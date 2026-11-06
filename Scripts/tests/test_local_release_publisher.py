import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import shutil
from datetime import datetime, timedelta, timezone
import unittest
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))

import release_pipeline
import local_release_publisher as publisher


class FakeGitHub:
    def __init__(self):
        self.reachable = False
        self.private = True
        self.current = None
        self.releases = {}
        self.objects = {}
        self.publications = 0
        self.fail_upload = None
        self.attempted_commits = []

    def commit_reachable_from_main(self, commit):
        return self.reachable

    def repository_is_private(self):
        return self.private

    def tag_commit(self, tag):
        release = self.releases.get(tag)
        if release and not release['draft']:
            return release['target_commitish']
        return None

    def release(self, tag):
        return self.releases.get(tag)

    def create(self, plan, notes):
        self.current = {
            'id': 1, 'tag_name': plan['tag'], 'target_commitish': plan['commit'],
            'draft': True, 'prerelease': True, 'body': notes, 'assets': [],
        }
        self.releases[plan['tag']] = self.current
        self.attempted_commits.append(plan['commit'])
        return self.current

    def upload(self, release, name, data):
        if self.fail_upload == name:
            raise OSError('simulated upload interruption')
        asset = {
            'id': len(self.objects) + 1, 'name': name, 'size': len(data),
            'digest': 'sha256:' + hashlib.sha256(data).hexdigest(),
        }
        self.objects[name] = data
        release['assets'].append(asset)
        return asset

    def notes(self, release, body):
        release['body'] = body

    def delete(self, asset):
        self.current['assets'] = [item for item in self.current['assets']
                                  if item['id'] != asset['id']]
        self.objects.pop(asset['name'], None)

    def release_by_id(self, release_id):
        return self.current

    def publish(self, release):
        self.publications += 1
        release['draft'] = False
        return release


class LocalPublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit',
                        '--allow-empty', '-qm', 'merge fixture'], check=True)
        self.commit = subprocess.check_output(
            ['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        count = int(subprocess.check_output(
            ['git', '-C', str(self.repo), 'rev-list', '--count', self.commit], text=True))
        self.plan = release_pipeline.identity('0.1.1', count, self.commit)
        self.queue = self.root / 'queue'
        self.queue.mkdir(mode=0o700)
        self.entry = self.queue / self.commit
        self.service = FakeGitHub()
        self.now = datetime(2026, 10, 28, tzinfo=timezone.utc)
        self.write_entry(self.entry, self.now)

    def write_entry(self, directory, created_at, plan=None):
        plan = plan or self.plan
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        data = {'Stash-macOS.zip': b'universal app zip', 'Stash-macOS.dmg': b'disk image'}
        for name, content in data.items():
            (directory / name).write_bytes(content)
        digests = {name: hashlib.sha256(content).hexdigest()
                   for name, content in data.items()}
        receipt = {
            **plan, 'package_format': 2, 'sha256': digests['Stash-macOS.zip'],
            'dmg_sha256': digests['Stash-macOS.dmg'], 'signing': 'ad-hoc',
            'notarized': False,
        }
        (directory / 'metadata.json').write_text(json.dumps(receipt))
        (directory / 'SHA256SUMS').write_text(''.join(
            f'{digests[name]}  {name}\n' for name in data))
        assets = {**data, 'metadata.json': (directory / 'metadata.json').read_bytes(),
                  'SHA256SUMS': (directory / 'SHA256SUMS').read_bytes()}
        manifest = {
            'schema': 1, 'plan': plan,
            'created_at': created_at.isoformat(),
            'assets': {name: {'sha256': hashlib.sha256(content).hexdigest(),
                              'size': len(content)} for name, content in assets.items()},
        }
        (directory / 'manifest.json').write_text(json.dumps(manifest))

    def run_queue(self, **kwargs):
        kwargs.setdefault('validate_package', lambda directory, plan: release_pipeline.package_assets(
            directory, plan, require_dmg=True))
        return publisher.run_pending(
            self.repo, self.queue, self.service, now=self.now,
            plan_lookup=lambda _api, commit: self.plan if commit == self.commit else
            release_pipeline.identity('0.1.2', 2, commit), **kwargs)

    def test_empty_queue_does_not_contact_github(self):
        shutil.rmtree(self.entry)
        self.run_queue()
        self.assertIsNone(self.service.current)

    def test_publication_waits_for_exact_commit_reachability(self):
        result = self.run_queue()
        self.assertEqual(result, [{'commit': self.commit, 'status': 'waiting-for-origin-main'}])
        self.assertTrue(self.entry.exists())
        self.assertIsNone(self.service.current)

        self.service.reachable = True
        result = self.run_queue()
        self.assertEqual(result, [{'commit': self.commit, 'tag': self.plan['tag'],
                                   'status': 'published'}])
        self.assertFalse(self.entry.exists())
        self.assertEqual(self.service.publications, 1)
        self.assertEqual(set(self.service.objects), {
            'Stash-macOS.zip', 'Stash-macOS.dmg', 'SHA256SUMS', 'metadata.json'})
        self.assertIn(f'Commit: {self.commit}', self.service.current['body'])
        self.assertIn('unnotarized', self.service.current['body'].lower())

    def test_unreachable_earlier_commit_blocks_later_reachable_publication(self):
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit',
                        '--allow-empty', '-qm', 'second merge'], check=True)
        second_commit = subprocess.check_output(
            ['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        second_plan = release_pipeline.identity('0.1.2', 2, second_commit)
        second_entry = self.queue / second_commit
        self.write_entry(second_entry, self.now, plan=second_plan)
        reachability = {self.commit: False, second_commit: True}
        self.service.commit_reachable_from_main = lambda commit: reachability[commit]
        validation_order = []

        def validate(_directory, plan):
            validation_order.append(plan['commit'])
            return {
                'Stash-macOS.zip': b'zip', 'Stash-macOS.dmg': b'dmg',
                'SHA256SUMS': b'sums', 'metadata.json': b'metadata',
            }

        results = self.run_queue(validate_package=validate)

        self.assertEqual(results, [{'commit': self.commit, 'status': 'waiting-for-origin-main'}])
        self.assertEqual(validation_order, [])
        self.assertTrue(self.entry.exists())
        self.assertTrue(second_entry.exists())
        self.assertIsNone(self.service.current)

    def test_remote_lookup_failure_keeps_package_for_a_later_retry(self):
        def unavailable(_commit):
            raise release_pipeline.GitHubTransportError('temporary lookup failure')

        self.service.commit_reachable_from_main = unavailable
        with self.assertRaisesRegex(release_pipeline.GitHubTransportError, 'lookup failure'):
            self.run_queue()
        self.assertTrue(self.entry.exists())
        self.assertIsNone(self.service.current)

    def test_interrupted_upload_keeps_queue_and_retry_publishes_once(self):
        self.service.reachable = True
        self.service.fail_upload = 'SHA256SUMS'
        with self.assertRaisesRegex(OSError, 'simulated upload interruption'):
            self.run_queue()
        self.assertTrue(self.entry.exists())
        self.assertTrue(self.service.current['draft'])

        self.service.fail_upload = None
        self.assertEqual(self.run_queue(), [{'commit': self.commit, 'tag': self.plan['tag'],
                                             'status': 'published'}])
        self.assertEqual(self.service.publications, 1)
        self.assertFalse(self.entry.exists())

    def test_queued_commits_remain_ordered_and_retry_after_an_individual_failure(self):
        self.service.reachable = True
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', 'commit',
                        '--allow-empty', '-qm', 'second merge'], check=True)
        second_commit = subprocess.check_output(
            ['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        second_plan = release_pipeline.identity('0.1.2', 2, second_commit)
        second_entry = self.queue / second_commit
        self.write_entry(second_entry, self.now, plan=second_plan)
        validation_order = []
        fail_first_attempt = [True]

        def validate(directory, plan):
            validation_order.append(plan['commit'])
            if plan['commit'] == self.commit and fail_first_attempt[0]:
                fail_first_attempt[0] = False
                raise ValueError('simulated first package validation failure')
            return release_pipeline.package_assets(directory, plan, require_dmg=True)

        with self.assertRaisesRegex(ValueError, 'simulated first package validation failure'):
            self.run_queue(validate_package=validate)

        self.assertEqual(validation_order, [self.commit])
        self.assertEqual(self.service.attempted_commits, [])
        self.assertTrue(self.entry.exists())
        self.assertTrue(second_entry.exists())

        validation_order.clear()
        results = self.run_queue(validate_package=validate)
        self.assertEqual(validation_order, [self.commit, second_commit])
        self.assertEqual(self.service.attempted_commits, [self.commit, second_commit])
        self.assertEqual([item['status'] for item in results], ['published', 'published'])
        self.assertFalse(self.entry.exists())
        self.assertFalse(second_entry.exists())
        self.assertEqual(self.service.publications, 2)

    def test_duplicate_publication_run_preserves_published_bytes(self):
        self.service.reachable = True
        retain_queue = lambda _directory, _root: None
        self.run_queue(remove_pending=retain_queue)
        original = dict(self.service.objects)
        self.run_queue(remove_pending=retain_queue)
        self.assertEqual(self.service.publications, 1)
        self.assertEqual(self.service.objects, original)

    def test_expired_queue_after_publication_is_verified_without_rebuilding(self):
        self.service.reachable = True
        retain_queue = lambda _directory, _root: None
        self.run_queue(remove_pending=retain_queue)
        original = dict(self.service.objects)
        self.write_entry(self.entry, self.now - timedelta(days=8))

        def unexpected_rebuild(*_args):
            raise AssertionError('published release must not be rebuilt')

        self.run_queue(rebuild_package=unexpected_rebuild, remove_pending=retain_queue)
        self.assertEqual(self.service.publications, 1)
        self.assertEqual(self.service.objects, original)

    def test_conflicting_remote_identity_keeps_local_queue(self):
        self.service.reachable = True
        self.service.current = {
            'id': 1, 'tag_name': self.plan['tag'], 'target_commitish': 'f' * 40,
            'draft': True, 'prerelease': True, 'assets': [], 'body': 'conflict',
        }
        self.service.releases[self.plan['tag']] = self.service.current
        with self.assertRaisesRegex(ValueError, 'release identity conflicts'):
            self.run_queue()
        self.assertTrue(self.entry.exists())
        self.assertEqual(self.service.publications, 0)

    def test_public_repository_is_rejected_before_publication(self):
        self.service.reachable = True
        self.service.private = False
        with self.assertRaisesRegex(ValueError, 'public repository'):
            self.run_queue()
        self.assertTrue(self.entry.exists())
        self.assertIsNone(self.service.current)

    def test_expired_package_rebuild_uses_original_commit_and_identity(self):
        self.service.reachable = True
        self.write_entry(self.entry, self.now - timedelta(days=8))
        rebuilt = []

        def rebuild(repo, queue, commit, plan):
            rebuilt.append((repo, queue, commit, plan))
            backup = self.queue / '.expired-backup'
            self.entry.rename(backup)
            self.write_entry(self.entry, self.now)
            shutil.rmtree(backup)
            return {'directory': str(self.entry), 'plan': plan}

        self.run_queue(rebuild_package=rebuild)
        self.assertEqual(rebuilt, [(self.repo, self.queue, self.commit, self.plan)])
        self.assertEqual(self.service.current['target_commitish'], self.commit)
        self.assertEqual(self.service.publications, 1)

    def test_failed_expiry_rebuild_restores_original_queued_package(self):
        with patch.object(publisher.local_release, 'prepare_commit',
                          side_effect=RuntimeError('simulated local rebuild failure')):
            with self.assertRaisesRegex(RuntimeError, 'simulated local rebuild failure'):
                publisher.rebuild_expired_package(self.repo, self.queue, self.commit, self.plan)
        self.assertTrue(self.entry.is_dir())
        self.assertFalse((self.queue / f'.{self.commit}.expired').exists())

    def test_expiry_rebuild_auth_failure_requests_terminal_retry_and_retains_package(self):
        original = {path.name: path.read_bytes() for path in self.entry.iterdir()}
        failure = subprocess.CalledProcessError(1, ['/usr/bin/sudo', '-v'])
        with patch.object(publisher.local_release, 'prepare_commit', side_effect=failure):
            with self.assertRaisesRegex(RuntimeError, 'retry.*terminal.*authenticate'):
                publisher.rebuild_expired_package(self.repo, self.queue, self.commit, self.plan)
        self.assertEqual({path.name: path.read_bytes() for path in self.entry.iterdir()}, original)
        self.assertFalse((self.queue / f'.{self.commit}.expired').exists())

    def test_expiry_rebuild_preserves_unrelated_command_failures(self):
        failure = subprocess.CalledProcessError(1, ['/usr/bin/sudo', '-n', 'other-command'])
        with patch.object(publisher.local_release, 'prepare_commit', side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                publisher.rebuild_expired_package(self.repo, self.queue, self.commit, self.plan)
        self.assertIs(raised.exception, failure)
        self.assertTrue(self.entry.is_dir())
        self.assertFalse((self.queue / f'.{self.commit}.expired').exists())

    def test_expiry_rebuild_invokes_package_preparation_for_original_commit(self):
        self.write_entry(self.entry, self.now - timedelta(days=8))

        def prepare(repo, commit, queue):
            self.assertEqual((repo, commit, queue), (self.repo, self.commit, self.queue))
            self.write_entry(self.entry, self.now)
            return publisher.local_release.read_pending(self.entry, commit, repo)

        with patch.object(publisher.local_release, 'prepare_commit', side_effect=prepare) as build:
            result = publisher.rebuild_expired_package(
                self.repo, self.queue, self.commit, self.plan)

        build.assert_called_once_with(self.repo, self.commit, self.queue)
        self.assertEqual(result['plan'], self.plan)
        self.assertTrue(self.entry.exists())
        self.assertFalse((self.queue / f'.{self.commit}.expired').exists())

    def test_interrupted_expiry_rebuild_recovers_the_original_queue_entry(self):
        backup = self.queue / f'.{self.commit}.expired'
        self.entry.rename(backup)
        result = self.run_queue()
        self.assertEqual(result, [{'commit': self.commit, 'status': 'waiting-for-origin-main'}])
        self.assertTrue(self.entry.is_dir())
        self.assertFalse(backup.exists())

    def test_loaded_publisher_skips_an_overlapping_run(self):
        descriptor = os.open(self.queue / '.publisher.lock', os.O_CREAT | os.O_RDWR, 0o600)
        try:
            import fcntl
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_queue(), [])
            self.assertIsNone(self.service.current)
            self.assertTrue(self.entry.exists())
        finally:
            os.close(descriptor)

    def test_launch_agent_is_configured_for_login_and_periodic_queue_checks(self):
        template = Path(__file__).parents[1] / 'launch_agents' / \
            'com.kfathy.stash-local-release-publisher.plist'
        with template.open('rb') as stream:
            agent = plistlib.load(stream)
        self.assertEqual(agent['Label'], publisher.PUBLISHER_LABEL)
        self.assertTrue(agent['RunAtLoad'])
        self.assertEqual(agent['StartInterval'], 300)
        self.assertIn('run', agent['ProgramArguments'])
        self.assertIn('--repo', agent['ProgramArguments'])
        script = Path(__file__).parents[1] / 'install_local_release_publisher.sh'
        checked = subprocess.run(['/bin/sh', '-n', str(script)], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_installer_install_status_retry_and_disable_use_the_owner_session(self):
        fake_bin = self.root / 'fake-bin'
        fake_bin.mkdir()
        state = self.root / 'launch-agent-loaded'
        disabled_state = self.root / 'launch-agent-disabled'
        log = self.root / 'launchctl.log'
        launchctl = fake_bin / 'launchctl'
        launchctl.write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$LAUNCHCTL_LOG"
case "$1" in
  print) [ -f "$LAUNCHCTL_STATE" ] ;;
  bootstrap) [ ! -f "$LAUNCHCTL_DISABLED" ] || exit 1; touch "$LAUNCHCTL_STATE" ;;
  bootout) rm -f "$LAUNCHCTL_STATE" ;;
  disable) touch "$LAUNCHCTL_DISABLED" ;;
  enable) rm -f "$LAUNCHCTL_DISABLED" ;;
  *) exit 2 ;;
esac
""")
        launchctl.chmod(0o755)
        home = self.root / 'owner-home'
        home.mkdir(mode=0o700)
        env = dict(os.environ, HOME=str(home), PATH=f'{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                   LAUNCHCTL_STATE=str(state), LAUNCHCTL_DISABLED=str(disabled_state),
                   LAUNCHCTL_LOG=str(log))
        source_scripts = Path(__file__).parents[1]
        scripts = self.repo / 'Scripts'
        scripts.mkdir()
        for name in ('install_local_release_publisher.sh', 'local_release_publisher.py',
                     'local_release.py', 'release_pipeline.py', 'release_versions.py',
                     'package_release.py', 'release_metadata.py'):
            shutil.copy2(source_scripts / name, scripts / name)
        shutil.copytree(source_scripts / 'launch_agents', scripts / 'launch_agents')
        installer = scripts / 'install_local_release_publisher.sh'

        def invoke(action):
            return subprocess.run(['/bin/sh', str(installer), action], env=env,
                                  capture_output=True, text=True, check=False)

        installed = invoke('install')
        self.assertEqual(installed.returncode, 0, installed.stderr)
        install_root = home / 'Library' / 'Application Support' / 'Stash' / 'LocalRelease' / 'Publisher'
        plist_path = home / 'Library' / 'LaunchAgents' / f'{publisher.PUBLISHER_LABEL}.plist'
        self.assertTrue((install_root / 'local_release_publisher.py').is_file())
        self.assertTrue(state.exists())
        with plist_path.open('rb') as stream:
            installed_plist = plistlib.load(stream)
        self.assertIn(str(install_root / 'local_release_publisher.py'),
                      installed_plist['ProgramArguments'])

        status = invoke('status')
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn('LaunchAgent is loaded', status.stdout)
        self.assertIn('"queued_commits": []', status.stdout)

        retry = invoke('retry')
        self.assertEqual(retry.returncode, 0, retry.stderr)
        queue = home / 'Library' / 'Caches' / 'Stash' / 'DevelopmentReleases'
        queue.mkdir(parents=True)
        queued_package = queue / 'retained-package'
        queued_package.write_bytes(b'pending package')
        disabled = invoke('disable')
        self.assertEqual(disabled.returncode, 0, disabled.stderr)
        self.assertFalse(state.exists())
        login = subprocess.run([str(launchctl), 'bootstrap', f'gui/{os.getuid()}',
                                str(plist_path)], env=env, capture_output=True)
        self.assertNotEqual(login.returncode, 0)
        self.assertFalse(state.exists())
        self.assertEqual(queued_package.read_bytes(), b'pending package')
        reinstalled = invoke('install')
        self.assertEqual(reinstalled.returncode, 0, reinstalled.stderr)
        self.assertTrue(state.exists())
        self.assertFalse(disabled_state.exists())
        self.assertEqual(queued_package.read_bytes(), b'pending package')
        calls = log.read_text().splitlines()
        self.assertTrue(any(call.startswith('bootstrap gui/') for call in calls))
        self.assertTrue(any(call.startswith('bootout gui/') for call in calls))


if __name__ == '__main__':
    unittest.main()
