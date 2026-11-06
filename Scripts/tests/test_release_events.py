"""Event-to-publication commands using real Git and an isolated HTTP service.

Portable cases exercise receipt validation, not native package creation. The
separate native cases use the real package CLI and keep disk-image checks enabled.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_release_recovery as recovery

pipeline = recovery.pipeline
versions = recovery.release_versions


class EventFixture:
    def __init__(self, root):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.source = root/'source'
        self.source.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.source/'README.md').write_text('base\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        self.service = recovery.ReleaseService()
        self.api = pipeline.GitHub('owner/repo', 'fixture-token')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.source, text=True,
                                       stderr=subprocess.PIPE).strip()

    def merged(self, method='merge', docs=False, fork=False):
        self.git('checkout', '-qb', 'feature', self.base)
        name = 'README.md' if docs else 'feature.txt'
        (self.source/name).write_text('contribution\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'contribution')
        head = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-q', 'main')
        if method == 'merge':
            self.git('merge', '--no-ff', '-qm', 'merge contribution', head)
        elif method == 'squash':
            self.git('merge', '--squash', head)
            self.git('commit', '-qm', 'squash contribution')
        elif method == 'rebase':
            # A main commit forces the contributed commit to be rewritten.
            (self.source/'later.txt').write_text('main changed\n')
            self.git('add', '.')
            self.git('commit', '-qm', 'advance base')
            self.git('checkout', '-q', 'feature')
            self.git('rebase', 'main')
            self.git('checkout', '-q', 'main')
            self.git('merge', '--ff-only', 'feature')
        else:
            raise AssertionError(method)
        selected = self.git('rev-parse', 'HEAD')
        # Main advancing after the event must not redirect the build or retry.
        self.git('commit', '--allow-empty', '-qm', 'later main merge')
        self.later = self.git('rev-parse', 'HEAD')
        self.git('checkout', '-q', selected)
        return {'action': 'closed', 'pull_request': {
            'number': 16, 'merged': True, 'merge_commit_sha': selected,
            'base': {'ref': 'main'}, 'head': {'sha': head, 'repo': {'fork': fork}}}}

    def command(self, event, action, directory=None):
        event_path = self.root/'event.json'
        event_path.write_text(json.dumps(event))
        args = ['release_pipeline.py', action]
        if directory is not None: args += ['--directory', str(directory)]
        previous = Path.cwd()
        try:
            os.chdir(self.source)
            with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo',
                            GH_TOKEN='fixture-token', GITHUB_EVENT_PATH=str(event_path),
                            GITHUB_OUTPUT=str(self.root/'outputs')), patch.object(sys, 'argv', args):
                pipeline.main()
        finally:
            os.chdir(previous)
        if action == 'reserve':
            return json.loads((self.source/'release-plan.json').read_text())

    def contract(self, plan):
        """Small bytes for publisher receipt validation; never a native DMG claim."""
        output = self.root/'contract'
        output.mkdir()
        data = {'Stash-macOS.zip': b'ZIP contract fixture',
                'Stash-macOS.dmg': b'DMG contract fixture'}
        digests = {n: hashlib.sha256(b).hexdigest() for n, b in data.items()}
        receipt = dict(plan, package_format=2, sha256=digests['Stash-macOS.zip'],
                       dmg_sha256=digests['Stash-macOS.dmg'], signing='ad-hoc', notarized=False)
        for name, body in data.items(): (output/name).write_bytes(body)
        (output/'SHA256SUMS').write_text(''.join(digests[n]+'  '+n+'\n' for n in data))
        (output/'metadata.json').write_text(json.dumps(receipt))
        return output


class EventCommandTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.fixture = EventFixture(Path(temp.name))
        boundary = patch.object(pipeline.urllib.request, 'urlopen',
                                side_effect=self.fixture.service.response)
        boundary.start()
        self.addCleanup(boundary.stop)
        versions.bootstrap(self.fixture.api)

    def publish_event(self, method='merge', docs=False, fork=False):
        f = self.fixture
        event = f.merged(method, docs, fork)
        plan = f.command(event, 'reserve')
        self.assertEqual(plan['commit'], event['pull_request']['merge_commit_sha'])
        self.assertNotEqual(plan['commit'], f.later)
        output = f.contract(plan)
        f.command(event, 'publish', output)
        release = f.api.release(plan['tag'])
        self.assertFalse(release['draft'])
        self.assertEqual(release['target_commitish'], plan['commit'])
        self.assertEqual(release['name'], plan['tag'])
        self.assertIn('Commit: '+plan['commit'], release['body'])
        self.assertIn('Version: '+plan['version'], release['body'])
        receipt = json.loads(next(f.service.downloads[a['id']] for a in release['assets']
                                  if a['name'] == 'metadata.json'))
        self.assertEqual((receipt['commit'], receipt['version'], receipt['build_number']),
                         (plan['commit'], plan['version'], plan['build_number']))
        before = copy.deepcopy((f.service.refs, f.service.objects, f.service.releases,
                                f.service.downloads, f.service.mutations))
        self.assertEqual(f.command(event, 'reserve'), plan)
        f.command(event, 'publish', output)
        self.assertEqual((f.service.refs, f.service.objects, f.service.releases,
                          f.service.downloads, f.service.mutations), before)
        return event, plan, output

    def test_merge_result_survives_later_main_and_retry(self): self.publish_event()
    def test_squash_result_survives_later_main_and_retry(self): self.publish_event('squash')
    def test_rebase_result_survives_later_main_and_retry(self): self.publish_event('rebase')
    def test_documentation_only_merge_publishes(self): self.publish_event(docs=True)
    def test_merged_fork_publishes_only_selected_main_result(self): self.publish_event(fork=True)

    def test_excluded_events_have_no_assignment_or_release_mutations(self):
        f = self.fixture
        valid = f.merged()
        events = [{'ref': 'refs/heads/main', 'after': valid['pull_request']['merge_commit_sha']}]
        for action in ('opened', 'synchronize', 'reopened'):
            event = copy.deepcopy(valid); event['action'] = action; events.append(event)
        for change in ({'merged': False}, {'base': {'ref': 'other'}},
                       {'merge_commit_sha': None}, {'merge_commit_sha': 'not-a-sha'}):
            event = copy.deepcopy(valid); event['pull_request'].update(change); events.append(event)
        before = copy.deepcopy((f.service.refs, f.service.objects, f.service.releases,
                                f.service.downloads, f.service.mutations))
        for event in events:
            for action in ('reserve', 'publish'):
                with self.subTest(event=event, action=action), self.assertRaises(ValueError):
                    f.command(event, action)
                self.assertFalse((f.source/'release-plan.json').exists())
                self.assertEqual((f.service.refs, f.service.objects, f.service.releases,
                                  f.service.downloads, f.service.mutations), before)

    def test_wrong_checkout_cannot_reserve_or_publish(self):
        f = self.fixture
        event = f.merged()
        f.git('checkout', '-q', f.later)
        before = copy.deepcopy((f.service.refs, f.service.objects, f.service.releases))
        for action in ('reserve', 'publish'):
            with self.assertRaisesRegex(ValueError, 'Checkout is not the merged revision'):
                f.command(event, action)
        self.assertEqual((f.service.refs, f.service.objects, f.service.releases), before)

    def test_event_text_is_data_not_shell(self):
        f = self.fixture
        event = f.merged(fork=True)
        sentinel = f.root/'must-not-exist'
        text = '$(touch '+str(sentinel)+'); `touch '+str(sentinel)+'`'
        event['pull_request'].update(title=text, body=text, number=text)
        event['pull_request']['head']['ref'] = text
        plan = f.command(event, 'reserve')
        f.command(event, 'publish', f.contract(plan))
        self.assertFalse(sentinel.exists())
        self.assertIn(text, f.api.release(plan['tag'])['body'])

    def test_missing_or_tampered_package_cannot_publish(self):
        f = self.fixture
        event = f.merged()
        plan = f.command(event, 'reserve')
        output = f.contract(plan)
        for body in (None, b'tampered'):
            if body is None: (output/'Stash-macOS.dmg').unlink()
            else: (output/'Stash-macOS.dmg').write_bytes(body)
            with self.assertRaises((OSError, ValueError)):
                f.command(event, 'publish', output)
            self.assertEqual(f.service.releases, {})
            self.assertEqual(f.service.mutations, [])


class NativeEventPackageTests(unittest.TestCase):
    """Same events through actual signing/ZIP/DMG CLI, never mocked native tools."""
    @classmethod
    def setUpClass(cls): recovery.RecoveryTests.setUpClass()

    @classmethod
    def tearDownClass(cls): recovery.RecoveryTests.tearDownClass()

    def setUp(self):
        # Reuse the existing native fixture/builder seam. Only Xcode is substituted.
        self.native = recovery.RecoveryTests()
        self.native.setUp()
        self.addCleanup(self.native.doCleanups)

    def publish_native_event(self, method):
        native = self.native
        # Replace only the Git source tree with a real merge-method fixture;
        # preserve the fixture package CLI/configuration files tracked by Git.
        f = EventFixture(native.root/'event-source')
        import shutil
        for folder in ('Scripts', 'Config'):
            shutil.copytree(native.source/folder, f.source/folder)
        f.git('add', '.')
        f.git('commit', '-qm', 'package fixture tools')
        f.base = f.git('rev-parse', 'HEAD')
        event = f.merged(method, docs=True, fork=True)
        f.service = native.service
        f.api = native.api
        native.source = f.source
        plan = f.command(event, 'reserve')
        output = native.package(plan)
        f.command(event, 'publish', output)
        release, downloaded = native.published(plan)
        self.assertEqual(release['target_commitish'], event['pull_request']['merge_commit_sha'])
        self.assertEqual(set(downloaded), {'Stash-macOS.zip', 'Stash-macOS.dmg',
                                         'metadata.json', 'SHA256SUMS'})
        self.assertEqual(json.loads(downloaded['metadata.json'])['commit'], plan['commit'])
        before = copy.deepcopy(native.service.downloads)
        f.command(event, 'publish', output)
        self.assertEqual(native.service.downloads, before)

    def test_native_merge_documentation_fork_package(self): self.publish_native_event('merge')
    def test_native_squash_documentation_fork_package(self): self.publish_native_event('squash')
    def test_native_rebase_documentation_fork_package(self): self.publish_native_event('rebase')
