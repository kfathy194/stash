import hashlib
from contextlib import ExitStack, contextmanager
import grp
import importlib.util
import io
import json
import os
import pwd
import select
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_pipeline

spec = importlib.util.spec_from_file_location(
    'local_release', Path(__file__).parents[1] / 'local_release.py')
local_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local_release)


class PushMergeDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'base.txt').write_text('base\n')
        self.git('add', 'base.txt')
        self.git('commit', '-m', 'base')
        self.old = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(
            ['git', '-C', str(self.repo), *args], text=True).strip()

    def test_finds_main_merge_and_skips_other_refs(self):
        self.git('switch', '-c', 'feature')
        (self.repo / 'feature.txt').write_text('feature\n')
        self.git('add', 'feature.txt')
        self.git('commit', '-m', 'feature')
        self.git('switch', 'main')
        self.git('merge', '--no-ff', 'feature', '-m', 'Merge feature')
        merge = self.git('rev-parse', 'HEAD')

        records = [
            f'refs/heads/main {merge} refs/heads/main {self.old}',
            f'refs/heads/feature {merge} refs/heads/feature {self.old}',
        ]

        self.assertEqual(local_release.pushed_merge_commits(records, self.repo), [merge])

    def test_main_push_without_a_merge_has_no_release(self):
        (self.repo / 'linear.txt').write_text('linear\n')
        self.git('add', 'linear.txt')
        self.git('commit', '-m', 'linear change')
        head = self.git('rev-parse', 'HEAD')

        record = f'refs/heads/main {head} refs/heads/main {self.old}'

        self.assertEqual(local_release.pushed_merge_commits([record], self.repo), [])

    def test_multiple_main_merges_are_returned_in_first_parent_order(self):
        self.git('switch', '-c', 'first-feature')
        (self.repo / 'first.txt').write_text('first\n')
        self.git('add', 'first.txt')
        self.git('commit', '-m', 'first feature')
        self.git('switch', 'main')
        self.git('merge', '--no-ff', 'first-feature', '-m', 'Merge first feature')
        first_merge = self.git('rev-parse', 'HEAD')

        self.git('switch', '-c', 'second-feature')
        (self.repo / 'second.txt').write_text('second\n')
        self.git('add', 'second.txt')
        self.git('commit', '-m', 'second feature')
        self.git('switch', 'main')
        self.git('merge', '--no-ff', 'second-feature', '-m', 'Merge second feature')
        second_merge = self.git('rev-parse', 'HEAD')

        record = f'refs/heads/main {second_merge} refs/heads/main {self.old}'

        self.assertEqual(
            local_release.pushed_merge_commits([record], self.repo),
            [first_merge, second_merge])

    def test_non_fast_forward_main_push_fails_closed(self):
        self.git('checkout', '--orphan', 'unrelated')
        self.git('rm', '-rf', '.')
        (self.repo / 'unrelated.txt').write_text('unrelated\n')
        self.git('add', 'unrelated.txt')
        self.git('commit', '-m', 'unrelated')
        unrelated = self.git('rev-parse', 'HEAD')

        record = f'refs/heads/main {unrelated} refs/heads/main {self.old}'

        with self.assertRaises(ValueError):
            local_release.pushed_merge_commits([record], self.repo)

    def test_new_remote_main_fails_closed(self):
        record = f'refs/heads/main {self.old} refs/heads/main {local_release.ZERO_SHA}'

        with self.assertRaises(ValueError):
            local_release.pushed_merge_commits([record], self.repo)

    def test_non_origin_push_does_not_reserve_or_build(self):
        with patch.object(local_release, 'pushed_merge_commits', side_effect=AssertionError):
            self.assertEqual(local_release.prepare_push('backup', [], self.repo, self.repo / 'queue'), [])

    def test_pushes_without_eligible_merges_do_not_start_privilege_helper(self):
        records = (
            [],
            [f'refs/heads/feature {self.old} refs/heads/feature {self.old}'],
            [f'refs/tags/v1 {self.old} refs/tags/v1 {local_release.ZERO_SHA}'],
            [f'refs/heads/main {self.old} refs/heads/main {self.old}'],
        )
        with patch.object(local_release, 'sudo_keepalive', side_effect=AssertionError('unexpected helper')):
            for updates in records:
                with self.subTest(records=updates):
                    self.assertEqual(local_release.prepare_push('origin', updates, self.repo), [])

    def test_sudo_keepalive_stops_after_normal_exit_and_parent_signals(self):
        for exit_kind in ('normal', 'exception', signal.SIGTERM, signal.SIGKILL):
            with self.subTest(exit=exit_kind):
                marker = self.repo / f'refresh-{exit_kind}'
                fake_sudo = self.repo / 'fake-sudo'
                fake_sudo.write_text(f"#!/bin/sh\nprintf . >> '{marker}'\n")
                fake_sudo.chmod(0o700)
                # Replace only the privilege boundary before spawning any child.
                # No test process ever invokes real sudo or changes credentials.
                source = f"""
import importlib.util, os, subprocess, sys, time
spec = importlib.util.spec_from_file_location('local_release', {str(Path(local_release.__file__))!r})
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
spawn = subprocess.Popen
def harmless_spawn(command, **kwargs):
    assert any('/usr/bin/sudo' in part for part in command), command
    command = [part.replace('/usr/bin/sudo', {str(fake_sudo)!r}) for part in command]
    return spawn(command, **kwargs)
release.subprocess.Popen = harmless_spawn
try:
    with release.sudo_keepalive(interval=0.05) as child:
        assert os.getsid(child.pid) == os.getsid(0), 'controlling-terminal session changed'
        assert os.getpgid(child.pid) == child.pid, 'cleanup process group missing'
        print(child.pid, flush=True)
        while not os.path.exists({str(marker)!r}):
            time.sleep(0.01)
        if {exit_kind == 'exception'!r}:
            raise RuntimeError('fixture build failure')
        if {isinstance(exit_kind, int)!r}:
            time.sleep(60)
except RuntimeError:
    pass
"""
                owner = subprocess.Popen(
                    [sys.executable, '-c', source], stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True)
                child_pid = None
                try:
                    self.assertTrue(select.select([owner.stdout], [], [], 3)[0], 'owner never started')
                    child_pid = int(owner.stdout.readline())
                    deadline = time.monotonic() + 3
                    while not marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(marker.exists(), 'fake refresh never ran')
                    if isinstance(exit_kind, int):
                        owner.send_signal(exit_kind)
                    owner.wait(timeout=3)
                    self.assertEqual(owner.returncode, -exit_kind if isinstance(exit_kind, int) else 0,
                                     owner.stderr.read())
                    deadline = time.monotonic() + 2
                    while self.keepalive_is_running(child_pid) and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertFalse(self.keepalive_is_running(child_pid), 'keepalive outlived its owner')
                    refreshes = marker.read_bytes()
                    time.sleep(0.12)
                    self.assertEqual(marker.read_bytes(), refreshes, 'refreshes continued after parent exit')
                finally:
                    if owner.poll() is None:
                        owner.kill()
                    owner.communicate(timeout=3)
                    # Only signal a real child PID reported by this fixture.
                    if child_pid and self.keepalive_is_running(child_pid):
                        os.killpg(child_pid, signal.SIGKILL)

    @staticmethod
    def keepalive_is_running(pid):
        status = subprocess.run(
            ['/bin/ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
        return status.returncode == 0 and not status.stdout.strip().startswith('Z')

    def test_prepare_push_keeps_sudo_alive_across_the_whole_build(self):
        record = f'refs/heads/main {self.old} refs/heads/main {self.old}'
        with patch.object(local_release, 'pushed_merge_commits', return_value=[self.old]), \
                patch.object(local_release, 'prepare_commit', return_value={'plan': {}}) as prepare, \
                patch.object(local_release, 'sudo_keepalive') as keepalive:
            releases = local_release.prepare_push(
                'origin', [record], self.repo, self.repo / 'queue')

        self.assertEqual(releases, [{'plan': {}}])
        self.assertEqual(prepare.call_count, 1)
        self.assertEqual(keepalive.call_count, 1)
        keepalive.return_value.__enter__.assert_called_once()
        keepalive.return_value.__exit__.assert_called_once()

    def test_entrypoint_skips_non_origin_when_origin_is_not_configured(self):
        argv = ['local_release.py', 'pre-push', 'backup', 'https://example.invalid/repo.git']
        with patch.object(sys, 'argv', argv), patch.object(sys, 'stdin', io.StringIO()), \
                patch.object(local_release.Path, 'cwd', return_value=self.repo), \
                patch.object(local_release, 'prepare_push') as prepare:
            local_release.main()

        prepare.assert_not_called()

    def test_installer_refuses_to_suppress_active_default_hook(self):
        repo = Path(self.temp.name) / 'installer-fixture'
        repo.mkdir()
        subprocess.run(['git', 'init', str(repo)], check=True, capture_output=True)
        scripts = repo / 'Scripts'
        scripts.mkdir()
        installer = scripts / 'install_local_release_hook.sh'
        installer.write_bytes((Path(__file__).parents[1] / 'install_local_release_hook.sh').read_bytes())
        hooks_path = subprocess.check_output(
            ['git', '-C', str(repo), 'rev-parse', '--git-path', 'hooks'], text=True).strip()
        hooks = Path(hooks_path)
        if not hooks.is_absolute():
            hooks = repo / hooks
        active_hook = hooks / 'pre-commit'
        active_hook.write_text('#!/bin/sh\nexit 0\n')
        active_hook.chmod(0o755)

        result = subprocess.run(['bash', str(installer)], capture_output=True, text=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('active default hook', result.stderr)
        self.assertEqual(active_hook.read_text(), '#!/bin/sh\nexit 0\n')
        configured = subprocess.run(
            ['git', '-C', str(repo), 'config', '--local', '--get', 'core.hooksPath'],
            capture_output=True, text=True)
        self.assertNotEqual(configured.returncode, 0)

    def test_installer_refuses_to_replace_explicit_active_githooks_path(self):
        repo = Path(self.temp.name) / 'configured-hooks-fixture'
        repo.mkdir()
        subprocess.run(['git', 'init', str(repo)], check=True, capture_output=True)
        scripts = repo / 'Scripts'
        scripts.mkdir()
        installer = scripts / 'install_local_release_hook.sh'
        installer.write_bytes((Path(__file__).parents[1] / 'install_local_release_hook.sh').read_bytes())
        hooks = repo / '.githooks'
        hooks.mkdir()
        active_hook = hooks / 'pre-push'
        hook_contents = '#!/bin/sh\nprintf custom-hook\n'
        active_hook.write_text(hook_contents)
        active_hook.chmod(0o755)
        subprocess.run(
            ['git', '-C', str(repo), 'config', '--local', 'core.hooksPath', '.githooks'],
            check=True)

        result = subprocess.run(['bash', str(installer)], capture_output=True, text=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('existing core.hooksPath', result.stderr)
        self.assertEqual(
            subprocess.check_output(
                ['git', '-C', str(repo), 'config', '--local', '--get', 'core.hooksPath'],
                text=True).strip(), '.githooks')
        self.assertEqual(active_hook.read_text(), hook_contents)

    def test_installer_copies_hook_helpers_outside_checkout(self):
        repo = Path(self.temp.name) / 'installed-hooks-fixture'
        repo.mkdir()
        subprocess.run(['git', 'init', str(repo)], check=True, capture_output=True)
        project_root = Path(__file__).parents[2]
        scripts = repo / 'Scripts'
        scripts.mkdir()
        for name in ('install_local_release_hook.sh', 'local_release.py',
                     'release_pipeline.py', 'release_versions.py', 'package_release.py',
                     'release_metadata.py'):
            (scripts / name).write_bytes((project_root / 'Scripts' / name).read_bytes())
        hooks = repo / '.githooks'
        hooks.mkdir()
        (hooks / 'pre-push').write_bytes((project_root / '.githooks' / 'pre-push').read_bytes())
        home = Path(self.temp.name) / 'owner-home'
        home.mkdir()
        install_root = home / 'Library' / 'Application Support' / 'Stash' / 'LocalRelease'

        result = subprocess.run(
            ['bash', str(scripts / 'install_local_release_hook.sh')],
            capture_output=True, text=True, env=dict(os.environ, HOME=str(home)))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            subprocess.check_output(
                ['git', '-C', str(repo), 'config', '--local', '--get', 'core.hooksPath'],
                text=True).strip(), str(install_root / 'hooks'))
        self.assertTrue((install_root / 'hooks' / 'pre-push').is_file())
        self.assertTrue(os.access(install_root / 'hooks' / 'pre-push', os.X_OK))
        self.assertEqual(
            (install_root / 'Scripts' / 'local_release.py').read_bytes(),
            (scripts / 'local_release.py').read_bytes())
        self.assertTrue((install_root / 'Scripts' / 'release_pipeline.py').is_file())
        self.assertTrue((install_root / 'Scripts' / 'release_versions.py').is_file())
        self.assertTrue((install_root / 'Scripts' / 'package_release.py').is_file())
        self.assertTrue((install_root / 'Scripts' / 'release_metadata.py').is_file())
        self.assertEqual((install_root / 'Scripts').stat().st_mode & 0o777, 0o700)
        self.assertEqual((install_root / 'Scripts' / 'package_release.py').stat().st_mode & 0o777, 0o600)

    def test_release_reservation_refuses_unexpected_github_repository(self):
        def output(command, **kwargs):
            if command[0] == 'git':
                return '1\n'
            return 'someone/fork\n'

        with patch.object(local_release.subprocess, 'check_output', side_effect=output) as run:
            with self.assertRaisesRegex(ValueError, 'unexpected repository'):
                local_release.reserve_plan(self.repo, self.old)

        self.assertEqual(run.call_count, 2)

    def test_builder_preflight_rejects_an_admin_account(self):
        with patch.object(local_release.Path, 'home', return_value=Path('/Users/fixture-owner')), \
                patch.object(local_release.subprocess, 'check_output', side_effect=[
                'NFSHomeDirectory: /Users/stashbuild\n', 'staff admin\n']), \
                patch.object(local_release.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'standard macOS account'):
                local_release.builder_home()

        run.assert_not_called()

    def test_builder_preflight_requires_no_sudo_rights_and_no_owner_home_access(self):
        with patch.object(local_release.Path, 'home', return_value=Path('/Users/fixture-owner')), \
                patch.object(local_release.subprocess, 'check_output', side_effect=[
                'NFSHomeDirectory: /Users/stashbuild\n', 'staff\n',
                'UserShell: /usr/bin/false\n']), \
                patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'validate_builder_home'), \
                patch.object(local_release, 'assert_no_builder_sessions'), \
                patch.object(local_release, 'inspect_builder_system_services', return_value=True), \
                patch.object(local_release.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1),
                    subprocess.CompletedProcess([], 0)]) as run:
            home = local_release.builder_home()

        self.assertEqual(home, Path('/Users/stashbuild'))
        calls = [call.args[0] for call in run.call_args_list]
        self.assertIn('-n', calls[1])
        self.assertIn('test ! -r', ' '.join(calls[2]))
        self.assertIn('test ! -x', ' '.join(calls[2]))
        self.assertEqual(len(calls), 3)

    def test_builder_preflight_rejects_interactive_account(self):
        with patch.object(local_release.Path, 'home', return_value=Path('/Users/fixture-owner')), \
                patch.object(local_release.subprocess, 'check_output', side_effect=[
                'NFSHomeDirectory: /Users/stashbuild\n', 'staff\n',
                'UserShell: /bin/zsh\n']), \
                patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'validate_builder_home'):
            with self.assertRaisesRegex(ValueError, 'non-interactive'):
                local_release.builder_home()

    def test_builder_preflight_rejects_nonempty_crontab_and_allows_empty(self):
        with patch.object(local_release, 'read_builder_crontab', return_value=b''):
            self.assertEqual(local_release.assert_no_builder_crontab(), b'')
        with patch.object(local_release, 'read_builder_crontab', return_value=b'@reboot run-me\n'):
            with self.assertRaisesRegex(ValueError, 'nonempty crontab'):
                local_release.assert_no_builder_crontab()

    def test_crontab_cleanup_removes_new_table_and_fails(self):
        with patch.object(local_release, 'read_builder_crontab', side_effect=[b'* * * * * run-me\n', None]), \
                patch.object(local_release, 'remove_builder_crontab') as remove:
            with self.assertRaisesRegex(ValueError, 'changed the stashbuild crontab'):
                local_release.cleanup_builder_crontab(None)

        remove.assert_called_once_with()

    def test_crontab_cleanup_restores_preexisting_empty_table(self):
        with patch.object(local_release, 'read_builder_crontab', side_effect=[b'@reboot run-me\n', b'']), \
                patch.object(local_release, 'remove_builder_crontab') as remove, \
                patch.object(local_release, 'install_builder_crontab') as install:
            with self.assertRaisesRegex(ValueError, 'original state was restored'):
                local_release.cleanup_builder_crontab(b'')

        remove.assert_called_once_with()
        install.assert_called_once_with(b'')

    def test_crontab_reader_is_bounded_and_distinguishes_missing_tables(self):
        with patch.object(local_release, 'read_bounded_command_output',
                          return_value=(0, b'* * * * * run-me\n')) as read:
            self.assertEqual(local_release.read_builder_crontab(), b'* * * * * run-me\n')
        self.assertEqual(read.call_args.args[1:5], (
            local_release.MAX_ATQ_OUTPUT_BYTES, local_release.MAX_AT_JOBS, 5,
            'stashbuild crontab'))
        self.assertTrue(read.call_args.kwargs['merge_stderr'])

        with patch.object(local_release, 'read_bounded_command_output',
                          return_value=(1, b'no crontab for stashbuild\n')):
            self.assertIsNone(local_release.read_builder_crontab())
        with patch.object(local_release, 'read_bounded_command_output',
                          return_value=(1, b'permission denied\n')):
            with self.assertRaisesRegex(OSError, 'status 1'):
                local_release.read_builder_crontab()

    def test_bounded_reader_allows_expected_missing_crontab_status(self):
        command = [sys.executable, '-c',
                   "import sys; sys.stderr.write('no crontab for stashbuild\\n'); sys.exit(1)"]
        status, output = local_release.read_bounded_command_output(
            command, 1024, 10, 5, 'fixture crontab', merge_stderr=True,
            allowed_return_codes=(0, 1))
        self.assertEqual(status, 1)
        self.assertEqual(output, b'no crontab for stashbuild\n')

        with self.assertRaisesRegex(OSError, 'exit status 1'):
            local_release.read_bounded_command_output(
                command, 1024, 10, 5, 'fixture atq', merge_stderr=True)

    def test_crontab_preflight_fails_closed_when_existing_table_exceeds_limits(self):
        for message in ('crontab output exceeds byte limit', 'crontab exceeds line limit'):
            with self.subTest(message=message), \
                    patch.object(local_release, 'read_builder_crontab',
                                 side_effect=local_release.OutputLimitError(message)):
                with self.assertRaisesRegex(local_release.OutputLimitError, message):
                    local_release.assert_no_builder_crontab()

    def test_crontab_cleanup_removes_oversized_table_and_restores_empty_original(self):
        for message in ('too many bytes', 'too many lines'):
            with self.subTest(message=message), \
                    patch.object(local_release, 'read_builder_crontab', side_effect=[
                        local_release.OutputLimitError(message), b'']), \
                    patch.object(local_release, 'remove_builder_crontab') as remove, \
                    patch.object(local_release, 'install_builder_crontab') as install:
                with self.assertRaisesRegex(ValueError, 'oversized stashbuild crontab'):
                    local_release.cleanup_builder_crontab(b'')

            remove.assert_called_once_with()
            install.assert_called_once_with(b'')

    def test_builder_preflight_rejects_existing_at_jobs_and_unknown_atq_errors(self):
        with patch.object(local_release, 'read_builder_at_jobs', return_value=frozenset({'17'})):
            with self.assertRaisesRegex(ValueError, 'pre-existing at jobs'):
                local_release.assert_no_builder_at_jobs()
        with patch.object(local_release, 'read_builder_at_jobs', side_effect=OSError('atq denied')):
            with self.assertRaisesRegex(OSError, 'atq denied'):
                local_release.assert_no_builder_at_jobs()

    def test_atq_reads_only_well_formed_job_ids_for_builder(self):
        with patch.object(local_release, 'read_bounded_command_output',
                           return_value=(0, b'17\tThu Oct 29 11:22:00 2026 a stashbuild\n')) as read:
            self.assertEqual(local_release.read_builder_at_jobs(), frozenset({'17'}))

        self.assertEqual(read.call_args.args[0], [
            '/usr/bin/sudo', '-n', '-u', 'stashbuild', '-H', '/usr/bin/atq'])
        with patch.object(local_release, 'read_bounded_command_output',
                           return_value=(0, b'unexpected output\n')):
            with self.assertRaisesRegex(OSError, 'Cannot parse.*atq output'):
                local_release.read_builder_at_jobs()

    def test_atq_output_byte_and_job_limits_kill_the_command(self):
        cases = (
            (16, 1000, "import os; os.write(1, b'x' * 100000)", 'output exceeds 16 bytes'),
            (1024, 2, "import os; os.write(1, b'1 a\\n2 b\\n3 c\\n')", 'exceeds 2 rows'),
        )
        for max_bytes, max_lines, source, message in cases:
            with self.subTest(message=message), \
                    patch.object(local_release, 'terminate_process_group',
                                 wraps=local_release.terminate_process_group) as terminate:
                with self.assertRaisesRegex(ValueError, message):
                    local_release.read_bounded_command_output(
                        [sys.executable, '-c', source], max_bytes, max_lines, 5, 'fixture atq')
                terminate.assert_called_once()

    def test_atrm_calls_share_one_total_cleanup_deadline(self):
        with patch.object(local_release.time, 'monotonic', side_effect=[100.0, 100.0, 115.0]), \
                patch.object(local_release.subprocess, 'run',
                             side_effect=lambda *args, **kwargs: subprocess.CompletedProcess(
                                 args[0], 0)) as run:
            local_release.remove_builder_at_jobs(frozenset({'1', '2'}))

        self.assertEqual([call.kwargs['timeout'] for call in run.call_args_list], [30.0, 15.0])
        self.assertEqual([call.args[0][-1] for call in run.call_args_list], ['1', '2'])

    def test_atrm_stops_when_total_cleanup_deadline_expires(self):
        with patch.object(local_release.time, 'monotonic', side_effect=[100.0, 100.0, 131.0]), \
                patch.object(local_release.subprocess, 'run') as run:
            with self.assertRaisesRegex(TimeoutError, 'total time limit'):
                local_release.remove_builder_at_jobs(frozenset({'1', '2'}))

        run.assert_called_once()

    def test_builder_at_cleanup_removes_new_jobs_and_fails_build(self):
        with patch.object(local_release, 'read_builder_at_jobs',
                          side_effect=[frozenset({'17'}), frozenset()]), \
                patch.object(local_release, 'remove_builder_at_jobs') as remove:
            with self.assertRaisesRegex(ValueError, 'at jobs; they were removed'):
                local_release.cleanup_builder_at_jobs(frozenset())

        remove.assert_called_once_with(frozenset({'17'}))

    def test_builder_home_must_be_owned_private_real_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp).resolve() / 'builder-home'
            home.mkdir(mode=0o700)

            local_release.validate_builder_home(home, os.getuid())
            with self.assertRaisesRegex(ValueError, 'private directory'):
                local_release.validate_builder_home(home, os.getuid() + 1)
            home.chmod(0o755)
            with self.assertRaisesRegex(ValueError, 'private directory'):
                local_release.validate_builder_home(home, os.getuid())

            home.chmod(0o700)
            link = Path(temp) / 'builder-link'
            link.symlink_to(home)
            with self.assertRaisesRegex(ValueError, 'private directory'):
                local_release.validate_builder_home(link, os.getuid())

    def test_builder_preflight_rejects_active_login_session(self):
        with patch.object(local_release.subprocess, 'check_output', return_value='stashbuild console  Oct 28\n'), \
                patch.object(local_release, 'builder_has_processes') as processes:
            with self.assertRaisesRegex(ValueError, 'interactive session'):
                local_release.assert_builder_account_idle()

        processes.assert_not_called()

    def test_builder_preflight_rejects_existing_launch_agents(self):
        with patch.object(local_release, 'assert_no_builder_sessions'), \
                patch.object(local_release, 'builder_launch_agents_remain_safely', return_value=True), \
                patch.object(local_release, 'builder_uid', return_value=501):
            with self.assertRaisesRegex(ValueError, 'pre-existing LaunchAgents'):
                local_release.prepare_builder_launchd(self.repo / 'builder-home')

    def test_builder_preflight_normalizes_dormant_user_domain(self):
        with patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'assert_no_builder_sessions'), \
                patch.object(local_release, 'builder_launch_agents_remain_safely', return_value=False), \
                patch.object(local_release, 'inspect_builder_system_services', return_value=False), \
                patch.object(local_release, 'assert_no_builder_crontab', return_value=None), \
                patch.object(local_release, 'assert_no_builder_at_jobs', return_value=frozenset()), \
                patch.object(local_release, 'builder_has_processes', return_value=False), \
                patch.object(local_release, 'clear_builder_launchd_domain') as bootout:
            local_release.prepare_builder_launchd(self.repo / 'builder-home')

        bootout.assert_called_once_with(501)

    def test_builder_preflight_refuses_active_user_domain_without_altering_it(self):
        with patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'assert_no_builder_sessions'), \
                patch.object(local_release, 'builder_launch_agents_remain_safely', return_value=False), \
                patch.object(local_release, 'inspect_builder_system_services',
                             side_effect=ValueError('unknown active process; refusing to alter it')), \
                patch.object(local_release, 'clear_builder_launchd_domain') as bootout:
            with self.assertRaisesRegex(ValueError, 'refusing to alter'):
                local_release.prepare_builder_launchd(self.repo / 'builder-home')

        bootout.assert_not_called()

    def test_launch_agents_inspection_fails_closed_on_inaccessible_directory(self):
        result = subprocess.CompletedProcess([], 4, b'', b'permission denied')
        with patch.object(local_release.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(OSError, 'Cannot inspect LaunchAgents'):
                local_release.inspect_builder_launch_agents(self.repo / 'builder-home')

    def test_safe_launch_agents_cleanup_unlinks_symlink_without_following_it(self):
        with tempfile.TemporaryDirectory(dir=local_release.BUILDER_TEMP_ROOT) as temp:
            home = Path(temp) / 'home'
            library = home / 'Library'
            library.mkdir(parents=True)
            external = Path(temp) / 'external'
            external.mkdir()
            sentinel = external / 'keep.txt'
            sentinel.write_text('keep')
            agents = library / 'LaunchAgents'
            agents.symlink_to(external, target_is_directory=True)
            result = subprocess.run([
                sys.executable, '-c', local_release.SAFE_REMOVE_BUILDER_LAUNCH_AGENTS,
                str(home), str(os.getuid()),
            ], capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(agents.is_symlink())
            self.assertEqual(sentinel.read_text(), 'keep')

    def test_builder_cleanup_removes_stable_and_per_build_launch_agents(self):
        with patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'clear_builder_launchd_domain', return_value=True), \
                patch.object(local_release, 'remove_builder_launch_agents_safely') as remove:
            local_release.cleanup_builder_launchd(
                self.repo / 'stable-home', self.repo / 'workspace' / 'home')

        self.assertEqual(remove.call_count, 2)
        self.assertEqual(remove.call_args_list[0].args,
                         (self.repo / 'stable-home', 501))
        self.assertEqual(remove.call_args_list[1].args,
                         (self.repo / 'workspace' / 'home', 501))

    def test_final_launchd_check_remediates_any_state_and_cleans_scheduled_jobs(self):
        events = []
        dependencies = (
            patch.object(local_release, 'bootout_builder_launchd_domain', return_value=True),
            patch.object(local_release, 'clear_builder_launchd_domain',
                         side_effect=lambda _uid: events.append('bootout')),
            patch.object(local_release, 'terminate_builder_account_processes',
                         side_effect=lambda: events.append('process sweep')),
            patch.object(local_release, 'remove_builder_launch_agents_safely',
                         side_effect=lambda *_args: events.append('remove agents')),
            patch.object(local_release, 'cleanup_builder_crontab', return_value=False),
            patch.object(local_release, 'cleanup_builder_at_jobs', return_value=False),
            patch.object(local_release, 'builder_has_processes',
                         side_effect=[True, False, False, False]),
            patch.object(local_release, 'builder_launch_agents_remain_safely', return_value=False),
            patch.object(local_release, 'read_builder_crontab', return_value=None),
            patch.object(local_release, 'read_builder_at_jobs', return_value=frozenset()),
        )
        with dependencies[0], dependencies[1], dependencies[2], dependencies[3], \
                dependencies[4], dependencies[5], dependencies[6], dependencies[7], \
                dependencies[8], dependencies[9]:
            local_release.verify_builder_launchd_clean(
                self.repo / 'stable-home', self.repo / 'workspace' / 'home', 501,
                None, frozenset())

        self.assertEqual(events[:3], ['bootout', 'process sweep', 'remove agents'])
        self.assertIn('bootout', events)
        self.assertEqual(events.count('bootout'), 1)

    def test_builder_process_appearing_during_cron_cleanup_gets_swept(self):
        events = []
        running = {'process': True}
        with patch.object(local_release, 'bootout_builder_launchd_domain',
                          side_effect=[True, False]), \
                patch.object(local_release, 'clear_builder_launchd_domain',
                             side_effect=lambda _uid: events.append('bootout')), \
                patch.object(local_release, 'terminate_builder_account_processes',
                             side_effect=lambda: (events.append('process sweep'),
                                                  running.update(process=False))) as sweep, \
                patch.object(local_release, 'remove_builder_launch_agents_safely',
                             side_effect=lambda *_args: events.append('remove agents')), \
                patch.object(local_release, 'cleanup_builder_crontab',
                             side_effect=lambda _original: (events.append('remove cron'),
                                                           running.update(process=True))), \
                patch.object(local_release, 'cleanup_builder_at_jobs'), \
                patch.object(local_release, 'builder_has_processes',
                             side_effect=lambda: running['process']), \
                patch.object(local_release, 'builder_launch_agents_remain_safely',
                             side_effect=[True, False, False, False]), \
                patch.object(local_release, 'read_builder_crontab', return_value=None), \
                patch.object(local_release, 'read_builder_at_jobs', return_value=frozenset()):
            local_release.verify_builder_launchd_clean(
                self.repo / 'stable-home', self.repo / 'workspace' / 'home', 501,
                None, frozenset())

        self.assertIn('remove cron', events)
        self.assertLess(events.index('remove cron'), len(events) - 1)
        self.assertEqual(events[-1], 'process sweep')
        self.assertEqual(sweep.call_count, 2)

    def test_final_launchd_check_retries_persistent_domain_once_then_fails_closed(self):
        with patch.object(local_release, 'bootout_builder_launchd_domain',
                          return_value=True), \
                patch.object(local_release, 'clear_builder_launchd_domain'), \
                patch.object(local_release, 'terminate_builder_account_processes'), \
                patch.object(local_release, 'remove_builder_launch_agents_safely'), \
                patch.object(local_release, 'cleanup_builder_crontab', return_value=False), \
                patch.object(local_release, 'cleanup_builder_at_jobs', return_value=False), \
                patch.object(local_release, 'builder_has_processes', return_value=True), \
                patch.object(local_release, 'builder_launch_agents_remain_safely', return_value=False), \
                patch.object(local_release, 'read_builder_crontab', return_value=None), \
                patch.object(local_release, 'read_builder_at_jobs', return_value=frozenset()):
            with self.assertRaisesRegex(RuntimeError, 'quarantine the stashbuild account'):
                local_release.verify_builder_launchd_clean(
                    self.repo / 'stable-home', self.repo / 'workspace' / 'home', 501,
                    None, frozenset())

    @unittest.skipUnless(os.geteuid() == 0, 'requires root for privileged mode-000 cleanup')
    def test_safe_launch_agents_cleanup_handles_mode_000_and_does_not_follow_symlinks(self):
        unprivileged = pwd.getpwnam('nobody')
        with tempfile.TemporaryDirectory(dir=local_release.BUILDER_TEMP_ROOT) as temp:
            home = Path(temp) / 'home'
            agents = home / 'Library' / 'LaunchAgents'
            nested = agents / 'nested'
            nested.mkdir(parents=True)
            (nested / 'job.plist').write_text('job')
            external = Path(temp) / 'external'
            external.mkdir()
            sentinel = external / 'keep.txt'
            sentinel.write_text('keep')
            link = agents / 'external-link'
            link.symlink_to(external, target_is_directory=True)
            for path in (home, home / 'Library', agents, nested, nested / 'job.plist',
                         external, sentinel, link):
                os.chown(path, unprivileged.pw_uid, unprivileged.pw_gid,
                         follow_symlinks=False)
            nested.chmod(0)
            agents.chmod(0)
            result = subprocess.run([
                sys.executable, '-c', local_release.SAFE_REMOVE_BUILDER_LAUNCH_AGENTS,
                str(home), str(unprivileged.pw_uid),
            ], capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(agents.exists())
            self.assertEqual(sentinel.read_text(), 'keep')

    def test_detached_builder_cleanup_escalates_to_uid_scoped_kill(self):
        with patch.object(local_release, 'assert_no_builder_sessions'), \
                patch.object(local_release, 'signal_builder_account') as signal_account, \
                patch.object(local_release, 'wait_for_builder_idle', side_effect=[False, True]) as idle:
            local_release.terminate_builder_account_processes()

        self.assertEqual([call.args[0] for call in signal_account.call_args_list],
                         ['TERM', 'KILL'])
        self.assertEqual(idle.call_args_list[0].args,
                         (local_release.PROCESS_TERMINATION_GRACE_SECONDS,))
        self.assertEqual(idle.call_args_list[1].args,
                         (local_release.BUILDER_CLEANUP_TIMEOUT_SECONDS,))

    def test_builder_spawns_keep_the_terminal_for_sudo_timestamps(self):
        """Child `sudo -n` calls validate the owner's cached per-tty timestamp
        through the controlling terminal; setsid-detached children cannot use
        it. Builder spawns must stay in the session while keeping their own
        process group for killpg-based timeout cleanup."""
        process = unittest.mock.Mock()
        process.wait.return_value = 0
        process.pid = 4321
        with tempfile.TemporaryFile() as empty_pipe:
            process.stdout = empty_pipe
            with patch.object(local_release.subprocess, 'Popen', return_value=process) as popen:
                local_release.run_as_builder(
                    self.repo / 'builder-home', self.old, ['/usr/bin/true'])
                local_release.read_bounded_command_output(
                    ['/usr/bin/true'], 64, 10, 5, 'fixture inspection')

        self.assertEqual(popen.call_count, 2)
        for call in popen.call_args_list:
            self.assertIs(call.kwargs.get('preexec_fn'), local_release.BUILDER_PREEXEC)
            self.assertFalse(call.kwargs.get('start_new_session'))

    def test_builder_invocation_uses_clean_env_without_github_tokens(self):
        home = self.repo / 'builder-home'
        process = unittest.mock.Mock()
        process.wait.return_value = 0
        with patch.dict(os.environ, {'GH_TOKEN': 'do-not-forward', 'GITHUB_TOKEN': 'also-secret'}), \
                patch.object(local_release.subprocess, 'Popen', return_value=process) as popen:
            local_release.run_as_builder(home, self.old, ['/usr/bin/true'])

        args, kwargs = popen.call_args
        self.assertEqual(kwargs['env'], local_release.SUDO_ENV)
        self.assertIs(kwargs['preexec_fn'], local_release.BUILDER_PREEXEC)
        self.assertFalse(kwargs.get('start_new_session'))
        self.assertIn('/usr/bin/env', args[0])
        self.assertIn('-i', args[0])
        self.assertIn('-n', args[0])
        self.assertIn('umask 077', ' '.join(args[0]))
        self.assertNotIn('GH_TOKEN', repr(args))
        self.assertNotIn('GITHUB_TOKEN', repr(args))
        self.assertNotIn('do-not-forward', repr(args))
        self.assertIs(kwargs['stdin'], subprocess.DEVNULL)
        process.wait.assert_called_once_with(timeout=None)

    def test_each_build_uses_home_and_tmp_inside_its_workspace(self):
        workspace = self.repo / 'private-workspace'
        command = local_release.builder_command(
            self.repo / 'builder-home', self.old, ['/usr/bin/true'],
            workspace_root=workspace)
        environment = [part for part in command if part.startswith(('HOME=', 'TMPDIR=', 'CFFIXED_USER_HOME='))]

        self.assertIn(f'HOME={workspace}/home', environment)
        self.assertIn(f'TMPDIR={workspace}/tmp', environment)
        self.assertIn(f'CFFIXED_USER_HOME={workspace}/home', environment)

    def test_machine_wide_lock_blocks_a_second_process_owner(self):
        lock = self.repo / 'machine-builder.lock'
        lock.touch()
        code = '''
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)
sys.exit(1)
'''
        with patch.object(local_release, 'BUILDER_LOCK_PATH', lock), \
                patch.object(local_release, 'prepare_builder_lock'):
            with local_release.builder_account_lock():
                result = subprocess.run(
                    [sys.executable, '-c', code, str(lock)], capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_builder_lock_allows_only_root_admin_group_mode(self):
        admin_gid = grp.getgrnam('admin').gr_gid
        directory = SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
        lock = SimpleNamespace(st_mode=stat.S_IFREG | 0o660, st_uid=0, st_gid=admin_gid)

        local_release.validate_builder_lock_metadata(directory, lock, admin_gid=admin_gid)
        with self.assertRaisesRegex(ValueError, 'not safely provisioned'):
            local_release.validate_builder_lock_metadata(directory, lock, admin_gid=admin_gid + 1)
        lock.st_mode = stat.S_IFREG | 0o666
        with self.assertRaisesRegex(ValueError, 'not safely provisioned'):
            local_release.validate_builder_lock_metadata(directory, lock, admin_gid=admin_gid)

    def test_machine_lock_is_provisioned_root_admin_0660(self):
        admin_gid = grp.getgrnam('admin').gr_gid
        directory = SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
        lock = SimpleNamespace(
            st_mode=stat.S_IFREG | 0o660, st_uid=0, st_gid=admin_gid)
        with patch.object(local_release.subprocess, 'run') as run, \
                patch.object(Path, 'lstat', side_effect=[directory, lock, directory, lock]), \
                patch.object(local_release.grp, 'getgrnam',
                             return_value=SimpleNamespace(gr_gid=admin_gid)):
            local_release.prepare_builder_lock()

        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(any(command[:4] == [
            '/usr/bin/sudo', '-n', '/usr/sbin/chown', 'root:admin',
        ] for command in commands))
        self.assertTrue(any(command[:4] == [
            '/usr/bin/sudo', '-n', '/bin/chmod', '0660',
        ] for command in commands))

    @unittest.skipUnless(os.geteuid() == 0, 'requires root to test an unprivileged account')
    def test_non_admin_account_cannot_open_or_hold_builder_lock(self):
        with tempfile.TemporaryDirectory(dir=local_release.BUILDER_TEMP_ROOT) as temp:
            root = Path(temp)
            lock = root / 'builder.lock'
            lock.touch()
            root.chmod(0o711)
            os.chown(lock, 0, grp.getgrnam('admin').gr_gid)
            lock.chmod(0o660)
            unprivileged = pwd.getpwnam('nobody')
            code = '''
import fcntl, os, sys
os.setgroups([])
os.setgid(int(sys.argv[2]))
os.setuid(int(sys.argv[3]))
try:
    fd = os.open(sys.argv[1], os.O_RDWR)
except PermissionError:
    sys.exit(0)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
sys.exit(1)
'''
            result = subprocess.run(
                [sys.executable, '-c', code, str(lock), str(unprivileged.pw_gid),
                 str(unprivileged.pw_uid)], capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_builder_lock_wait_has_a_visible_timeout(self):
        with patch.object(local_release.fcntl, 'flock', side_effect=BlockingIOError), \
                patch.object(local_release.time, 'monotonic', side_effect=[0, 301]):
            with self.assertRaisesRegex(TimeoutError, 'Timed out waiting'):
                local_release.acquire_builder_lock(4, timeout=300)

    def test_builder_timeout_terminates_its_process_group(self):
        process = unittest.mock.Mock()
        process.pid = 1234
        process.wait.side_effect = [
            subprocess.TimeoutExpired(['builder'], 30), None]
        def kill_group(_pid, sig):
            if sig == 0:
                raise ProcessLookupError

        with patch.object(local_release.subprocess, 'Popen', return_value=process), \
                patch.object(local_release.os, 'killpg', side_effect=kill_group) as killpg:
            with self.assertRaises(subprocess.TimeoutExpired):
                local_release.run_as_builder(
                    self.repo / 'builder-home', self.old, ['build'], timeout=30)

        self.assertEqual(killpg.call_args_list[0].args,
                         (process.pid, local_release.signal.SIGTERM))

    def test_builder_cleanup_preserves_errors_when_process_already_exited(self):
        process = unittest.mock.Mock()
        process.pid = 9876
        process.wait.return_value = 0
        process.poll.return_value = 0
        with patch.object(local_release.os, 'killpg', side_effect=ProcessLookupError) as killpg:
            local_release.terminate_process_group(process)

        self.assertEqual(process.wait.call_count, 1)
        self.assertEqual(killpg.call_args.args, (process.pid, local_release.signal.SIGTERM))

    def test_group_kill_falls_back_to_the_direct_child_on_eperm(self):
        process = unittest.mock.Mock()
        process.pid = 4321
        process.wait.return_value = 0
        def denied_group(_pid, sig):
            if sig == 0:
                raise ProcessLookupError  # the group is gone once the child died
            raise PermissionError('fixture group denial')

        with patch.object(local_release.os, 'killpg', side_effect=denied_group) as killpg, \
                patch.object(local_release.os, 'kill', return_value=None) as kill:
            local_release.terminate_process_group(process, grace=0.05)

        self.assertEqual(killpg.call_args_list[0].args,
                         (process.pid, local_release.signal.SIGTERM))
        kill.assert_called_once_with(process.pid, local_release.signal.SIGTERM)
        process.wait.assert_called_once()

    def test_direct_child_kill_denial_still_fails_closed(self):
        process = unittest.mock.Mock()
        process.pid = 4321
        process.poll.return_value = None
        def denied_everywhere(_pid, sig):
            raise PermissionError('fixture total denial')

        with patch.object(local_release.os, 'killpg', side_effect=denied_everywhere), \
                patch.object(local_release.os, 'kill', side_effect=denied_everywhere):
            with self.assertRaises(PermissionError):
                local_release.terminate_process_group(process, grace=0.05)

    def test_cleanup_permission_error_requires_reaped_child_and_absent_group(self):
        for denied_signal in (local_release.signal.SIGTERM, local_release.signal.SIGKILL):
            for surviving_group in (False, True):
                with self.subTest(signal=denied_signal, surviving_group=surviving_group):
                    process = unittest.mock.Mock(pid=9876)
                    reaped = False

                    def reap():
                        nonlocal reaped
                        reaped = True
                        return -15

                    def kill_group(_pid, sig):
                        if sig == denied_signal:
                            raise PermissionError('fixture signal denied')
                        if sig == 0 and reaped and not surviving_group:
                            raise ProcessLookupError

                    process.poll.side_effect = reap
                    process.wait.side_effect = reap
                    with patch.object(local_release.os, 'killpg', side_effect=kill_group), \
                            patch.object(local_release.os, 'kill', return_value=None):
                        if surviving_group:
                            with self.assertRaises(PermissionError):
                                local_release.terminate_process_group(process, grace=0)
                        else:
                            local_release.terminate_process_group(process, grace=0)
                            process.wait.assert_called_once()

    def test_process_group_kills_surviving_child_after_leader_exits(self):
        child_code = 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
        leader_code = (
            'import signal,subprocess,sys,time; '
            f'child=subprocess.Popen([sys.executable, "-c", {child_code!r}]); '
            'print(child.pid, flush=True); '
            'signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); time.sleep(60)')
        leader = subprocess.Popen(
            [sys.executable, '-c', leader_code], stdout=subprocess.PIPE,
            text=True, start_new_session=True)
        child_pid = int(leader.stdout.readline())
        leader.stdout.close()

        local_release.terminate_process_group(leader, grace=0.2)

        self.assertIsNotNone(leader.poll())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                state = subprocess.check_output(
                    ['/bin/ps', '-o', 'stat=', '-p', str(child_pid)], text=True).strip()
            except subprocess.CalledProcessError:
                state = ''
            if not state or state.startswith('Z'):
                break
            time.sleep(0.05)
        self.assertTrue(not state or state.startswith('Z'), f'child survived group kill: {state}')

    def test_package_build_has_a_thirty_minute_timeout(self):
        plan = {'commit': self.old, 'version': '0.1.1', 'build_number': 1}
        output = self.repo / 'owner-package'
        calls = []
        cleanup_order = []
        lock_path = self.repo / 'cache' / 'builder.lock'
        lock_path.parent.mkdir()
        lock_path.touch()
        with patch.object(local_release, 'BUILDER_LOCK_PATH', lock_path), \
                patch.object(local_release, 'prepare_builder_lock'), \
                patch.object(local_release, 'assert_builder_account_idle',
                             return_value=(None, frozenset())), \
                patch.object(local_release, 'prepare_builder_launchd', return_value=(None, frozenset())), \
                patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'terminate_builder_account_processes',
                             side_effect=lambda: cleanup_order.append('terminate')), \
                patch.object(local_release, 'cleanup_builder_launchd',
                             side_effect=lambda *args: cleanup_order.append('launchd')), \
                patch.object(local_release, 'verify_builder_launchd_clean',
                             side_effect=lambda *args: cleanup_order.append('verify')), \
                patch.object(local_release, 'run_as_builder', side_effect=lambda *args, **kwargs: calls.append((args, kwargs))), \
                patch.object(local_release, 'archive_source_to_builder'), \
                patch.object(local_release, 'stream_builder_package'):
            local_release.build_isolated_package(
                self.repo, plan, self.repo / 'builder-home', output)

        build_call = next(kwargs for args, kwargs in calls
                          if any('package_release.py' in str(part) for part in args[2]))
        self.assertEqual(build_call['timeout'], local_release.BUILDER_BUILD_TIMEOUT_SECONDS)
        cleanup_call = next(kwargs for args, kwargs in calls
                            if any(part == '/bin/rm' for part in args[2]))
        self.assertEqual(cleanup_call['timeout'], local_release.BUILDER_CLEANUP_TIMEOUT_SECONDS)
        self.assertEqual(cleanup_order, ['terminate', 'launchd', 'terminate', 'verify'])

    def test_workspace_removal_cannot_restart_services_after_final_teardown(self):
        plan = {'commit': self.old, 'version': '0.1.1', 'build_number': 1}
        services_running = False
        workspace_removed = False

        def run_builder(_home, _commit, command, **_kwargs):
            nonlocal services_running, workspace_removed
            # sudo/PAM may activate the builder's user domain on every invocation,
            # including the apparently harmless final workspace removal.
            services_running = True
            if command[:3] == ['/bin/rm', '-rf', '--']:
                workspace_removed = True

        def sweep():
            nonlocal services_running
            services_running = False

        def verify(*_args):
            self.assertFalse(services_running, 'builder services remain at final verification')

        with patch.object(local_release, 'builder_account_lock'), \
                patch.object(local_release, 'assert_builder_account_idle',
                             return_value=(None, frozenset())), \
                patch.object(local_release, 'prepare_builder_launchd', return_value=(None, frozenset())), \
                patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'terminate_builder_account_processes', side_effect=sweep), \
                patch.object(local_release, 'cleanup_builder_launchd'), \
                patch.object(local_release, 'verify_builder_launchd_clean', side_effect=verify), \
                patch.object(local_release, 'run_as_builder', side_effect=run_builder), \
                patch.object(local_release, 'archive_source_to_builder'), \
                patch.object(local_release, 'stream_builder_package'):
            local_release.build_isolated_package(
                self.repo, plan, self.repo / 'builder-home', self.repo / 'output')

        self.assertTrue(workspace_removed)
        self.assertFalse(services_running, 'workspace removal restarted services after final teardown')

    def test_cleanup_continues_after_first_process_sweep_timeout(self):
        plan = {'commit': self.old, 'version': '0.1.1', 'build_number': 1}
        events = []
        lock_path = self.repo / 'cache' / 'builder.lock'
        lock_path.parent.mkdir()
        lock_path.touch()
        sweep_count = 0

        def sweep_builder():
            nonlocal sweep_count
            sweep_count += 1
            if sweep_count == 1:
                raise TimeoutError('first sweep')
            events.append('final sweep')

        with patch.object(local_release, 'BUILDER_LOCK_PATH', lock_path), \
                patch.object(local_release, 'prepare_builder_lock'), \
                patch.object(local_release, 'assert_builder_account_idle',
                             return_value=(None, frozenset())), \
                patch.object(local_release, 'prepare_builder_launchd', return_value=(None, frozenset())), \
                patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'terminate_builder_account_processes',
                             side_effect=sweep_builder) as sweep, \
                patch.object(local_release, 'cleanup_builder_launchd',
                             side_effect=lambda *args: events.append('launchd cleanup')), \
                patch.object(local_release, 'verify_builder_launchd_clean',
                             side_effect=lambda *args: events.append('final verification')), \
                patch.object(local_release, 'run_as_builder'), \
                patch.object(local_release, 'archive_source_to_builder'), \
                patch.object(local_release, 'stream_builder_package'), \
                patch('sys.stderr', new_callable=io.StringIO):
            local_release.build_isolated_package(
                self.repo, plan, self.repo / 'builder-home', self.repo / 'output')

        self.assertEqual(events, [
            'launchd cleanup', 'final sweep', 'final verification'])
        self.assertEqual(sweep.call_count, 2)

    def test_workspace_cleanup_timeout_does_not_mask_build_failure(self):
        plan = {'commit': self.old, 'version': '0.1.1', 'build_number': 1}
        lock_path = self.repo / 'cache' / 'builder.lock'
        lock_path.parent.mkdir()
        lock_path.touch()

        def run_builder(_home, _commit, command, **kwargs):
            if 'package_release.py' in ' '.join(str(part) for part in command):
                raise RuntimeError('primary build failure')
            if '/bin/rm' in command:
                raise subprocess.TimeoutExpired(command, kwargs['timeout'])

        with patch.object(local_release, 'BUILDER_LOCK_PATH', lock_path), \
                patch.object(local_release, 'prepare_builder_lock'), \
                patch.object(local_release, 'assert_builder_account_idle',
                             return_value=(None, frozenset())), \
                patch.object(local_release, 'prepare_builder_launchd', return_value=(None, frozenset())), \
                patch.object(local_release, 'builder_uid', return_value=501), \
                patch.object(local_release, 'terminate_builder_account_processes'), \
                patch.object(local_release, 'cleanup_builder_launchd'), \
                patch.object(local_release, 'verify_builder_launchd_clean'), \
                patch.object(local_release, 'run_as_builder', side_effect=run_builder) as builder, \
                patch.object(local_release, 'archive_source_to_builder'), \
                patch('sys.stderr', new_callable=io.StringIO):
            with self.assertRaisesRegex(RuntimeError, 'primary build failure'):
                local_release.build_isolated_package(
                    self.repo, plan, self.repo / 'builder-home', self.repo / 'output')

        cleanup_call = next(call for call in builder.call_args_list
                            if '/bin/rm' in call.args[2])
        self.assertEqual(cleanup_call.kwargs['timeout'],
                         local_release.BUILDER_CLEANUP_TIMEOUT_SECONDS)

    def test_package_transfer_idle_timeout_cleans_stage_and_stops_builder(self):
        class FakePipe:
            def fileno(self):
                return 123

            def close(self):
                pass

        process = unittest.mock.Mock()
        process.pid = 5678
        process.stdout = FakePipe()
        process.wait.return_value = 0
        destination = self.repo / 'timeout-stage'
        def kill_group(_pid, sig):
            if sig == 0:
                raise ProcessLookupError

        with patch.object(local_release.subprocess, 'Popen', return_value=process) as popen, \
                patch.object(local_release.select, 'select', return_value=([], [], [])), \
                patch.object(local_release.os, 'killpg', side_effect=kill_group) as killpg:
            with self.assertRaisesRegex(TimeoutError, 'transfer stalled'):
                local_release.stream_builder_package(
                    self.repo / 'builder-home', self.old, self.repo, destination)

        self.assertFalse(destination.exists())
        self.assertIs(popen.call_args.kwargs.get('preexec_fn'), local_release.BUILDER_PREEXEC)
        self.assertFalse(popen.call_args.kwargs.get('start_new_session'))
        self.assertEqual(killpg.call_args_list[0].args,
                         (process.pid, local_release.signal.SIGTERM))

    def test_stream_builder_package_tar_omits_macos_metadata_members(self):
        workspace = self.repo / 'workspace'
        package = workspace / 'package'
        package.mkdir(parents=True)
        names = ('Stash-macOS.zip', 'Stash-macOS.dmg', 'SHA256SUMS', 'metadata.json')
        for name in names:
            (package / name).write_bytes(name.encode())
            subprocess.run(
                ['/usr/bin/xattr', '-w', 'com.apple.metadata:kMDItemWhereFroms',
                 'stash', str(package / name)], capture_output=True)
        destination = self.repo / 'staged-package'

        def plain_builder(home, commit, command, cwd, workspace_root=None):
            return command

        with patch.object(local_release, 'builder_command', side_effect=plain_builder):
            local_release.stream_builder_package(
                self.repo / 'builder-home', self.old, workspace, destination)

        self.assertEqual({path.name for path in destination.iterdir()}, set(names))

    def test_builder_source_archive_is_streamed_directly_into_builder_tar(self):
        self.git('remote', 'add', 'origin', 'https://example.invalid/owner/repo.git')
        (self.repo / 'base.txt').write_text('uncommitted owner change\n')
        (self.repo / 'untracked.txt').write_text('owner-only\n')
        snapshot = io.BytesIO()
        with tarfile.open(fileobj=snapshot, mode='w') as archive:
            data = b'base\n'
            member = tarfile.TarInfo('base.txt')
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        snapshot.seek(0)
        expected_stream = snapshot.getvalue()
        process = type('ArchiveProcess', (), {
            'stdout': snapshot, 'pid': 2468, 'poll': lambda self: 0,
            'wait': lambda self, timeout=None: 0,
            'terminate': lambda self: None,
        })()
        captured = {}

        def builder(home, commit, command, cwd, stdin, timeout, workspace_root):
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, local_release.BUILDER_TRANSFER_TIMEOUT_SECONDS)
            self.assertEqual(workspace_root, self.repo / 'private-workspace')
            captured.update(command=command, cwd=cwd, input=stdin.read())

        with patch.object(local_release.subprocess, 'Popen', return_value=process) as popen, \
                patch.object(local_release, 'run_as_builder', side_effect=builder):
            local_release.archive_source_to_builder(
                self.repo, self.old, self.repo / 'builder-home',
                self.repo / 'private-workspace', self.repo / 'private-workspace' / 'source')

        self.assertIs(popen.call_args.kwargs.get('preexec_fn'), local_release.BUILDER_PREEXEC)
        self.assertFalse(popen.call_args.kwargs.get('start_new_session'))
        self.assertEqual(popen.call_args.args[0], [
            'git', '-C', str(self.repo), 'archive', '--format=tar', self.old])
        self.assertEqual(captured['command'], ['/usr/bin/tar', '-xf', '-', '-C',
                                               str(self.repo / 'private-workspace/source')])
        self.assertEqual(captured['input'], expected_stream)
        self.assertNotIn(b'example.invalid', captured['input'])
        self.assertNotIn(b'owner-only', captured['input'])

    def test_archive_wait_timeout_kills_process_group(self):
        archive = unittest.mock.Mock()
        archive.pid = 2469
        archive.stdout = io.BytesIO(b'')
        archive.poll.return_value = 0
        archive.wait.side_effect = [
            subprocess.TimeoutExpired(['git', 'archive'], 10), None]

        def signal_group(_pid, sig):
            if sig == 0:
                raise ProcessLookupError

        with patch.object(local_release.subprocess, 'Popen', return_value=archive), \
                patch.object(local_release, 'run_as_builder') as builder, \
                patch.object(local_release.os, 'killpg', side_effect=signal_group):
            with self.assertRaises(subprocess.TimeoutExpired):
                local_release.archive_source_to_builder(
                    self.repo, self.old, self.repo / 'builder-home',
                    self.repo / 'workspace', self.repo / 'workspace' / 'source')

        self.assertLessEqual(builder.call_args.kwargs['timeout'],
                             local_release.BUILDER_TRANSFER_TIMEOUT_SECONDS)
        archive_timeout = archive.wait.call_args_list[0].kwargs['timeout']
        self.assertGreater(archive_timeout, 0)
        self.assertLessEqual(archive_timeout, local_release.BUILDER_TRANSFER_TIMEOUT_SECONDS)

    def test_owner_streams_only_private_regular_package_files(self):
        names = ('Stash-macOS.zip', 'Stash-macOS.dmg', 'SHA256SUMS', 'metadata.json')
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as archive:
            for name in names:
                data = name.encode()
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        stream.seek(0)
        destination = self.repo / 'owner-package'

        local_release.copy_package_stream(stream, destination)

        self.assertEqual({path.name for path in destination.iterdir()}, set(names))
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        for name in names:
            self.assertEqual((destination / name).read_bytes(), name.encode())
            self.assertEqual((destination / name).stat().st_mode & 0o777, 0o600)

    def test_owner_rejects_symlink_in_builder_package_stream_and_cleans_stage(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as archive:
            link = tarfile.TarInfo('metadata.json')
            link.type = tarfile.SYMTYPE
            link.linkname = '/owner/secret'
            archive.addfile(link)
        stream.seek(0)
        destination = self.repo / 'owner-package'

        with self.assertRaisesRegex(ValueError, 'invalid package stream'):
            local_release.copy_package_stream(stream, destination)

        self.assertFalse(destination.exists())

    def test_owner_rejects_appledouble_companion_member_in_package_stream(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w') as archive:
            data = b'zipped'
            companion = tarfile.TarInfo('._Stash-macOS.zip')
            companion.size = len(data)
            archive.addfile(companion, io.BytesIO(data))
            member = tarfile.TarInfo('Stash-macOS.zip')
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        stream.seek(0)
        destination = self.repo / 'companion-stage'

        with self.assertRaisesRegex(ValueError, 'invalid package stream'):
            local_release.copy_package_stream(stream, destination)

        self.assertFalse(destination.exists())

    def test_owner_rejects_zip_path_escape_before_extraction(self):
        archive = self.repo / 'unsafe.zip'
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr('../outside', 'unsafe')

        with self.assertRaisesRegex(ValueError, 'unsafe path'):
            local_release.validate_zip_layout(archive)

    def test_owner_rejects_zip_symlink_escape_before_extraction(self):
        archive = self.repo / 'unsafe-link.zip'
        link = zipfile.ZipInfo('Stash.app/Contents/Resources/escape')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr(link, '../../../../outside')
            package.writestr('Stash.app/Contents/Info.plist', b'plist')

        with self.assertRaisesRegex(ValueError, 'escaping symbolic link'):
            local_release.validate_zip_layout(archive)

    def test_owner_rejects_oversized_tar_member_before_copying(self):
        member = unittest.mock.Mock()
        member.name = 'Stash-macOS.zip'
        member.size = local_release.MAX_PACKAGE_BINARY_BYTES + 1
        member.isfile.return_value = True
        archive = unittest.mock.MagicMock()
        archive.__enter__.return_value = archive
        archive.__iter__.return_value = iter([member])
        destination = self.repo / 'oversize-stage'

        with patch.object(local_release.tarfile, 'open', return_value=archive):
            with self.assertRaisesRegex(ValueError, 'exceeds size limit'):
                local_release.copy_package_stream(io.BytesIO(), destination)

        self.assertFalse(destination.exists())

    def test_owner_rejects_aggregate_tar_stream_over_limit(self):
        members = []
        for name, size in (
                ('Stash-macOS.zip', local_release.MAX_PACKAGE_BINARY_BYTES),
                ('Stash-macOS.dmg', local_release.MAX_PACKAGE_BINARY_BYTES),
                ('metadata.json', 1)):
            member = unittest.mock.Mock()
            member.name = name
            member.size = size
            member.isfile.return_value = True
            members.append(member)
        archive = unittest.mock.MagicMock()
        archive.__enter__.return_value = archive
        archive.__iter__.return_value = iter(members)
        archive.extractfile.side_effect = lambda _member: io.BytesIO(b'')
        destination = self.repo / 'aggregate-stage'

        with patch.object(local_release.tarfile, 'open', return_value=archive):
            with self.assertRaisesRegex(ValueError, 'aggregate size limit'):
                local_release.copy_package_stream(io.BytesIO(), destination)

        self.assertFalse(destination.exists())

    def test_owner_rejects_zip_bomb_size_declaration(self):
        archive_path = self.repo / 'declared-bomb.zip'
        with zipfile.ZipFile(archive_path, 'w'):
            pass
        member = zipfile.ZipInfo('Stash.app/Contents/Info.plist')
        member.file_size = local_release.MAX_ZIP_MEMBER_BYTES + 1

        with patch.object(zipfile.ZipFile, 'infolist', return_value=[member]):
            with self.assertRaisesRegex(ValueError, 'member exceeds size limit'):
                local_release.validate_zip_layout(archive_path)

    def test_owner_rejects_zip_aggregate_uncompressed_size(self):
        archive_path = self.repo / 'aggregate-bomb.zip'
        with zipfile.ZipFile(archive_path, 'w'):
            pass
        info = zipfile.ZipInfo('Stash.app/Contents/Info.plist')
        members = [info]
        for index in range(3):
            member = zipfile.ZipInfo(f'Stash.app/Contents/large-{index}')
            member.file_size = 200 * 1024**2
            members.append(member)

        with patch.object(zipfile.ZipFile, 'infolist', return_value=members):
            with self.assertRaisesRegex(ValueError, 'uncompressed size limit'):
                local_release.validate_zip_layout(archive_path)

    def test_owner_rejects_zip_with_too_many_members(self):
        archive_path = self.repo / 'many-members.zip'
        with zipfile.ZipFile(archive_path, 'w'):
            pass
        members = [zipfile.ZipInfo('Stash.app/Contents/Info.plist')]
        members *= local_release.MAX_ZIP_MEMBERS + 1

        with patch.object(zipfile.ZipFile, 'infolist', return_value=members):
            with self.assertRaisesRegex(ValueError, 'too many members'):
                local_release.validate_zip_layout(archive_path)

    def test_owner_rejects_declared_zip_member_count_before_parsing_entries(self):
        archive_path = self.repo / 'declared-count.zip'
        with zipfile.ZipFile(archive_path, 'w'):
            pass
        raw = bytearray(archive_path.read_bytes())
        end_record = raw.rfind(b'PK\x05\x06')
        struct.pack_into('<H', raw, end_record + 8, local_release.MAX_ZIP_MEMBERS + 1)
        struct.pack_into('<H', raw, end_record + 10, local_release.MAX_ZIP_MEMBERS + 1)
        archive_path.write_bytes(raw)

        with patch.object(zipfile, 'ZipFile') as zip_open:
            with self.assertRaisesRegex(ValueError, 'too many members'):
                local_release.validate_zip_layout(archive_path)

        zip_open.assert_not_called()

    def test_owner_rejects_oversized_zip_symlink_payload(self):
        archive = self.repo / 'long-link.zip'
        link = zipfile.ZipInfo('Stash.app/Contents/Resources/link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, 'w') as package:
            package.writestr(link, 'x' * (local_release.MAX_ZIP_SYMLINK_BYTES + 1))
            package.writestr('Stash.app/Contents/Info.plist', b'plist')

        with self.assertRaisesRegex(ValueError, 'symbolic link payload exceeds'):
            local_release.validate_zip_layout(archive)

    def test_owner_independently_verifies_zip_app_and_dmg_contents(self):
        output = self.repo / 'owner-package'
        output.mkdir(mode=0o700)
        plan = release_pipeline.identity('0.1.1', 1, self.old)
        zip_path = output / 'Stash-macOS.zip'
        with zipfile.ZipFile(zip_path, 'w') as package:
            package.writestr('Stash.app/Contents/Info.plist', b'plist')
        dmg = output / 'Stash-macOS.dmg'
        dmg.write_bytes(b'dmg bytes')
        zip_hash = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        dmg_hash = hashlib.sha256(dmg.read_bytes()).hexdigest()
        receipt = {**plan, 'package_format': 2, 'sha256': zip_hash,
                   'dmg_sha256': dmg_hash, 'signing': 'ad-hoc', 'notarized': False}
        (output / 'metadata.json').write_text(json.dumps(receipt))
        (output / 'SHA256SUMS').write_text(
            f'{zip_hash}  Stash-macOS.zip\n{dmg_hash}  Stash-macOS.dmg\n')
        inventory = {'Contents/Info.plist': ('file', 0o644, 'bundle-hash')}

        def extract(*command, timeout):
            (Path(command[-1]) / 'Stash.app').mkdir()
            self.assertEqual(timeout, local_release.OWNER_VERIFY_TIMEOUT_SECONDS)

        with patch.object(local_release.package_release, 'run', side_effect=extract) as ditto, \
                patch.object(local_release.package_release, 'verify_app') as verify_app, \
                patch.object(local_release.package_release, 'bundle_inventory', return_value=inventory), \
                patch.object(local_release.package_release, 'verify_dmg') as verify_dmg:
            assets = local_release.validate_package_contents(output, plan)

        self.assertIn('Stash-macOS.dmg', assets)
        ditto.assert_called_once_with(
            '/usr/bin/ditto', '-x', '-k', zip_path, unittest.mock.ANY,
            timeout=local_release.OWNER_VERIFY_TIMEOUT_SECONDS)
        verify_app.assert_called_once()
        self.assertEqual(verify_app.call_args.args[1], receipt)
        verify_dmg.assert_called_once_with(dmg, receipt, inventory)

    def test_missing_builder_blocks_before_release_reservation(self):
        queue = self.repo / 'release-queue'
        with patch.object(local_release, 'builder_home', side_effect=ValueError('missing builder')), \
                patch.object(local_release, 'reserve_plan') as reserve:
            with self.assertRaisesRegex(ValueError, 'missing builder'):
                local_release.prepare_commit(self.repo, self.old, queue)

        reserve.assert_not_called()
        self.assertEqual(list(queue.iterdir()), [])

    def test_failed_build_leaves_no_queued_package(self):
        queue = self.repo / 'release-queue'
        plan = release_pipeline.identity(
            '0.1.1', int(self.git('rev-list', '--count', self.old)), self.old)

        with patch.object(local_release, 'builder_home', return_value=self.repo / 'builder-home'), \
                patch.object(local_release, 'reserve_plan', return_value=plan), \
                patch.object(local_release, 'build_isolated_package',
                             side_effect=RuntimeError('verification failed')):
            with self.assertRaisesRegex(RuntimeError, 'verification failed'):
                local_release.prepare_commit(self.repo, self.old, queue)

        self.assertEqual(list(queue.iterdir()), [])

    def test_installed_hook_allows_feature_push_without_release_work(self):
        remote = self.repo / 'remote.git'
        subprocess.run(['git', 'init', '--bare', str(remote)], check=True, capture_output=True)
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '--no-verify', 'origin', 'main')
        project_root = Path(__file__).parents[2]
        scripts = self.repo / 'Scripts'
        scripts.mkdir()
        for name in ('local_release.py', 'release_pipeline.py', 'release_versions.py'):
            (scripts / name).write_bytes((project_root / 'Scripts' / name).read_bytes())
        self.git('config', 'core.hooksPath', str(project_root / '.githooks'))
        self.git('switch', '-c', 'feature')
        (self.repo / 'feature.txt').write_text('feature\n')
        self.git('add', 'feature.txt')
        self.git('commit', '-m', 'feature')

        result = subprocess.run(['git', '-C', str(self.repo), 'push', 'origin', 'feature'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installed_hook_allows_linear_main_push_without_release_work(self):
        remote = self.repo / 'remote.git'
        subprocess.run(['git', 'init', '--bare', str(remote)], check=True, capture_output=True)
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '--no-verify', 'origin', 'main')
        project_root = Path(__file__).parents[2]
        scripts = self.repo / 'Scripts'
        scripts.mkdir()
        for name in ('local_release.py', 'release_pipeline.py', 'release_versions.py'):
            (scripts / name).write_bytes((project_root / 'Scripts' / name).read_bytes())
        self.git('config', 'core.hooksPath', str(project_root / '.githooks'))
        (self.repo / 'linear.txt').write_text('linear\n')
        self.git('add', 'linear.txt')
        self.git('commit', '-m', 'linear')

        result = subprocess.run(['git', '-C', str(self.repo), 'push', 'origin', 'main'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_prepare_commit_uses_exact_merge_and_reuses_queued_package(self):
        self.git('switch', '-c', 'feature')
        (self.repo / 'feature.txt').write_text('feature\n')
        self.git('add', 'feature.txt')
        self.git('commit', '-m', 'feature')
        self.git('switch', 'main')
        self.git('merge', '--no-ff', 'feature', '-m', 'Merge feature')
        merge = self.git('rev-parse', 'HEAD')
        commit_count = int(self.git('rev-list', '--count', merge))
        plan = release_pipeline.identity('0.1.1', commit_count, merge)
        queue = self.repo / 'release-queue'
        builds = []

        def build(repo, selected_plan, home, output):
            builds.append((selected_plan['commit'], selected_plan))
            output.mkdir()
            assets = {'Stash-macOS.zip': b'zip', 'Stash-macOS.dmg': b'dmg'}
            digests = {name: hashlib.sha256(data).hexdigest() for name, data in assets.items()}
            for name, data in assets.items():
                (output / name).write_bytes(data)
            (output / 'SHA256SUMS').write_text(''.join(
                f'{digests[name]}  {name}\n' for name in assets))
            receipt = {
                **selected_plan,
                'package_format': 2,
                'sha256': digests['Stash-macOS.zip'],
                'dmg_sha256': digests['Stash-macOS.dmg'],
                'signing': 'ad-hoc',
                'notarized': False,
            }
            (output / 'metadata.json').write_text(json.dumps(receipt))

        with patch.object(local_release, 'builder_home', return_value=self.repo / 'builder-home'), \
                patch.object(local_release, 'reserve_plan', return_value=plan) as reserve, \
                patch.object(local_release, 'build_isolated_package', side_effect=build), \
                patch.object(local_release, 'validate_package_contents',
                             side_effect=lambda directory, selected: release_pipeline.package_assets(
                                 directory, selected, require_dmg=True)):
            first = local_release.prepare_commit(self.repo, merge, queue)
            second = local_release.prepare_commit(self.repo, merge, queue)

        self.assertEqual(builds, [(merge, plan)])
        reserve.assert_called_once_with(self.repo.resolve(), merge)
        self.assertEqual(first, second)
        self.assertEqual(first['plan'], plan)
        self.assertEqual(set(path.name for path in Path(first['directory']).iterdir()), {
            'Stash-macOS.zip', 'Stash-macOS.dmg', 'SHA256SUMS', 'metadata.json', 'manifest.json'})


class BuilderPreflightRecoveryTests(unittest.TestCase):
    @contextmanager
    def builder_fixture(self, snapshots=None, paths=None, session=False, agents=False,
                        cron=None, at_jobs=frozenset()):
        state = SimpleNamespace(locked=False, active=True, reads=0, events=[])
        snapshots = snapshots or ['101 503 503 1\n']
        paths = {101: '/usr/sbin/distnoted'} if paths is None else paths

        @contextmanager
        def lock():
            state.locked = True
            try:
                yield
            finally:
                state.locked = False

        def read(command, *_args, **_kwargs):
            self.assertTrue(state.locked, 'process inspection occurred outside the machine lock')
            if command[0] == '/bin/ps':
                rows = snapshots[min(state.reads, len(snapshots) - 1)]
                state.reads += 1
                state.events.append('process inspection')
                return (0 if rows else 1), rows.encode()
            if '/usr/bin/crontab' in command:
                state.events.append('cron inspection')
                return (1, b'no crontab for stashbuild\n') if cron is None else (0, cron)
            if '/usr/bin/atq' in command:
                state.events.append('at inspection')
                return 0, b''.join(f'{job} fixture\n'.encode() for job in at_jobs)
            raise AssertionError(command)

        def sessions(command, **_kwargs):
            self.assertEqual(command, ['/usr/bin/who'])
            return 'stashbuild console fixture\n' if session else ''

        def normalize(*_args):
            self.assertTrue(state.locked)
            state.events.append('normalize')
            state.active = False

        def kernel_path(pid):
            if pid not in paths:
                raise OSError('fixture executable identity is unavailable')
            return paths[pid]

        with ExitStack() as stack:
            for name, replacement in (
                    ('builder_account_lock', lock), ('builder_uid', lambda: 503),
                    ('read_bounded_command_output', read),
                    ('builder_launch_agents_remain_safely', lambda *_args: agents),
                    ('inspect_builder_launch_agents', lambda *_args: agents),
                    ('builder_has_processes', lambda: state.active),
                    ('clear_builder_launchd_domain', normalize),
                    ('terminate_builder_account_processes', normalize),
                    ('run_as_builder', lambda *_args, **_kwargs: state.events.append('build')),
                    ('archive_source_to_builder', lambda *_args: None),
                    ('stream_builder_package', lambda *_args: None),
                    ('cleanup_builder_launchd', lambda *_args: None),
                    ('verify_builder_launchd_clean', lambda *_args: None)):
                stack.enter_context(patch.object(local_release, name, side_effect=replacement))
            stack.enter_context(patch.object(local_release.subprocess, 'check_output', side_effect=sessions))
            stack.enter_context(patch.object(local_release, 'kernel_process_path',
                                            side_effect=kernel_path))
            stack.enter_context(patch.object(Path, 'resolve', lambda path: path))
            stack.enter_context(patch.object(Path, 'lstat', return_value=SimpleNamespace(
                st_mode=stat.S_IFREG | 0o755, st_uid=0)))
            yield state

    @staticmethod
    def build():
        local_release.build_isolated_package(
            Path('/unused-fixture'), {'commit': 'a' * 40, 'version': '0.1.1', 'build_number': 1},
            Path('/Users/stashbuild'), Path('/unused-output'))

    def test_known_apple_services_are_normalized_under_lock_before_build(self):
        paths = dict(enumerate((
            '/usr/sbin/distnoted', '/usr/sbin/cfprefsd', '/usr/libexec/pkd',
            '/usr/libexec/lsd', '/usr/libexec/secd', '/usr/libexec/containermanagerd',
            '/usr/libexec/trustd', '/usr/libexec/fskit_agent',
            '/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/'
            'Metadata.framework/Versions/A/Support/mdbulkimport',
        ), start=101))
        rows = ''.join(f'{pid} 503 503 1\n' for pid in paths)
        with self.builder_fixture(snapshots=[rows], paths=paths) as state:
            self.build()
        self.assertEqual(state.reads, 2)
        first_normalize = state.events.index('normalize')
        self.assertIn('cron inspection', state.events[:first_normalize])
        self.assertIn('at inspection', state.events[:first_normalize])
        self.assertEqual(state.events[:first_normalize].count('process inspection'), 2)
        self.assertLess(first_normalize, state.events.index('build'))
        self.assertEqual(state.events[:state.events.index('build')].count('normalize'), 1)
        self.assertNotIn('cron inspection', state.events[first_normalize:])
        self.assertNotIn('at inspection', state.events[first_normalize:])

    def test_unknown_mixed_and_uninspectable_process_sets_refuse_without_teardown(self):
        cases = (
            ('101 503 503 1\n', {101: '/tmp/distnoted'}),
            ('101 503 503 1\n102 503 503 1\n',
             {101: '/usr/sbin/distnoted', 102: '/usr/bin/python3'}),
            ('101 503 503 2\n', {101: '/usr/sbin/distnoted'}),
            ('101 0 503 1\n', {101: '/usr/sbin/distnoted'}),
            ('101 503 0 1\n', {101: '/usr/sbin/distnoted'}),
            ('invalid process data\n', {}),
            ('101 503 503 1\n', {}),
        )
        for rows, paths in cases:
            with self.subTest(rows=rows, paths=paths), \
                    self.builder_fixture(snapshots=[rows], paths=paths) as state:
                with self.assertRaises((ValueError, OSError)):
                    self.build()
                self.assertNotIn('normalize', state.events)
                self.assertNotIn('build', state.events)
                self.assertNotIn('cron inspection', state.events)

    def test_sessions_agents_and_scheduled_work_refuse_without_teardown(self):
        for settings in ({'session': True}, {'agents': True}, {'cron': b'* * * * * command\n'},
                         {'at_jobs': frozenset({'7'})}):
            with self.subTest(settings=settings), self.builder_fixture(**settings) as state:
                with self.assertRaises(ValueError):
                    self.build()
                self.assertNotIn('normalize', state.events)
                self.assertNotIn('build', state.events)

    def test_process_set_is_requeried_after_scheduled_state_reads(self):
        with self.builder_fixture(
                snapshots=['101 503 503 1\n', '101 503 503 1\n102 503 503 1\n'],
                paths={101: '/usr/sbin/distnoted', 102: '/usr/bin/python3'}) as state:
            with self.assertRaisesRegex(ValueError, 'unknown active process'):
                self.build()
        self.assertEqual(state.reads, 2)
        self.assertNotIn('normalize', state.events)
        self.assertNotIn('build', state.events)

    def test_system_file_metadata_must_be_root_owned_and_nonwritable(self):
        for metadata in (
                SimpleNamespace(st_mode=stat.S_IFREG | 0o755, st_uid=503),
                SimpleNamespace(st_mode=stat.S_IFREG | 0o775, st_uid=0),
                SimpleNamespace(st_mode=stat.S_IFLNK | 0o755, st_uid=0)):
            with self.subTest(metadata=metadata), self.builder_fixture() as state, \
                    patch.object(Path, 'lstat', return_value=metadata):
                with self.assertRaises(ValueError):
                    self.build()
                self.assertNotIn('normalize', state.events)
                self.assertNotIn('build', state.events)

    def test_noncanonical_system_executable_refuses_without_teardown(self):
        with self.builder_fixture() as state, \
                patch.object(Path, 'resolve', return_value=Path('/tmp/replaced-service')):
            with self.assertRaisesRegex(ValueError, 'unknown active process'):
                self.build()
        self.assertNotIn('normalize', state.events)
        self.assertNotIn('build', state.events)

    def test_normalization_failure_preserves_error_and_does_not_start_build(self):
        with self.builder_fixture() as state, \
                patch.object(local_release, 'clear_builder_launchd_domain',
                             side_effect=TimeoutError('normalization fixture')):
            with self.assertRaisesRegex(TimeoutError, 'normalization fixture'):
                self.build()
        self.assertNotIn('build', state.events)

    def test_residual_processes_after_normalization_refuse_build(self):
        with self.builder_fixture() as state, \
                patch.object(local_release, 'clear_builder_launchd_domain'), \
                patch.object(local_release, 'terminate_builder_account_processes'):
            with self.assertRaisesRegex(ValueError, 'idle before use'):
                self.build()
        self.assertNotIn('build', state.events)

    def test_new_process_after_bootout_refuses_build_without_uid_wide_signal(self):
        with self.builder_fixture() as state:
            def bootout_then_new_process(_uid):
                state.active = False  # bootout completed with no builder processes
                state.events.append('bootout reached idle')
                state.active = True  # an unexpected PID appeared after that checkpoint

            with patch.object(local_release, 'clear_builder_launchd_domain',
                              side_effect=bootout_then_new_process), \
                    patch.object(local_release, 'terminate_builder_account_processes',
                                 wraps=local_release.terminate_builder_account_processes) as signal_uid:
                with self.assertRaisesRegex(ValueError, 'idle before use'):
                    self.build()
                signal_uid.assert_not_called()
        self.assertIn('bootout reached idle', state.events)
        self.assertNotIn('build', state.events)

    def test_inspection_errors_refuse_without_destructive_calls(self):
        for boundary in ('read_bounded_command_output', 'kernel_process_path'):
            with self.subTest(boundary=boundary), self.builder_fixture() as state, \
                    patch.object(local_release, boundary, side_effect=OSError('inspection fixture')):
                with self.assertRaisesRegex(OSError, 'inspection fixture'):
                    self.build()
                self.assertNotIn('normalize', state.events)
                self.assertNotIn('build', state.events)

    def test_account_role_probes_refuse_unknown_processes_before_starting_sudo(self):
        def account_output(command, **_kwargs):
            if command == ['/usr/bin/who']:
                return ''
            if command[0] == '/usr/bin/id':
                return 'staff\n'
            return ('NFSHomeDirectory: /Users/stashbuild\n' if command[-1] == 'NFSHomeDirectory'
                    else 'UserShell: /usr/bin/false\n')

        with patch.object(local_release.subprocess, 'check_output', side_effect=account_output), \
                patch.object(local_release, 'builder_uid', return_value=503), \
                patch.object(local_release, 'validate_builder_home'), \
                patch.object(local_release, 'read_bounded_command_output',
                             return_value=(0, b'101 503 503 1\n')), \
                patch.object(local_release, 'kernel_process_path', return_value='/tmp/distnoted'), \
                patch.object(local_release.subprocess, 'run') as commands:
            with self.assertRaisesRegex(ValueError, 'unknown active process'):
                local_release.builder_home()
        commands.assert_not_called()

    def test_kernel_executable_identity_is_available_without_privilege(self):
        actual = Path(local_release.kernel_process_path(os.getpid()))
        self.assertTrue(actual.is_absolute())
        self.assertTrue(actual.is_file())
        self.assertEqual(actual, actual.resolve())


if __name__ == '__main__':
    unittest.main()
