import importlib.util
import unittest
from unittest.mock import patch
import io
import json
from pathlib import Path
spec = importlib.util.spec_from_file_location('release_pipeline', Path(__file__).parents[1] / 'release_pipeline.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class GitHubBoundaryTests(unittest.TestCase):
    def test_finds_interrupted_draft_beyond_first_page(self):
        draft = {'id': 101, 'tag_name': 'v0.1.0-dev.14', 'draft': True}
        def response(request, **kwargs):
            path = request.full_url.split('/repos/owner/repo')[1]
            if path.startswith('/releases/tags/'):
                raise r.urllib.error.HTTPError(request.full_url, 404, 'Not Found', {}, None)
            if path == '/releases?per_page=100&page=1':
                return io.BytesIO(json.dumps([{'id': n, 'tag_name': str(n)} for n in range(100)]).encode())
            if path == '/releases?per_page=100&page=2':
                return io.BytesIO(json.dumps([draft]).encode())
            raise AssertionError('Unexpected request: ' + path)
        with patch.object(r.urllib.request, 'urlopen', side_effect=response):
            self.assertEqual(r.GitHub('owner/repo', 'test-token').release(draft['tag_name']), draft)

class ReleaseTests(unittest.TestCase):
    def event(self):
        return {'action':'closed','pull_request':{'merged':True,'number':7,'merge_commit_sha':'a'*40,'base':{'ref':'main'}}}
    def test_only_completed_main_merges(self):
        self.assertEqual(r.merged_revision(self.event()), 'a'*40)
        for change in ({'merged':False}, {'base':{'ref':'other'}}, {'merge_commit_sha':None}):
            e=self.event(); e['pull_request'].update(change)
            with self.assertRaises(ValueError): r.merged_revision(e)
    def test_identity_from_source_not_run_counter(self):
        self.assertEqual(r.identity('0.1.0', 12, 'a'*40), {'version':'0.1.0','build_number':14,'commit':'a'*40,'tag':'v0.1.0-dev.14'})
    def test_reject_invalid_versions(self):
        with self.assertRaises(ValueError): r.identity('$(evil)',12,'a'*40)

class FakeAPI:
    def __init__(self): self.current=None; self.objects={}; self.publications=0; self.fail=None
    def tag_commit(self,tag): return self.current["target_commitish"] if self.current and not self.current["draft"] else None
    def release(self,tag): return self.current
    def release_by_id(self,release_id): return self.current
    def create(self,plan,notes):
        self.current={'id':1,'draft':True,'tag_name':plan['tag'],'target_commitish':plan['commit'],'body':notes,'assets':[]}
        return self.current
    def upload(self,release,name,data):
        if self.fail==name: raise RuntimeError('quota or network failure')
        asset={'id':len(self.objects)+1,'name':name,'size':len(data),'digest':'sha256:'+r.hashlib.sha256(data).hexdigest()}
        self.objects[name]=data;release['assets'].append(asset)
    def notes(self,release,body): release["body"]=body
    def delete(self,asset):
        self.current['assets']=[a for a in self.current['assets'] if a['id']!=asset['id']]
        self.objects.pop(asset['name'])
    def publish(self,release): self.publications+=1;release['draft']=False;return release

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.plan=r.identity('0.1.0',12,'a'*40)
        self.assets={'Stash-macOS.zip':b'zip','SHA256SUMS':b'checksum','metadata.json':b'receipt'}
        self.api=FakeAPI()

    def test_http_draft_recovery_publishes_once_and_preserves_bytes(self):
        # Model GitHub's documented HTTP contract, exercising the real adapter.
        # In particular, tag lookup cannot see drafts and responses are copies.
        backend = self.api
        def response(request, **kwargs):
            url = r.urllib.parse.urlsplit(request.full_url)
            path = url.path.split('/repos/owner/repo')[1]
            method = request.get_method()
            body = json.loads(request.data) if request.data and url.netloc == 'api.github.com' else None
            result = None
            if path.startswith('/git/ref/'):
                sha = backend.tag_commit(self.plan['tag'])
                result = {'object': {'type': 'commit', 'sha': sha}} if sha else None
            elif path.startswith('/releases/tags/'):
                result = backend.current if backend.current and not backend.current['draft'] else None
            elif path == '/releases' and method == 'GET':
                result = [backend.current] if backend.current else []
            elif path == '/releases' and method == 'POST':
                result = backend.create(self.plan, body['body'])
            elif path == '/releases/1/assets':
                backend.upload(backend.current, r.urllib.parse.parse_qs(url.query)['name'][0], request.data)
                result = backend.current['assets'][-1]
            elif path == '/releases/1' and method == 'GET':
                result = backend.current
            elif path == '/releases/1' and method == 'PATCH':
                # Observed draft-update behavior: omitting tag_name replaces a
                # not-yet-created tag with an untagged draft placeholder.
                backend.current['tag_name'] = body.get('tag_name', 'untagged-fixture')
                if 'body' in body:
                    backend.notes(backend.current, body['body'])
                    result = backend.current
                else:
                    result = backend.publish(backend.current)
            else:
                raise AssertionError(f'Unexpected request: {method} {path}')
            if result is None:
                raise r.urllib.error.HTTPError(request.full_url, 404, 'Not Found', {}, None)
            return io.BytesIO(json.dumps(result).encode())

        api = r.GitHub('owner/repo', 'test-token')
        with patch.object(r.urllib.request, 'urlopen', side_effect=response):
            backend.fail = 'SHA256SUMS'
            with self.assertRaises(RuntimeError):
                r.publish(api, self.plan, self.assets, 'notes')
            self.assertTrue(backend.current['draft'])
            backend.fail = None
            released = r.publish(api, self.plan, self.assets, 'notes')
            self.assertFalse(released['draft'])
            r.publish(api, self.plan, {**self.assets, 'Stash-macOS.zip': b'rebuilt'}, 'notes')
        self.assertEqual(backend.publications, 1)
        self.assertEqual(backend.current['tag_name'], 'v0.1.0-dev.14')
        self.assertEqual(backend.current['target_commitish'], 'a'*40)
        self.assertEqual(backend.objects, self.assets)
    def test_interrupted_upload_resumes_original_release(self):
        self.api.fail='SHA256SUMS'
        with self.assertRaises(RuntimeError):r.publish(self.api,self.plan,self.assets,'notes')
        self.assertTrue(self.api.current['draft'])
        self.api.fail=None
        r.publish(self.api,self.plan,self.assets,'notes')
        self.assertEqual(self.api.publications,1)
        self.assertEqual(self.api.objects,self.assets)
    def test_success_response_lost_then_retry_does_not_mutate(self):
        r.publish(self.api,self.plan,self.assets,'notes')
        before=dict(self.api.objects)
        r.publish(self.api,self.plan,self.assets,'notes')
        self.assertEqual(self.api.publications,1)
        self.assertEqual(self.api.objects,before)
    def test_changed_rebuild_reconciles_draft_only(self):
        self.api.fail='SHA256SUMS'
        with self.assertRaises(RuntimeError):r.publish(self.api,self.plan,self.assets,'notes')
        self.api.fail=None
        changed=dict(self.assets);changed['Stash-macOS.zip']=b'rebuilt'
        r.publish(self.api,self.plan,changed,'notes')
        self.assertEqual(self.api.objects,changed)
        r.publish(self.api,self.plan,self.assets,'notes')
        self.assertEqual(self.api.objects,changed)
    def test_conflicting_commit_rejected_without_mutation(self):
        r.publish(self.api,self.plan,self.assets,'notes')
        other=dict(self.plan);other['commit']='b'*40
        with self.assertRaises(ValueError):r.publish(self.api,other,self.assets,'notes')
        self.assertEqual(self.api.publications,1)

class MoreReleaseTests(unittest.TestCase):
    def test_distinct_merged_revisions_have_increasing_build_numbers(self):
        a=r.identity('0.1.0',20,'a'*40);b=r.identity('0.1.0',21,'b'*40)
        self.assertEqual((a['build_number'],b['build_number']),(22,23))
        self.assertEqual(r.identity('0.1.0',20,'a'*40),a)
    def test_quota_denial_preserves_existing_download(self):
        api=FakeAPI(); plan=r.identity('0.1.0',12,'a'*40)
        assets={'Stash-macOS.zip':b'old','SHA256SUMS':b'oldsum','metadata.json':b'receipt'}
        r.publish(api,plan,assets,'notes')
        before=dict(api.objects)
        api.fail='SHA256SUMS'
        r.publish(api,plan,{'Stash-macOS.zip':b'new'},'notes')
        self.assertEqual(api.objects,before)
    def test_package_receipt_and_checksum_match_selected_identity(self):
        import tempfile
        import json
        plan=r.identity('0.1.0',12,'a'*40)
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp); (p/'Stash-macOS.zip').write_bytes(b'package')
            sha=r.hashlib.sha256(b'package').hexdigest()
            (p/'SHA256SUMS').write_text(sha+'  Stash-macOS.zip\n')
            receipt={**plan,'sha256':sha,'signing':'ad-hoc','notarized':False}
            (p/'metadata.json').write_text(json.dumps(receipt))
            self.assertEqual(set(r.package_assets(p,plan)),{'Stash-macOS.zip','SHA256SUMS','metadata.json'})
            receipt['commit']='b'*40;(p/'metadata.json').write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):r.package_assets(p,plan)
    def test_unmerged_and_wrong_action_have_no_release_source(self):
        with self.assertRaises(ValueError):r.merged_revision({'action':'opened'})
    def test_moved_published_tag_rejected(self):
        api=FakeAPI(); plan=r.identity('0.1.0',12,'a'*40)
        r.publish(api,plan,{'Stash-macOS.zip':b'data','SHA256SUMS':b'sum','metadata.json':b'receipt'},'notes')
        api.tag_commit=lambda tag:'f'*40
        with self.assertRaises(ValueError):r.publish(api,plan,{'Stash-macOS.zip':b'data','SHA256SUMS':b'sum','metadata.json':b'receipt'},'notes')
    def test_published_digest_changed_externally_fails(self):
        api=FakeAPI();plan=r.identity('0.1.0',12,'a'*40)
        r.publish(api,plan,{'Stash-macOS.zip':b'data','SHA256SUMS':b'sum','metadata.json':b'receipt'},'notes')
        api.current['assets'][0]['digest']='sha256:'+'0'*64
        with self.assertRaises(ValueError):r.publish(api,plan,{'Stash-macOS.zip':b'data','SHA256SUMS':b'sum','metadata.json':b'receipt'},'notes')
        self.assertEqual(api.publications,1)

    def test_empty_published_manifest_fails(self):
        api=FakeAPI();plan=r.identity('0.1.0',12,'a'*40)
        assets={'Stash-macOS.zip':b'data','SHA256SUMS':b'sum','metadata.json':b'receipt'}
        r.publish(api,plan,assets,'notes')
        api.current['body']='<!-- stash-release:'+r.json.dumps({'plan':plan,'assets':{}})+' -->'
        with self.assertRaises(ValueError):r.publish(api,plan,assets,'notes')

class AssignedCommandTests(unittest.TestCase):
    def test_materialize_preserves_forwarded_plan_and_rejects_wrong_identity_without_network(self):
        import os
        import subprocess
        import tempfile
        script = Path(__file__).resolve().parents[1]/'release_pipeline.py'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git','init','-q',directory], check=True)
            subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','fixture'],cwd=root,check=True)
            sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
            event = root/'event.json'
            event.write_text(json.dumps({'action':'closed','pull_request':{'merged':True,'base':{'ref':'main'},'merge_commit_sha':sha}}))
            env = dict(os.environ, GITHUB_EVENT_PATH=str(event))
            env.pop('GH_TOKEN',None)
            plan = dict(version='0.1.7',build_number=3,commit=sha,tag='v0.1.7-dev.3')
            def invoke(selected):
                return subprocess.run(['python3',str(script),'materialize',*[arg for k,v in selected.items() for arg in ('--'+k.replace('_','-'),str(v))]],cwd=root,env=env,capture_output=True,text=True)
            result = invoke(plan)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads((root/'release-plan.json').read_text()),plan)
            for change in ({'version':'0.1.8'}, {'build_number':4}, {'commit':'f'*40}, {'tag':'v0.1.7-dev.4'}, {'version':'bad\nsecret=x'}):
                with self.subTest(change=change):
                    result = invoke({**plan,**change})
                    self.assertNotEqual(result.returncode,0)
                    self.assertEqual(json.loads((root/'release-plan.json').read_text()),plan)
            event.write_text(json.dumps({'action':'opened'}))
            self.assertNotEqual(invoke(plan).returncode,0)
