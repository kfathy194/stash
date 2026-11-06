"""Public allocator behavior against an isolated Git Database HTTP service."""
import hashlib
import io
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_pipeline as pipeline


class GitService:
    def __init__(self):
        self.refs = {}
        self.objects = {}
        self.lock = threading.RLock()
        self.before_update = None
        self.lose_update = False
        self.fail_update = None

    def response(self, request, **kwargs):
        with self.lock:
            path = urllib.parse.urlsplit(request.full_url).path.split('/repos/owner/repo')[1]
            method = request.get_method()
            body = json.loads(request.data) if request.data else None
            def error(status):
                raise urllib.error.HTTPError(request.full_url, status, 'fixture', {}, None)
            result = None
            if path.startswith('/git/ref/'):
                name = path[len('/git/ref/'):]
                if name in self.refs:
                    result = {'object': {'type': 'commit', 'sha': self.refs[name]}}
            elif path.startswith('/git/matching-refs/'):
                prefix = path[len('/git/matching-refs/'):]
                result = [{'ref': 'refs/' + k} for k in self.refs if k.startswith(prefix)]
            elif path == '/releases':
                result = []
            elif method == 'POST' and path in ('/git/blobs', '/git/trees', '/git/commits'):
                sha = hashlib.sha1((path + json.dumps(body, sort_keys=True)).encode()).hexdigest()
                result = {**body, 'sha': sha}
                if path == '/git/commits':
                    result['tree'] = {'sha': body['tree']}
                    result['parents'] = [{'sha': p} for p in body['parents']]
                self.objects[sha] = result
            elif method == 'GET' and path.startswith(('/git/blobs/', '/git/trees/', '/git/commits/')):
                result = self.objects.get(path.rsplit('/', 1)[1])
            elif method == 'POST' and path == '/git/refs':
                name = body['ref'][len('refs/'):]
                if name in self.refs: error(422)
                self.refs[name] = body['sha']
                result = {'object': {'type': 'commit', 'sha': body['sha']}}
            elif method == 'PATCH' and path.startswith('/git/refs/'):
                name = path[len('/git/refs/'):]
                if self.before_update:
                    callback = self.before_update
                    self.before_update = None
                    callback()
                if self.fail_update: error(self.fail_update)
                candidate = self.objects[body['sha']]
                # Git accepts only descendants of the current head, not stale siblings.
                if body.get('force') is not False or (body['sha'] != self.refs[name] and candidate['parents'] != [{'sha': self.refs[name]}]):
                    error(422)
                self.refs[name] = body['sha']
                if self.lose_update:
                    self.lose_update = False
                    raise urllib.error.URLError('response lost with test-token')
                result = {'object': {'type': 'commit', 'sha': body['sha']}}
            else:
                raise AssertionError(f'Unexpected HTTP request: {method} {path}')
            if result is None: error(404)
            return io.BytesIO(json.dumps(result).encode())


class AllocationTests(unittest.TestCase):
    def setUp(self):
        self.service = GitService()
        self.http = patch.object(pipeline.urllib.request, 'urlopen', side_effect=self.service.response)
        self.http.start()
        self.addCleanup(self.http.stop)
        self.api = pipeline.GitHub('owner/repo', 'test-token')

    def reserve(self, letter, count):
        import release_versions
        event = {'action': 'closed', 'pull_request': {'merged': True, 'base': {'ref': 'main'}, 'merge_commit_sha': letter * 40}}
        return release_versions.reserve(self.api, event, count)

    def bootstrap(self):
        import release_versions
        return release_versions.bootstrap(self.api)

    def test_three_sources_and_retries_keep_separate_build_numbers(self):
        self.bootstrap()
        first = self.reserve('a', 47)
        second = self.reserve('b', 52)
        third = self.reserve('c', 60)
        self.assertEqual(first, {'version': '0.1.1', 'build_number': 49, 'commit': 'a'*40, 'tag': 'v0.1.1-dev.49'})
        self.assertEqual((second['version'], second['build_number']), ('0.1.2', 54))
        self.assertEqual((third['version'], third['build_number']), ('0.1.3', 62))
        self.assertEqual(self.reserve('a', 47), first)

    def test_public_reserve_command_writes_validated_plan(self):
        import os
        import tempfile
        self.bootstrap()
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            event.write_text(json.dumps({'action': 'closed', 'pull_request': {'merged': True, 'base': {'ref': 'main'}, 'merge_commit_sha': 'a'*40}}))
            output = Path(directory) / 'outputs'
            original = os.getcwd()
            try:
                os.chdir(directory)
                with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_REPOSITORY='owner/repo', GH_TOKEN='test-token', GITHUB_OUTPUT=str(output)), patch.object(sys, 'argv', ['release_pipeline.py', 'reserve']), patch.object(pipeline.subprocess, 'check_output', side_effect=['a'*40, '47']):
                    pipeline.main()
                plan = json.loads(Path('release-plan.json').read_text())
                self.assertEqual(plan['tag'], 'v0.1.1-dev.49')
                self.assertEqual(set(output.read_text().splitlines()), {'version=0.1.1', 'build_number=49', 'commit='+'a'*40, 'tag=v0.1.1-dev.49'})
            finally:
                os.chdir(original)

    def test_lost_response_and_abandoned_build_keep_original_reservation(self):
        self.bootstrap()
        self.service.lose_update = True
        first = self.reserve('a', 47)
        self.assertEqual(self.reserve('b', 60)['version'], '0.1.2')
        self.assertEqual(self.reserve('a', 47), first)

    def test_stale_distinct_sources_and_duplicate_sources_allocate_once(self):
        self.bootstrap()
        other = []
        self.service.before_update = lambda: other.append(self.reserve('b', 52))
        first = self.reserve('a', 47)
        self.assertEqual((other[0]['version'], first['version']), ('0.1.1', '0.1.2'))
        duplicates = []
        self.service.before_update = lambda: duplicates.append(self.reserve('c', 60))
        self.assertEqual(self.reserve('c', 60), duplicates[0])
        self.assertEqual(self.reserve('d', 70)['version'], '0.1.4')

    def test_missing_state_never_bootstraps_and_deleted_branch_never_recovers_seed(self):
        with self.assertRaisesRegex(ValueError, 'not initialized'):
            self.reserve('a', 47)
        self.bootstrap()
        self.reserve('a', 47)
        del self.service.refs['heads/stash-release-versions']
        with self.assertRaisesRegex(ValueError, 'deleted'):
            self.bootstrap()
        with self.assertRaises(ValueError):
            self.reserve('b', 52)

    def test_bootstrap_idempotence_and_interrupted_seed_creation(self):
        self.bootstrap()
        seed = self.service.refs['heads/stash-release-versions']
        del self.service.refs['tags/stash-release-versions-bootstrap-v1']
        self.bootstrap()
        self.assertEqual(self.service.refs['heads/stash-release-versions'], seed)
        first = self.reserve('a', 47)
        self.bootstrap()
        self.assertEqual(self.reserve('a', 47), first)
        del self.service.refs['tags/stash-release-versions-bootstrap-v1']
        with self.assertRaisesRegex(ValueError, 'owned empty seed'):
            self.bootstrap()

    def test_nonrace_api_errors_are_not_retried_or_exposed(self):
        self.bootstrap()
        for status in (401, 403, 422, 500):
            with self.subTest(status=status):
                self.service.fail_update = status
                with self.assertRaisesRegex(RuntimeError, str(status)) as error:
                    self.reserve('a', 47)
                self.assertNotIn('test-token', str(error.exception))
        self.service.fail_update = None
        self.assertEqual(self.reserve('a', 47)['version'], '0.1.1')

    def test_build_count_conflict_and_invalid_event_fail(self):
        self.bootstrap()
        self.reserve('a', 47)
        with self.assertRaisesRegex(ValueError, 'identity conflict'):
            self.reserve('a', 48)
        import release_versions
        with self.assertRaises(ValueError):
            release_versions.reserve(self.api, {'action': 'opened'}, 47)

    def test_external_changes_to_existing_assignment_fail_before_new_allocation(self):
        self.bootstrap()
        self.reserve('a', 47)
        # The service admits an external malformed blob, as a real Git host can.
        head = self.service.objects[self.service.refs['heads/stash-release-versions']]
        tree = self.service.objects[head['tree']['sha']]
        blob = self.service.objects[tree['tree'][0]['sha']]
        original = blob['content']
        import base64
        for payload in (b'not json', b'{"schema":2}', b'null'):
            with self.subTest(payload=payload):
                blob['content'] = base64.b64encode(payload).decode()
                with self.assertRaises(ValueError): self.reserve('b', 52)
        blob['content'] = original
        self.assertEqual(self.reserve('b', 52)['version'], '0.1.2')

    def test_bootstrap_recovery_rejects_new_policy_release_tags(self):
        self.bootstrap()
        del self.service.refs['tags/stash-release-versions-bootstrap-v1']
        self.service.refs['tags/v0.1.1-dev.49'] = 'e'*40
        with self.assertRaisesRegex(ValueError, 'already exist'):
            self.bootstrap()

    def test_bounded_contention_does_not_report_unpersisted_assignment(self):
        import release_versions
        self.bootstrap()
        self.service.before_update = lambda: self.reserve('b', 52)
        event = {'action': 'closed', 'pull_request': {'merged': True, 'base': {'ref': 'main'}, 'merge_commit_sha': 'a'*40}}
        with self.assertRaisesRegex(RuntimeError, 'contention exhausted'):
            release_versions.reserve(self.api, event, 47, max_attempts=1)
        self.assertEqual(self.reserve('a', 47)['version'], '0.1.2')

    def test_valid_external_commit_cannot_change_an_existing_mapping(self):
        import base64
        self.bootstrap()
        first = self.reserve('a', 47)
        head = self.service.refs['heads/stash-release-versions']
        commit = self.service.objects[head]
        tree = self.service.objects[commit['tree']['sha']]
        old_blob = self.service.objects[tree['tree'][0]['sha']]
        state = json.loads(base64.b64decode(old_blob['content']))
        # External writer adds a new entry but also changes an earlier identity.
        state['assignments']['a'*40]['build_number'] = 50
        state['assignments']['a'*40]['tag'] = 'v0.1.1-dev.50'
        state['assignments']['b'*40] = {'version': '0.1.2', 'build_number': 54, 'commit': 'b'*40, 'tag': 'v0.1.2-dev.54'}
        state['next_patch'] = 3
        blob = self.api.request('POST', '/git/blobs', {'encoding': 'base64', 'content': base64.b64encode(json.dumps(state).encode()).decode()})
        tree = self.api.request('POST', '/git/trees', {'tree': [{'path': 'release-versions.json', 'mode': '100644', 'type': 'blob', 'sha': blob['sha']}]})
        candidate = self.api.request('POST', '/git/commits', {'tree': tree['sha'], 'parents': [head], 'message': 'external write'})
        self.api.request('PATCH', '/git/refs/heads/stash-release-versions', {'sha': candidate['sha'], 'force': False})
        with self.assertRaisesRegex(ValueError, 'changed or removed'):
            self.reserve('c', 60)
        self.assertEqual(first['version'], '0.1.1')

    def test_malformed_git_response_fails_before_reserving(self):
        self.bootstrap()
        original = self.service.response
        def response(request, **kwargs):
            if '/git/ref/heads/' in request.full_url:
                return io.BytesIO(b'{"object": {"type": "commit", "sha": null}}')
            return original(request, **kwargs)
        with patch.object(pipeline.urllib.request, 'urlopen', side_effect=response):
            with self.assertRaisesRegex(ValueError, 'Git object identity'):
                self.reserve('a', 47)
        self.assertEqual(self.reserve('a', 47)['version'], '0.1.1')

    def test_truncated_success_response_is_resolved_from_durable_source(self):
        self.bootstrap()
        original = self.service.response
        truncated = []
        def response(request, **kwargs):
            result = original(request, **kwargs)
            if request.get_method() == 'PATCH' and not truncated:
                truncated.append(True)
                return io.BytesIO(b'{')
            return result
        with patch.object(pipeline.urllib.request, 'urlopen', side_effect=response):
            first = self.reserve('a', 47)
        self.assertEqual(first['version'], '0.1.1')
        self.assertEqual(self.reserve('b', 52)['version'], '0.1.2')

    def test_bootstrap_recovers_response_loss_after_each_ref_creation(self):
        original = self.service.response
        lost = set()
        def response(request, **kwargs):
            result = original(request, **kwargs)
            if request.get_method() == 'POST' and request.full_url.endswith('/git/refs'):
                name = json.loads(request.data)['ref']
                if name not in lost:
                    lost.add(name)
                    raise urllib.error.URLError('lost committed bootstrap response')
            return result
        with patch.object(pipeline.urllib.request, 'urlopen', side_effect=response):
            self.bootstrap()
        self.assertEqual(len(lost), 2)
        self.assertEqual(self.reserve('a', 47)['version'], '0.1.1')

    def test_lookup_reads_original_assignment_without_allocating(self):
        import release_versions
        self.bootstrap()
        first = self.reserve('a', 47)
        self.reserve('b', 52)
        before = dict(self.service.refs)
        self.assertEqual(release_versions.lookup(self.api, 'a'*40), first)
        with self.assertRaisesRegex(ValueError, 'not assigned'):
            release_versions.lookup(self.api, 'c'*40)
        self.assertEqual(self.service.refs, before)

    def test_publish_command_checks_assignment_before_any_release_mutation(self):
        import os
        import subprocess
        import tempfile
        import release_versions
        from test_release_pipeline import FakeAPI
        backend = FakeAPI()
        original_http = self.service.response
        def response(request, **kwargs):
            url = urllib.parse.urlsplit(request.full_url)
            path = url.path.split('/repos/owner/repo')[1]
            method = request.get_method()
            body = json.loads(request.data) if request.data and url.netloc == 'api.github.com' else None
            if path.startswith('/git/'):
                return original_http(request, **kwargs)
            if path.startswith('/releases/tags/'):
                result = backend.current if backend.current and not backend.current['draft'] else None
            elif path == '/releases' and method == 'GET': result = [backend.current] if backend.current else []
            elif path == '/releases' and method == 'POST':
                result = backend.create(dict(tag=body['tag_name'],commit=body['target_commitish']), body['body'])
                result.update(name=body['name'], prerelease=body['prerelease'])
            elif path == '/releases/1/assets':
                backend.upload(backend.current,urllib.parse.parse_qs(url.query)['name'][0],request.data)
                result = backend.current['assets'][-1]
            elif path == '/releases/1' and method == 'GET': result = backend.current
            elif path == '/releases/1' and method == 'PATCH':
                if 'body' in body:
                    backend.notes(backend.current,body['body']); result = backend.current
                else: result = backend.publish(backend.current)
            else: raise AssertionError(f'Unexpected request: {method} {path}')
            if result is None: raise urllib.error.HTTPError(request.full_url,404,'fixture',{},None)
            return io.BytesIO(json.dumps(result).encode())
        self.bootstrap()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git','init','-q',directory],check=True)
            subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-qm','fixture'],cwd=root,check=True)
            sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
            event = {'action':'closed','pull_request':{'number':32,'merged':True,'base':{'ref':'main'},'merge_commit_sha':sha}}
            plan = release_versions.reserve(self.api,event,1)
            before = dict(self.service.refs)
            (root/'event.json').write_text(json.dumps(event))
            output = root/'release-output'; output.mkdir()
            (output/'Stash-macOS.zip').write_bytes(b'assigned package')
            digest = hashlib.sha256(b'assigned package').hexdigest()
            (output/'Stash-macOS.dmg').write_bytes(b'assigned disk image')
            dmg_digest = hashlib.sha256(b'assigned disk image').hexdigest()
            (output/'SHA256SUMS').write_text(digest+'  Stash-macOS.zip\n'+dmg_digest+'  Stash-macOS.dmg\n')
            receipt = dict(plan,package_format=2,sha256=digest,dmg_sha256=dmg_digest,signing='ad-hoc',notarized=False)
            original_cwd = os.getcwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ,GITHUB_EVENT_PATH=str(root/'event.json'),GITHUB_REPOSITORY='owner/repo',GH_TOKEN='test-token'), patch.object(sys,'argv',['release_pipeline.py','publish']), patch.object(pipeline.urllib.request,'urlopen',side_effect=response):
                    for selected, packaged in [(dict(plan,version='0.1.2',tag='v0.1.2-dev.3'),dict(receipt,version='0.1.2',tag='v0.1.2-dev.3')),(dict(plan,build_number=4,tag='v0.1.1-dev.4'),receipt),(dict(plan,tag='wrong'),receipt),(dict(plan,commit='f'*40),receipt),(plan,dict(receipt,version='0.1.2')),(plan,dict(receipt,build_number=4)),(plan,dict(receipt,commit='f'*40))]:
                        (root/'release-plan.json').write_text(json.dumps(selected))
                        (output/'metadata.json').write_text(json.dumps(packaged))
                        with self.assertRaises(ValueError): pipeline.main()
                        self.assertIsNone(backend.current)
                    (root/'release-plan.json').write_text(json.dumps(plan))
                    (output/'metadata.json').write_text(json.dumps(receipt))
                    pipeline.main()
                    self.assertFalse(backend.current['draft'])
                    self.assertEqual(backend.current['tag_name'],'v0.1.1-dev.3')
                    self.assertEqual(backend.current['name'],'v0.1.1-dev.3')
                    self.assertTrue(backend.current['prerelease'])
                    self.assertIn('Version: 0.1.1 (build 3)',backend.current['body'])
                    self.assertEqual(self.service.refs,before)
            finally: os.chdir(original_cwd)
