"""Recovery at public command, native package and isolated GitHub HTTP boundaries."""
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse
import urllib.request

from test_release_versions import GitService
import test_release_package as package_fixtures
import release_pipeline as pipeline
import release_versions

ROOT = Path(__file__).resolve().parents[2]


class ReleaseService(GitService):
    """Multiple releases share the allocator's atomic Git service and fault boundary."""
    def __init__(self):
        super().__init__()
        self.releases = {}
        self.downloads = {}
        self.mutations = []
        self.deny_upload = False
        self.lose_publication = False

    def response(self, request, **kwargs):
        url = urllib.parse.urlsplit(request.full_url)
        path = url.path.split('/repos/owner/repo')[1]
        method = request.get_method()
        if path.startswith('/git/'):
            return super().response(request, **kwargs)
        if method != 'GET': self.mutations.append((method, path))
        def error(status):
            raise urllib.error.HTTPError(request.full_url, status, 'fixture', {}, None)
        body = json.loads(request.data) if request.data and url.netloc == 'api.github.com' else None
        result = None
        if path == '/releases' and method == 'GET':
            page = int(urllib.parse.parse_qs(url.query).get('page', ['1'])[0])
            result = list(self.releases.values())[(page-1)*100:page*100]
        elif path == '/releases' and method == 'POST':
            number = len(self.releases)+1
            result = dict(body, id=number, assets=[])
            self.releases[number] = result
        elif path.startswith('/releases/tags/'):
            result = next((r for r in self.releases.values() if r['tag_name'] == path.split('/tags/')[1] and not r['draft']), None)
        elif path.startswith('/releases/assets/'):
            number = int(path.rsplit('/', 1)[1])
            if method == 'GET': return io.BytesIO(self.downloads[number])
            if method == 'DELETE':
                for release in self.releases.values():
                    release['assets'] = [a for a in release['assets'] if a['id'] != number]
                return io.BytesIO(b'')
        elif path.startswith('/releases/'):
            parts = path.strip('/').split('/')
            release = self.releases.get(int(parts[1]))
            if release is None: error(404)
            if len(parts) == 3 and parts[2] == 'assets' and method == 'POST':
                if self.deny_upload: error(403)
                number = len(self.downloads)+1
                data = request.data
                self.downloads[number] = data
                result = dict(id=number, name=urllib.parse.parse_qs(url.query)['name'][0], size=len(data), digest='sha256:'+hashlib.sha256(data).hexdigest())
                release['assets'].append(result)
            elif method == 'GET': result = release
            elif method == 'PATCH':
                release.update(body)
                result = release
                if body.get('draft') is False:
                    self.refs['tags/'+release['tag_name']] = release['target_commitish']
                    if self.lose_publication:
                        self.lose_publication = False
                        raise urllib.error.URLError('publication response lost')
            else: raise AssertionError((method, path))
        else: raise AssertionError((method, path))
        if result is None: error(404)
        return io.BytesIO(json.dumps(result).encode())


class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A native universal fixture, never the installed app or user library.
        package_fixtures.ExtractedBundleTests.setUpClass()
        cls.app = package_fixtures.ExtractedBundleTests.app

    @classmethod
    def tearDownClass(cls):
        package_fixtures.ExtractedBundleTests.tearDownClass()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root/'source'; self.source.mkdir()
        for folder in ('Scripts', 'Config'): (self.source/folder).mkdir()
        for name in ('package_release.py', 'release_metadata.py'):
            shutil.copy2(ROOT/'Scripts'/name, self.source/'Scripts'/name)
        for name in ('ReleaseVersion.txt', 'StashMacDevelopment.entitlements'):
            shutil.copy2(ROOT/'Config'/name, self.source/'Config'/name)
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','source A')
        self.a = self.git('rev-parse', 'HEAD')
        self.git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','source B')
        self.b = self.git('rev-parse', 'HEAD')
        self.service = ReleaseService()
        self.http = patch.object(urllib.request, 'urlopen', side_effect=self.service.response)
        self.http.start(); self.addCleanup(self.http.stop)
        self.api = pipeline.GitHub('owner/repo','fixture-token')
        release_versions.bootstrap(self.api)
        tools = self.root/'tools'; tools.mkdir()
        builder = tools/'bash'
        # Replace only the external Xcode process. All package signing, arch,
        # extraction and receipt commands execute normally against fixture bytes.
        builder.write_text('#!'+sys.executable+'\n'+'''import os, pathlib, plistlib, shutil, sys
if os.environ.get('FAIL_FIXTURE_BUILD'): sys.exit(65)
app = pathlib.Path(os.environ['STASH_CHECK_ROOT'])/'mac/Build/Products/Release/Stash.app'
shutil.copytree(os.environ['FIXTURE_APP'], app)
p = app/'Contents/Info.plist'
info = plistlib.loads(p.read_bytes())
info.update(CFBundleShortVersionString=os.environ['STASH_RELEASE_VERSION'], CFBundleVersion=os.environ['STASH_BUILD_NUMBER'])
p.write_bytes(plistlib.dumps(info))
''')
        builder.chmod(0o755)
        self.env = dict(GITHUB_REPOSITORY='owner/repo', GH_TOKEN='fixture-token', FIXTURE_APP=str(self.app), PATH=str(tools)+os.pathsep+os.environ['PATH'])

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.source, text=True).strip()

    def command(self, action, sha, *args):
        self.git('checkout','-q',sha)
        event = self.source/'event.json'
        event.write_text(json.dumps({'action':'closed','pull_request':{'number':33,'merged':True,'base':{'ref':'main'},'merge_commit_sha':sha}}))
        original = Path.cwd()
        try:
            os.chdir(self.source)
            with patch.dict(os.environ, dict(self.env, GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(self.source/'outputs'))), patch.object(sys,'argv',['release_pipeline.py',action,*args]):
                pipeline.main()
        finally: os.chdir(original)
        if action in ('reserve','plan','materialize'):
            return json.loads((self.source/'release-plan.json').read_text())

    def package(self, plan, fail=False):
        output = self.root/('failed-package' if fail else 'package-'+plan['version'])
        result = subprocess.run([sys.executable,str(self.source/'Scripts/package_release.py'),'--version',plan['version'],'--build-number',str(plan['build_number']),'--commit',plan['commit'],'--output',str(output)], cwd=self.source, env=dict(os.environ,**self.env, **({'FAIL_FIXTURE_BUILD':'1'} if fail else {})), capture_output=True, text=True)
        if fail:
            self.assertNotEqual(result.returncode,0)
            self.assertIn('65',result.stderr)
            self.assertFalse(output.exists())
        else: self.assertEqual(result.returncode,0,result.stderr)
        return output

    def published(self, plan):
        release = self.api.release(plan['tag'])
        self.assertFalse(release['draft'])
        downloaded = {}
        for asset in release['assets']:
            request = urllib.request.Request(self.api.base+'/releases/assets/'+str(asset['id']))
            with urllib.request.urlopen(request) as response: downloaded[asset['name']] = response.read()
        return release, downloaded

    def publish(self, plan, output):
        self.command('materialize',plan['commit'],'--version',plan['version'],'--build-number',str(plan['build_number']),'--commit',plan['commit'],'--tag',plan['tag'])
        self.command('publish',plan['commit'],'--directory',str(output))

    def test_failed_build_later_publication_and_fresh_runner_recover_original(self):
        a = self.command('reserve',self.a)
        self.package(a,fail=True)
        b = self.command('reserve',self.b)
        self.publish(b,self.package(b))
        before = self.published(b)
        self.assertEqual((a['version'],a['build_number'],b['version'],b['build_number']),('0.1.1',3,'0.1.2',4))
        # A new clone has neither the plan nor artifacts from runner A.
        fresh = self.root/'fresh-runner'
        subprocess.run(['git','clone','-q',str(self.source),str(fresh)],check=True,capture_output=True)
        self.source = fresh
        self.assertFalse((fresh/'release-plan.json').exists())
        recovered = self.command('reserve',self.a)
        self.assertEqual(recovered,a)
        self.assertEqual(release_versions.lookup(self.api,self.a),a)
        self.publish(recovered,self.package(recovered))
        self.assertEqual(self.published(b),before)
        release, assets = self.published(a)
        receipt = json.loads(assets['metadata.json'])
        self.assertEqual((receipt['commit'],receipt['version'],receipt['build_number']),(self.a,'0.1.1',3))
        self.assertIn('Version: 0.1.1 (build 3)',release['body'])
        self.assertEqual(release['target_commitish'],self.a)
        self.assertEqual(release['name'],'v0.1.1-dev.3')
        self.assertTrue(release['prerelease'])
        # Verify downloaded archive bytes and actual native app metadata.
        archive = self.root/'download.zip'; archive.write_bytes(assets['Stash-macOS.zip'])
        subprocess.run(['ditto','-x','-k',str(archive),str(self.root/'extracted')],check=True)
        import package_release
        package_release.verify_app(self.root/'extracted/Stash.app',a)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(),receipt['sha256'])
        self.assertEqual(assets['SHA256SUMS'].decode().strip(),receipt['sha256']+'  Stash-macOS.zip\n'+receipt['dmg_sha256']+'  Stash-macOS.dmg')
        self.assertEqual(hashlib.sha256(assets['Stash-macOS.dmg']).hexdigest(),receipt['dmg_sha256'])
        mutations = list(self.service.mutations)
        self.assertEqual(self.command('reserve',self.a),a)
        self.publish(a,self.root/'package-0.1.1')
        self.assertEqual(self.service.mutations,mutations)
        self.assertEqual(len(self.service.releases),2)

    def test_denied_new_upload_preserves_prior_download_then_recovers_draft(self):
        a = self.command('reserve',self.a)
        self.publish(a,self.package(a))
        before = self.published(a)
        b = self.command('reserve',self.b)
        output = self.package(b)
        self.service.deny_upload = True
        with self.assertRaisesRegex(pipeline.GitHubError,'403'): self.publish(b,output)
        self.assertEqual(self.published(a),before)
        self.assertTrue(self.api.release(b['tag'])['draft'])
        self.service.deny_upload = False
        self.assertEqual(self.command('reserve',self.b),b)
        self.publish(b,output)
        self.assertEqual(self.published(a),before)
        self.assertEqual(json.loads(self.published(b)[1]['metadata.json'])['version'],'0.1.2')

    def test_lost_publication_response_retry_is_read_only(self):
        a = self.command('reserve',self.a); output = self.package(a)
        self.service.lose_publication = True
        with self.assertRaises(pipeline.GitHubTransportError): self.publish(a,output)
        before = self.published(a)
        mutations = list(self.service.mutations)
        self.publish(a,output)
        self.assertEqual(self.published(a),before)
        self.assertEqual(self.service.mutations,mutations)

    def test_reservation_permission_denial_does_not_own_or_recycle_version(self):
        self.service.fail_update = 403
        with self.assertRaisesRegex(pipeline.GitHubError,'403'):
            self.command('reserve',self.a)
        self.assertFalse((self.source/'release-plan.json').exists())
        self.service.fail_update = None
        b = self.command('reserve',self.b)
        self.assertEqual(b['version'],'0.1.1')
        a = self.command('reserve',self.a)
        self.assertEqual(a['version'],'0.1.2')
        self.assertEqual(self.command('reserve',self.b),b)

    def test_missing_or_corrupt_state_cannot_publish_or_reset_prior_release(self):
        a = self.command('reserve',self.a); output = self.package(a)
        self.publish(a,output)
        before = self.published(a)
        head = self.service.refs[release_versions.BRANCH]
        commit = self.service.objects[head]
        tree = self.service.objects[commit['tree']['sha']]
        blob = self.service.objects[tree['tree'][0]['sha']]
        original = blob['content']
        for fault in ('missing','corrupt'):
            with self.subTest(fault=fault):
                if fault == 'missing': self.service.refs.pop(release_versions.BRANCH)
                else: blob['content'] = base64.b64encode(b'not a ledger').decode()
                refs = dict(self.service.refs)
                mutations = list(self.service.mutations)
                with self.assertRaises(ValueError): self.publish(a,output)
                with self.assertRaises(ValueError): self.command('reserve',self.b)
                self.assertEqual(self.service.refs,refs)
                self.assertEqual(self.service.mutations,mutations)
                self.assertEqual(self.published(a),before)
                self.service.refs[release_versions.BRANCH] = head
                blob['content'] = original

    def test_conflicting_plan_moved_tag_or_published_digest_never_replaces_assets(self):
        a = self.command('reserve',self.a); output = self.package(a)
        self.publish(a,output)
        release, downloaded = self.published(a)
        original_release = copy.deepcopy(release)
        for fault in ('plan','tag','digest'):
            with self.subTest(fault=fault):
                selected = dict(a,version='0.1.9',tag='v0.1.9-dev.3') if fault == 'plan' else a
                if fault == 'tag': self.service.refs['tags/'+a['tag']] = self.b
                if fault == 'digest': self.service.releases[release['id']]['assets'][0]['digest'] = 'sha256:'+'0'*64
                observed = self.published(a)
                mutations = list(self.service.mutations)
                refs = dict(self.service.refs)
                with self.assertRaises(ValueError): self.publish(selected,output)
                self.assertEqual(self.published(a),observed)
                self.assertEqual(self.published(a)[1],downloaded)
                self.assertEqual(self.service.mutations,mutations)
                self.assertEqual(self.service.refs,refs)
                self.service.refs['tags/'+a['tag']] = self.a
                self.service.releases[release['id']] = copy.deepcopy(original_release)

    def test_legacy_published_releases_and_draft_survive_new_policy_recovery(self):
        legacy = []
        assets = {'Stash-macOS.zip':b'historical zip', 'SHA256SUMS':b'historical sums', 'metadata.json':b'historical receipt'}
        for build in (43,46):
            plan = pipeline.identity('0.1.0',build-2,self.a)
            manifest={'plan':plan,'assets':{name:['sha256:'+hashlib.sha256(data).hexdigest(),len(data)] for name,data in assets.items()}}
            release=self.api.create(plan,'Historical 0.1.0\n<!-- stash-release:'+json.dumps(manifest)+' -->')
            for name,data in assets.items():self.api.upload(release,name,data)
            self.api.publish(release)
            legacy.append(plan)
        draft_plan = pipeline.identity('0.1.0',38,self.b)
        draft = self.api.create(draft_plan,'retained legacy draft')
        self.api.upload(draft,'Stash-macOS.zip',b'partial historical staging')
        before = [self.published(plan) for plan in legacy]
        old_draft = copy.deepcopy(self.api.release(draft_plan['tag']))
        refs = dict(self.service.refs)
        # Original legacy planner has no token and performs no HTTP operation.
        token = self.env.pop('GH_TOKEN')
        try:
            with patch.dict(os.environ,{},clear=True), patch.object(urllib.request,'urlopen',side_effect=AssertionError('legacy planner attempted HTTP')):
                local = self.command('plan',self.a)
            self.assertEqual((local['version'],local['build_number']),('0.1.0',3))
        finally: self.env['GH_TOKEN'] = token
        self.assertEqual(self.service.refs,refs)
        a = self.command('reserve',self.a)
        self.assertEqual(a['version'],'0.1.1')
        self.publish(a,self.package(a))
        self.assertEqual([self.published(plan) for plan in legacy],before)
        self.assertEqual(self.api.release(draft_plan['tag']),old_draft)
        # Legacy retry uses the old publisher contract and original manifest.
        mutations = list(self.service.mutations)
        for plan in legacy: pipeline.publish(self.api,plan,assets,'retry')
        self.assertEqual(self.service.mutations,mutations)
        # The CURRENT publisher never treats 0.1.0 as permission to skip lookup.
        legacy_for_source = dict(local)
        package = self.package(legacy_for_source)
        with self.assertRaisesRegex(ValueError,'original ledger assignment'):
            self.publish(legacy_for_source,package)

    def test_failed_earlier_upload_can_complete_after_later_source(self):
        a = self.command('reserve',self.a); output_a = self.package(a)
        self.service.deny_upload = True
        with self.assertRaises(pipeline.GitHubError): self.publish(a,output_a)
        self.service.deny_upload = False
        b = self.command('reserve',self.b)
        self.publish(b,self.package(b))
        before = self.published(b)
        self.assertEqual(self.command('reserve',self.a),a)
        self.publish(a,output_a)
        self.assertEqual(self.published(b),before)
        self.assertEqual([r['tag_name'] for r in self.service.releases.values()],['v0.1.1-dev.3','v0.1.2-dev.4'])
        self.assertFalse(self.api.release(a['tag'])['draft'])
