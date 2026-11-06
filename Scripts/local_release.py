#!/usr/bin/env python3
"""Prepare local development releases before pushing merge commits on main."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import grp
import hashlib
import json
import os
import posixpath
import re
import select
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import shutil
import zipfile
import zlib
from pathlib import Path
from pathlib import PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_pipeline
import release_versions
import package_release


ZERO_SHA = '0' * 40
RELEASE_REPOSITORY = 'kfathy194/stash'
BUILDER_USER = 'stashbuild'
BUILDER_TEMP_ROOT = Path('/private/tmp')
QUEUE_ROOT = Path.home() / 'Library' / 'Caches' / 'Stash' / 'DevelopmentReleases'
SUDO_ENV = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
# App payloads are currently small; these ceilings leave substantial growth room.
# Raise them only if verified release assets legitimately exceed the limits.
MAX_PACKAGE_BINARY_BYTES = 256 * 1024**2
MAX_PACKAGE_METADATA_BYTES = 1 * 1024**2
MAX_PACKAGE_STREAM_BYTES = 512 * 1024**2
MAX_ZIP_MEMBERS = 20_000
MAX_ZIP_CENTRAL_DIRECTORY_BYTES = 32 * 1024**2
MAX_ZIP_MEMBER_BYTES = 256 * 1024**2
MAX_ZIP_UNCOMPRESSED_BYTES = 512 * 1024**2
MAX_ZIP_SYMLINK_BYTES = 4 * 1024
BUILDER_BUILD_TIMEOUT_SECONDS = 30 * 60
BUILDER_TRANSFER_TIMEOUT_SECONDS = 2 * 60
BUILDER_CLEANUP_TIMEOUT_SECONDS = 2 * 60
MAX_ATQ_OUTPUT_BYTES = 64 * 1024
MAX_AT_JOBS = 1000
AT_JOB_CLEANUP_TIMEOUT_SECONDS = 30
OWNER_VERIFY_TIMEOUT_SECONDS = 2 * 60
PROCESS_TERMINATION_GRACE_SECONDS = 10
PROCESS_GROUP_REAP_SETTLE_SECONDS = 0.5
PROCESS_POLL_INTERVAL_SECONDS = 0.1
BUILDER_LOCK_TIMEOUT_SECONDS = 5 * 60
BUILDER_LOCK_PATH = Path('/private/var/db/StashLocalRelease/builder.lock')
# `sudo -n` in spawned children resolves the owner's cached per-tty sudo
# timestamp through the controlling terminal. start_new_session (setsid)
# detaches that terminal, and every child sudo call then fails non-
# interactively with "a password is required". Spawn builder children in a
# fresh process group instead: killpg(timeout) cleanup and terminal-signal
# isolation are preserved while the session (and therefore the tty that sudo
# validates) stays attached.
BUILDER_PREEXEC = os.setpgrp
SUDO_KEEPALIVE_INTERVAL_SECONDS = 55
SAFE_REMOVE_BUILDER_LAUNCH_AGENTS = r'''import os, stat, sys
home = os.path.abspath(sys.argv[1])
uid = int(sys.argv[2])
if not os.path.isabs(home) or os.path.normpath(home) != home or os.path.realpath(home) != home:
    sys.exit(3)
try:
    home_metadata = os.lstat(home)
except FileNotFoundError:
    sys.exit(0)
except OSError:
    sys.exit(4)
if stat.S_ISLNK(home_metadata.st_mode) or not stat.S_ISDIR(home_metadata.st_mode) or home_metadata.st_uid != uid:
    sys.exit(3)
no_follow = getattr(os, 'O_NOFOLLOW', 0)
directory = getattr(os, 'O_DIRECTORY', 0)
try:
    home_fd = os.open(home, os.O_RDONLY | directory | no_follow)
except OSError:
    sys.exit(4)
try:
    try:
        library_metadata = os.stat('Library', dir_fd=home_fd, follow_symlinks=False)
    except FileNotFoundError:
        sys.exit(0)
    if stat.S_ISLNK(library_metadata.st_mode):
        if library_metadata.st_uid != uid:
            sys.exit(3)
        os.unlink('Library', dir_fd=home_fd)
        sys.exit(0)
    if not stat.S_ISDIR(library_metadata.st_mode) or library_metadata.st_uid != uid:
        sys.exit(3)
    try:
        library_fd = os.open('Library', os.O_RDONLY | directory | no_follow, dir_fd=home_fd)
    except OSError:
        sys.exit(4)
    try:
        try:
            agents_metadata = os.stat('LaunchAgents', dir_fd=library_fd, follow_symlinks=False)
        except FileNotFoundError:
            sys.exit(0)
        if stat.S_ISLNK(agents_metadata.st_mode):
            if agents_metadata.st_uid != uid:
                sys.exit(3)
            os.unlink('LaunchAgents', dir_fd=library_fd)
            sys.exit(0)
        if not stat.S_ISDIR(agents_metadata.st_mode) or agents_metadata.st_uid != uid:
            sys.exit(3)
        try:
            agents_fd = os.open('LaunchAgents', os.O_RDONLY | directory | no_follow, dir_fd=library_fd)
        except OSError:
            sys.exit(4)
        def remove_contents(fd):
            for name in os.listdir(fd):
                metadata = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if metadata.st_uid != uid:
                    raise PermissionError('LaunchAgents contains an entry not owned by the builder')
                if stat.S_ISDIR(metadata.st_mode):
                    child_fd = os.open(name, os.O_RDONLY | directory | no_follow, dir_fd=fd)
                    try:
                        if os.fstat(child_fd).st_uid != uid:
                            raise PermissionError('LaunchAgents contains a directory not owned by the builder')
                        remove_contents(child_fd)
                    finally:
                        os.close(child_fd)
                    os.rmdir(name, dir_fd=fd)
                else:
                    os.unlink(name, dir_fd=fd)
        try:
            remove_contents(agents_fd)
        finally:
            os.close(agents_fd)
        os.rmdir('LaunchAgents', dir_fd=library_fd)
    finally:
        os.close(library_fd)
finally:
    os.close(home_fd)
'''
CHECK_BUILDER_LAUNCH_AGENTS = r'''import os, stat, sys
home = os.path.abspath(sys.argv[1])
uid = int(sys.argv[2])
if os.path.normpath(home) != home or os.path.realpath(home) != home:
    sys.exit(3)
try:
    metadata = os.lstat(home)
except FileNotFoundError:
    sys.exit(0)
except OSError:
    sys.exit(4)
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid:
    sys.exit(3)
no_follow = getattr(os, 'O_NOFOLLOW', 0)
directory = getattr(os, 'O_DIRECTORY', 0)
home_fd = os.open(home, os.O_RDONLY | directory | no_follow)
try:
    try:
        library = os.stat('Library', dir_fd=home_fd, follow_symlinks=False)
    except FileNotFoundError:
        sys.exit(0)
    if stat.S_ISLNK(library.st_mode):
        sys.exit(1)
    if not stat.S_ISDIR(library.st_mode) or library.st_uid != uid:
        sys.exit(3)
    library_fd = os.open('Library', os.O_RDONLY | directory | no_follow, dir_fd=home_fd)
    try:
        try:
            agents = os.stat('LaunchAgents', dir_fd=library_fd, follow_symlinks=False)
        except FileNotFoundError:
            sys.exit(0)
        if stat.S_ISLNK(agents.st_mode):
            sys.exit(1)
        if not stat.S_ISDIR(agents.st_mode) or agents.st_uid != uid:
            sys.exit(3)
        sys.exit(1)
    finally:
        os.close(library_fd)
finally:
    os.close(home_fd)
'''


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()


def pushed_merge_commits(records, repo):
    """Return newly pushed first-parent merge commits in push order."""
    selected = []
    seen = set()
    for record in records:
        fields = record.split()
        if len(fields) != 4:
            raise ValueError('Invalid pre-push ref record')
        local_ref, local_sha, remote_ref, remote_sha = fields
        if local_ref != 'refs/heads/main' or remote_ref != 'refs/heads/main':
            continue
        if local_sha == ZERO_SHA:
            continue
        invalid_local = not re.fullmatch(r'[0-9a-f]{40}', local_sha)
        invalid_remote = remote_sha != ZERO_SHA and not re.fullmatch(r'[0-9a-f]{40}', remote_sha)
        if invalid_local or invalid_remote:
            raise ValueError('Invalid pre-push commit identity')
        if remote_sha == local_sha:
            continue
        if remote_sha == ZERO_SHA:
            raise ValueError('Refusing release preparation for a new remote main branch')
        ancestor = subprocess.run(
            ['git', '-C', str(repo), 'merge-base', '--is-ancestor', remote_sha, local_sha],
            check=False)
        if ancestor.returncode:
            raise ValueError('Refusing a non-fast-forward release push')
        revision = f'{remote_sha}..{local_sha}'
        output = git(repo, 'rev-list', '--first-parent', '--merges', '--reverse', revision)
        for sha in output.splitlines():
            if sha not in seen:
                selected.append(sha)
                seen.add(sha)
    return selected


def reserve_plan(repo, commit):
    count = int(git(repo, 'rev-list', '--count', commit))
    repository = subprocess.check_output(
        ['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'],
        cwd=repo, text=True).strip()
    if repository.lower() != RELEASE_REPOSITORY:
        raise ValueError(f'Refusing release allocation for unexpected repository: {repository}')
    token = subprocess.check_output(['gh', 'auth', 'token'], cwd=repo, text=True).strip()
    event = {'action': 'closed', 'pull_request': {
        'merged': True, 'base': {'ref': 'main'}, 'merge_commit_sha': commit}}
    plan = release_versions.reserve(release_pipeline.GitHub(repository, token), event, count)
    return release_pipeline.validate_plan(plan, commit, count)


def builder_home():
    account = f'/Users/{BUILDER_USER}'
    details = subprocess.check_output(
        ['/usr/bin/dscl', '.', '-read', account, 'NFSHomeDirectory'], text=True).strip()
    if not details.startswith('NFSHomeDirectory: '):
        raise ValueError(f'Cannot resolve the {BUILDER_USER} home directory')
    home = Path(details.split(':', 1)[1].strip())
    if not home.is_absolute() or home == Path.home():
        raise ValueError(f'Invalid or unsafe {BUILDER_USER} home directory')
    groups = subprocess.check_output(['/usr/bin/id', '-Gn', BUILDER_USER], text=True).split()
    if 'admin' in groups:
        raise ValueError(f'{BUILDER_USER} must be a standard macOS account')
    uid = builder_uid()
    validate_builder_home(home, uid)
    shell_info = subprocess.check_output(
        ['/usr/bin/dscl', '.', '-read', account, 'UserShell'], text=True).strip()
    if shell_info != 'UserShell: /usr/bin/false':
        raise ValueError(f'{BUILDER_USER} must have a non-interactive /usr/bin/false login shell')
    subprocess.run(['/usr/bin/sudo', '-v'], env=SUDO_ENV, check=True)
    elevated = subprocess.run([
        '/usr/bin/sudo', '-u', BUILDER_USER, '-H', '/usr/bin/env', '-i',
        f'HOME={home}', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
        '/usr/bin/sudo', '-n', '-l',
    ], env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if elevated.returncode == 0:
        raise ValueError(f'{BUILDER_USER} must not have sudo privileges')
    isolation = subprocess.run([
        '/usr/bin/sudo', '-u', BUILDER_USER, '-H', '/usr/bin/env', '-i',
        f'HOME={home}', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
        '/bin/sh', '-c', 'test -d "$1" && test ! -r "$2" && test ! -x "$2"',
        BUILDER_USER, str(home), str(Path.home().resolve()),
    ], env=SUDO_ENV, check=False)
    if isolation.returncode:
        raise ValueError(f'{BUILDER_USER} home is missing or owner home is accessible')
    assert_builder_account_idle()
    return home


@contextmanager
def sudo_keepalive(interval=SUDO_KEEPALIVE_INTERVAL_SECONDS):
    """Keep the owner's per-tty sudo timestamp alive for the whole push.

    macOS expires the cached timestamp after roughly five idle minutes and a
    single long builder step (the package build) provides exactly that gap:
    every later `sudo -n` call, including the package stream and cleanup,
    would then fail non-interactively with "a password is required". A
    dedicated shell child refreshes the ticket with `sudo -n true`, which
    never prompts and never handles credentials. The child must keep the
    controlling terminal (sudo validates the ticket against that tty) but
    runs in its own process group so it can be stopped deterministically.
    """
    command = [
        '/bin/sh', '-c',
        f'while :; do /usr/bin/sudo -n true >/dev/null 2>&1; sleep {interval}; done',
    ]
    process = subprocess.Popen(
        command, env=SUDO_ENV, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        preexec_fn=BUILDER_PREEXEC)
    try:
        yield process
    finally:
        terminate_process_group(process, grace=1)


def builder_uid():
    value = subprocess.check_output(['/usr/bin/id', '-u', BUILDER_USER], text=True).strip()
    if not value.isdecimal() or int(value) == 0:
        raise ValueError(f'Invalid UID for {BUILDER_USER}')
    return int(value)


def validate_builder_home(home, uid):
    home = Path(home)
    try:
        metadata = home.lstat()
    except OSError:
        raise ValueError(f'{BUILDER_USER} home is missing or inaccessible') from None
    if (stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode) or
            metadata.st_uid != uid or metadata.st_mode & 0o077 or
            home.resolve() != home):
        raise ValueError(f'{BUILDER_USER} home must be a real, private directory owned by its UID')


def builder_has_processes():
    result = subprocess.run(
        ['/usr/bin/pgrep', '-u', BUILDER_USER, '-f', '.'],
        env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=5, check=False)
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    raise OSError(f'Cannot inspect {BUILDER_USER} processes: {result.stderr.strip()}')


def assert_no_builder_sessions():
    sessions = subprocess.check_output(['/usr/bin/who'], text=True)
    if any(line.split() and line.split()[0] == BUILDER_USER for line in sessions.splitlines()):
        raise ValueError(f'{BUILDER_USER} must not have an interactive session')


def read_builder_crontab():
    status, output = read_bounded_command_output([
        '/usr/bin/sudo', '-n', '-u', BUILDER_USER, '-H', '/usr/bin/crontab', '-l',
    ], MAX_ATQ_OUTPUT_BYTES, MAX_AT_JOBS, 5, f'{BUILDER_USER} crontab',
       merge_stderr=True, allowed_return_codes=(0, 1))
    if status == 0:
        return output
    message = output.decode(errors='replace').lower()
    if status == 1 and f'no crontab for {BUILDER_USER}' in message:
        return None
    raise OSError(f'Cannot inspect {BUILDER_USER} crontab (status {status}): {message.strip()}')


def assert_no_builder_crontab():
    contents = read_builder_crontab()
    if contents is not None and contents.strip():
        raise ValueError(f'{BUILDER_USER} must not have a nonempty crontab')
    return contents


def remove_builder_crontab():
    subprocess.run([
        '/usr/bin/sudo', '-n', '-u', BUILDER_USER, '-H', '/usr/bin/crontab', '-r',
    ], env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
       timeout=5, check=True)


def install_builder_crontab(contents):
    subprocess.run([
        '/usr/bin/sudo', '-n', '-u', BUILDER_USER, '-H', '/usr/bin/crontab', '-',
    ], env=SUDO_ENV, input=contents, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
       timeout=5, check=True)


def cleanup_builder_crontab(original):
    try:
        current = read_builder_crontab()
    except OutputLimitError as error:
        remove_builder_crontab()
        if original is not None:
            install_builder_crontab(original)
        if read_builder_crontab() != original:
            raise OSError(f'Could not restore the original {BUILDER_USER} crontab state') from error
        raise ValueError(
            f'Build created an oversized {BUILDER_USER} crontab; original state was restored') from error
    if current == original:
        return False
    if current is not None:
        remove_builder_crontab()
    if original is not None:
        install_builder_crontab(original)
    if read_builder_crontab() != original:
        raise OSError(f'Could not restore the original {BUILDER_USER} crontab state')
    raise ValueError(f'Build changed the {BUILDER_USER} crontab; the original state was restored')


class OutputLimitError(ValueError):
    """Raised when a bounded child emits more data or rows than allowed."""


def read_bounded_command_output(command, max_bytes, max_lines, timeout, label,
                                merge_stderr=False, allowed_return_codes=(0,)):
    process = subprocess.Popen(
        command, env=SUDO_ENV, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
        preexec_fn=BUILDER_PREEXEC)
    output = bytearray()
    line_count = 0
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f'{label} exceeded its time limit')
            readable, _, _ = select.select([process.stdout], [], [], remaining)
            if not readable:
                raise TimeoutError(f'{label} exceeded its time limit')
            chunk = os.read(process.stdout.fileno(), min(4096, max_bytes + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            line_count += chunk.count(b'\n')
            if len(output) > max_bytes:
                raise OutputLimitError(f'{label} output exceeds {max_bytes} bytes')
            if line_count > max_lines:
                raise OutputLimitError(f'{label} exceeds {max_lines} rows')
        status = process.wait(timeout=max(0, deadline - time.monotonic()))
        if status not in allowed_return_codes:
            raise OSError(f'{label} failed with exit status {status}')
        if output and not output.endswith(b'\n') and line_count == max_lines:
            raise OutputLimitError(f'{label} exceeds {max_lines} rows')
        return status, bytes(output)
    except BaseException:
        terminate_process_group(process, grace=0)
        raise
    finally:
        process.stdout.close()


def read_builder_at_jobs():
    status, output = read_bounded_command_output([
        '/usr/bin/sudo', '-n', '-u', BUILDER_USER, '-H', '/usr/bin/atq',
    ], MAX_ATQ_OUTPUT_BYTES, MAX_AT_JOBS, 5, f'{BUILDER_USER} atq')
    if status:
        raise OSError(f'{BUILDER_USER} atq failed with exit status {status}')
    jobs = set()
    for line in output.decode(errors='replace').splitlines():
        match = re.match(r'^\s*(\d+)\s', line)
        if not match:
            raise OSError(f'Cannot parse {BUILDER_USER} atq output: {line!r}')
        jobs.add(match.group(1))
        if len(jobs) > MAX_AT_JOBS:
            raise ValueError(f'{BUILDER_USER} atq exceeds {MAX_AT_JOBS} jobs')
    return frozenset(jobs)


def assert_no_builder_at_jobs():
    jobs = read_builder_at_jobs()
    if jobs:
        raise ValueError(f'{BUILDER_USER} must not have pre-existing at jobs')
    return jobs


def remove_builder_at_jobs(jobs):
    deadline = time.monotonic() + AT_JOB_CLEANUP_TIMEOUT_SECONDS
    for job in sorted(jobs, key=int):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f'Removing {BUILDER_USER} at jobs exceeded its total time limit')
        subprocess.run([
            '/usr/bin/sudo', '-n', '-u', BUILDER_USER, '-H', '/usr/bin/atrm', job,
        ], env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
           timeout=remaining, check=True)


def cleanup_builder_at_jobs(original):
    current = read_builder_at_jobs()
    if current == original:
        return False
    created = current - original
    if created:
        remove_builder_at_jobs(created)
    remaining = read_builder_at_jobs()
    if remaining != original:
        raise OSError(f'Could not restore the original {BUILDER_USER} at-job state')
    raise ValueError(f'Build created {BUILDER_USER} at jobs; they were removed')


def assert_builder_account_idle():
    assert_no_builder_sessions()
    if builder_has_processes():
        raise ValueError(f'{BUILDER_USER} must be dedicated to this build and idle before use')
    return assert_no_builder_crontab(), assert_no_builder_at_jobs()


@contextmanager
def builder_account_lock():
    prepare_builder_lock()
    descriptor = os.open(
        BUILDER_LOCK_PATH,
        os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0))
    locked = False
    try:
        acquire_builder_lock(descriptor)
        locked = True
        yield
    finally:
        if locked:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def acquire_builder_lock(descriptor, timeout=BUILDER_LOCK_TIMEOUT_SECONDS):
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(
                    f'Timed out waiting for the shared {BUILDER_USER} build lock') from None
            time.sleep(min(PROCESS_POLL_INTERVAL_SECONDS, remaining))


def prepare_builder_lock():
    admin_gid = grp.getgrnam('admin').gr_gid
    subprocess.run([
        '/usr/bin/sudo', '-n', '/usr/bin/install', '-d', '-o', 'root', '-g', 'wheel',
        '-m', '0755', str(BUILDER_LOCK_PATH.parent),
    ], env=SUDO_ENV, timeout=5, check=True)
    directory = BUILDER_LOCK_PATH.parent.lstat()
    if (stat.S_ISLNK(directory.st_mode) or not stat.S_ISDIR(directory.st_mode) or
            directory.st_uid != 0 or directory.st_mode & 0o022):
        raise ValueError('Machine-wide builder lock directory is not safely provisioned')
    try:
        existing_lock = BUILDER_LOCK_PATH.lstat()
    except FileNotFoundError:
        existing_lock = None
    if existing_lock is not None and (
            stat.S_ISLNK(existing_lock.st_mode) or not stat.S_ISREG(existing_lock.st_mode) or
            existing_lock.st_uid != 0):
        raise ValueError('Machine-wide builder lock file is not safely provisioned')
    subprocess.run([
        '/usr/bin/sudo', '-n', '/usr/bin/touch', str(BUILDER_LOCK_PATH),
    ], env=SUDO_ENV, timeout=5, check=True)
    subprocess.run([
        # macOS ships chown in /usr/sbin; /usr/bin/chown does not exist.
        '/usr/bin/sudo', '-n', '/usr/sbin/chown', 'root:admin', str(BUILDER_LOCK_PATH),
    ], env=SUDO_ENV, timeout=5, check=True)
    subprocess.run([
        '/usr/bin/sudo', '-n', '/bin/chmod', '0660', str(BUILDER_LOCK_PATH),
    ], env=SUDO_ENV, timeout=5, check=True)
    directory = BUILDER_LOCK_PATH.parent.lstat()
    lock = BUILDER_LOCK_PATH.lstat()
    validate_builder_lock_metadata(directory, lock, admin_gid)


def validate_builder_lock_metadata(directory, lock, admin_gid):
    if (stat.S_ISLNK(directory.st_mode) or not stat.S_ISDIR(directory.st_mode) or
            directory.st_uid != 0 or directory.st_mode & 0o022 or
            stat.S_ISLNK(lock.st_mode) or not stat.S_ISREG(lock.st_mode) or
            lock.st_uid != 0 or lock.st_gid != admin_gid or
            lock.st_mode & 0o777 != 0o660):
        raise ValueError('Machine-wide builder lock path is not safely provisioned')


def signal_builder_account(signal_name):
    result = subprocess.run([
        '/usr/bin/sudo', '-n', '/usr/bin/pkill', f'-{signal_name}',
        '-u', BUILDER_USER, '-f', '.',
    ], env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
       timeout=5, check=False)
    if result.returncode not in (0, 1):
        raise OSError(f'Cannot signal {BUILDER_USER} processes: {result.stderr.decode().strip()}')


def wait_for_builder_idle(timeout):
    deadline = time.monotonic() + timeout
    while builder_has_processes():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(PROCESS_POLL_INTERVAL_SECONDS, remaining))
    return True


def terminate_builder_account_processes():
    assert_no_builder_sessions()
    signal_builder_account('TERM')
    if wait_for_builder_idle(PROCESS_TERMINATION_GRACE_SECONDS):
        return
    signal_builder_account('KILL')
    if not wait_for_builder_idle(BUILDER_CLEANUP_TIMEOUT_SECONDS):
        raise TimeoutError(f'Could not stop all processes owned by {BUILDER_USER}')


def inspect_builder_launch_agents(home, commit='launchd-inspection', workspace_root=None):
    script = r'''import os, stat, sys
home = sys.argv[1]
for path in (os.path.join(home, 'Library'), os.path.join(home, 'Library', 'LaunchAgents')):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        continue
    except OSError:
        sys.exit(4)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        sys.exit(3)
    if path.endswith('LaunchAgents'):
        try:
            if next(os.scandir(path), None) is not None:
                sys.exit(2)
        except OSError:
            sys.exit(4)
sys.exit(0)
'''
    command = builder_command(
        home, commit, ['/usr/bin/python3', '-c', script, str(home)],
        cwd=BUILDER_TEMP_ROOT, workspace_root=workspace_root)
    result = subprocess.run(
        command, env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=5, check=False)
    if result.returncode in (0, 2):
        return result.returncode == 2
    if result.returncode == 3:
        raise ValueError(f'Unsafe Library or LaunchAgents directory in {BUILDER_USER} home')
    if result.returncode == 4:
        raise OSError(f'Cannot inspect LaunchAgents in {BUILDER_USER} home')
    raise OSError(
        f'LaunchAgents inspection failed for {BUILDER_USER}: '
        f'{result.stderr.decode(errors="replace").strip()}')


def assert_no_builder_launch_agents(home, commit='launchd-inspection', workspace_root=None):
    if inspect_builder_launch_agents(home, commit, workspace_root):
        raise ValueError(f'{BUILDER_USER} must not have pre-existing LaunchAgents')


def bootout_builder_launchd_domain(uid):
    """Boot out the builder's launchd domain; bootout is idempotent and safe on
    an already-absent domain. Never probe with `launchctl print`: printing a
    user domain materializes it and spawns its daemons, so launchd liveness is
    judged from process state and bootout normalization instead."""
    result = subprocess.run(
        ['/usr/bin/sudo', '-n', '/bin/launchctl', 'bootout', f'user/{uid}'],
        env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=20, check=False)
    if result.returncode == 0:
        return True
    details = (result.stdout + result.stderr).decode(errors='replace').strip()
    raise OSError(f'Cannot boot out the {BUILDER_USER} launchd domain: {details}')


def clear_builder_launchd_domain(uid):
    bootout_builder_launchd_domain(uid)
    deadline = time.monotonic() + PROCESS_TERMINATION_GRACE_SECONDS
    while builder_has_processes():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f'Could not unload {BUILDER_USER} launchd domain')
        time.sleep(min(PROCESS_POLL_INTERVAL_SECONDS, remaining))
    return True


def remove_builder_launch_agents_safely(home, uid):
    result = subprocess.run([
        '/usr/bin/sudo', '-n', '/usr/bin/python3', '-c',
        SAFE_REMOVE_BUILDER_LAUNCH_AGENTS, str(home), str(uid),
    ], env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
       timeout=BUILDER_CLEANUP_TIMEOUT_SECONDS, check=False)
    if result.returncode:
        details = result.stderr.decode(errors='replace').strip()
        raise OSError(
            f'Cannot safely remove {BUILDER_USER} LaunchAgents '
            f'(status {result.returncode}): {details}')


def builder_launch_agents_remain_safely(home, uid):
    result = subprocess.run([
        '/usr/bin/sudo', '-n', '/usr/bin/python3', '-c',
        CHECK_BUILDER_LAUNCH_AGENTS, str(home), str(uid),
    ], env=SUDO_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
       timeout=5, check=False)
    if result.returncode == 0:
        return False
    if result.returncode == 1:
        return True
    details = result.stderr.decode(errors='replace').strip()
    raise OSError(
        f'Cannot verify {BUILDER_USER} LaunchAgents '
        f'(status {result.returncode}): {details}')


def prepare_builder_launchd(home):
    assert_no_builder_launch_agents(home)
    if builder_has_processes():
        raise ValueError(
            f'{BUILDER_USER} launchd domain is active with running processes; '
            'refusing to alter it')
    clear_builder_launchd_domain(builder_uid())


def cleanup_builder_launchd(home, build_home):
    uid = builder_uid()
    clear_builder_launchd_domain(uid)
    remove_builder_launch_agents_safely(home, uid)
    remove_builder_launch_agents_safely(build_home, uid)


def verify_builder_launchd_clean(home, build_home, uid, original_crontab, original_at_jobs):
    cleanup_errors = []
    state_violations = []

    def cleanup_auxiliary_state():
        for candidate in (home, build_home):
            try:
                remove_builder_launch_agents_safely(candidate, uid)
            except BaseException as error:
                cleanup_errors.append(error)
        for cleanup, original, _label in (
                (cleanup_builder_crontab, original_crontab, 'crontab'),
                (cleanup_builder_at_jobs, original_at_jobs, 'at jobs')):
            try:
                cleanup(original)
            except ValueError as error:
                state_violations.append(error)
            except BaseException as error:
                cleanup_errors.append(error)

    def teardown():
        try:
            clear_builder_launchd_domain(uid)
        except BaseException as error:
            cleanup_errors.append(error)
        try:
            terminate_builder_account_processes()
        except BaseException as error:
            cleanup_errors.append(error)
        cleanup_auxiliary_state()
        # Cron and at jobs can have launched processes during removal; sweep again.
        try:
            terminate_builder_account_processes()
        except BaseException as error:
            cleanup_errors.append(error)

    def inspect_state():
        state = []
        try:
            if builder_has_processes():
                state.append(f'{BUILDER_USER} processes remain')
        except BaseException as error:
            cleanup_errors.append(error)
        for candidate in (home, build_home):
            try:
                if builder_launch_agents_remain_safely(candidate, uid):
                    state.append(f'{BUILDER_USER} LaunchAgents remain')
            except BaseException as error:
                cleanup_errors.append(error)
        for read, original, label in (
                (read_builder_crontab, original_crontab, 'crontab'),
                (read_builder_at_jobs, original_at_jobs, 'at jobs')):
            try:
                if read() != original:
                    state.append(f'{BUILDER_USER} {label} state changed')
            except BaseException as error:
                cleanup_errors.append(error)
        try:
            if bootout_builder_launchd_domain(uid) and builder_has_processes():
                state.append(f'{BUILDER_USER} launchd domain remains active')
        except BaseException as error:
            cleanup_errors.append(error)
        return state

    state = inspect_state()
    for _attempt in range(2):
        if not state:
            break
        teardown()
        state = inspect_state()
    if state:
        raise RuntimeError(
            'Builder persistence state remains after bounded teardown; quarantine the '
            f'{BUILDER_USER} account and manually remove its processes, launchd domain, '
            f'LaunchAgents, crontab, and at jobs: {", ".join(state)}')
    if cleanup_errors:
        raise cleanup_errors[0]
    if state_violations:
        raise state_violations[0]


def builder_command(home, commit, command, cwd=BUILDER_TEMP_ROOT, workspace_root=None):
    execution_home = Path(workspace_root) / 'home' if workspace_root else Path(home)
    temporary = Path(workspace_root) / 'tmp' if workspace_root else BUILDER_TEMP_ROOT
    cache = execution_home / 'Library' / 'Caches' / 'Stash' / 'LocalRelease' / commit
    environment = {
        'HOME': str(execution_home),
        'USER': BUILDER_USER,
        'LOGNAME': BUILDER_USER,
        'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        'TMPDIR': str(temporary),
        'CFFIXED_USER_HOME': str(execution_home),
        'STASH_CHECK_ROOT': str(cache / 'verify'),
        'CLANG_MODULE_CACHE_PATH': str(cache / 'clang'),
        'SWIFTPM_MODULECACHE_OVERRIDE': str(cache / 'modules'),
    }
    args = [
        '/usr/bin/sudo', '-n', '-u', BUILDER_USER, '-H', '/usr/bin/env', '-i',
        *[f'{key}={value}' for key, value in environment.items()],
        '/bin/sh', '-c', 'umask 077; cd "$1"; shift; exec "$@"',
        BUILDER_USER, str(cwd), *[str(part) for part in command],
    ]
    return args


def process_group_exists(process_group_id):
    try:
        os.killpg(process_group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def signal_builder_group(process, sig):
    """Deliver sig to the child's process group, degrading to the direct child
    when macOS denies the group signal (EPERM has been observed for builder
    children spawned several sudo layers deep). The direct child is always
    same-uid; if even that signal is denied, the PermissionError propagates so
    callers keep their fail-closed behavior."""
    try:
        os.killpg(process.pid, sig)
    except PermissionError:
        try:
            os.kill(process.pid, sig)
        except ProcessLookupError:
            pass


def terminate_process_group(process, grace=PROCESS_TERMINATION_GRACE_SECONDS):
    try:
        signal_builder_group(process, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    deadline = time.monotonic() + grace
    while process_group_exists(process.pid):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        if process.poll() is None:
            try:
                process.wait(timeout=min(PROCESS_POLL_INTERVAL_SECONDS, remaining))
            except subprocess.TimeoutExpired:
                pass
        else:
            time.sleep(min(PROCESS_POLL_INTERVAL_SECONDS, remaining))
    if process_group_exists(process.pid):
        try:
            signal_builder_group(process, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS can deny signals to a zombie-only group until its child is
            # reaped; fail closed only when no signal path can reach the child.
            if process.poll() is None or process_group_exists(process.pid):
                raise
    process.wait()
    # Group-orphaned zombies are reaped by launchd shortly after the leader;
    # give that a brief settle window before declaring the cleanup failed.
    deadline = time.monotonic() + PROCESS_GROUP_REAP_SETTLE_SECONDS
    while process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    if process_group_exists(process.pid):
        raise PermissionError('The builder process group could not be destroyed')


def run_as_builder(home, commit, command, cwd=BUILDER_TEMP_ROOT,
                   stdin=subprocess.DEVNULL, timeout=None, workspace_root=None):
    args = builder_command(home, commit, command, cwd, workspace_root)
    process = subprocess.Popen(
        args, env=SUDO_ENV, stdin=stdin, preexec_fn=BUILDER_PREEXEC)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate_process_group(process)
        raise
    if status:
        raise subprocess.CalledProcessError(status, args)
    return subprocess.CompletedProcess(args, status)


def archive_source_to_builder(repo, commit, home, workspace, source):
    archive_command = ['git', '-C', str(repo), 'archive', '--format=tar', commit]
    deadline = time.monotonic() + BUILDER_TRANSFER_TIMEOUT_SECONDS
    archive = subprocess.Popen(
        archive_command, stdout=subprocess.PIPE, preexec_fn=BUILDER_PREEXEC)
    try:
        run_as_builder(home, commit, ['/usr/bin/tar', '-xf', '-', '-C', str(source)],
                       cwd=workspace, stdin=archive.stdout,
                       timeout=max(0, deadline - time.monotonic()),
                       workspace_root=workspace)
        archive_status = archive.wait(timeout=max(0, deadline - time.monotonic()))
        if archive_status:
            raise subprocess.CalledProcessError(archive_status, archive_command)
    except BaseException:
        archive.stdout.close()
        terminate_process_group(archive)
        raise
    archive.stdout.close()


class IdleTimeoutReader:
    """Read a pipe with a fixed total and per-read idle deadline."""
    def __init__(self, stream, timeout):
        self.stream = stream
        self.file_descriptor = stream.fileno()
        self.deadline = time.monotonic() + timeout
        self.timeout = timeout

    def read(self, size=-1):
        if size < 0:
            raise ValueError('Unbounded reads are not supported for builder streams')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Builder package transfer exceeded its time limit')
        readable, _, _ = select.select(
            [self.file_descriptor], [], [], min(remaining, self.timeout))
        if not readable:
            raise TimeoutError('Builder package transfer stalled')
        return os.read(self.file_descriptor, size)


def copy_package_stream(package_stream, destination):
    names = {'Stash-macOS.zip', 'Stash-macOS.dmg', 'SHA256SUMS', 'metadata.json'}
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    destination.chmod(0o700)
    found = set()
    total_size = 0
    try:
        with tarfile.open(fileobj=package_stream, mode='r|') as archive:
            for member in archive:
                if member.name not in names or member.name in found or not member.isfile():
                    raise ValueError('Builder returned an invalid package stream')
                limit = (MAX_PACKAGE_BINARY_BYTES if member.name in {
                    'Stash-macOS.zip', 'Stash-macOS.dmg'} else MAX_PACKAGE_METADATA_BYTES)
                if member.size < 0 or member.size > limit:
                    raise ValueError(f'Builder package file exceeds size limit: {member.name}')
                if total_size + member.size > MAX_PACKAGE_STREAM_BYTES:
                    raise ValueError('Builder package stream exceeds aggregate size limit')
                total_size += member.size
                found.add(member.name)
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError(f'Builder package file is unreadable: {member.name}')
                descriptor = os.open(
                    destination / member.name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600)
                with source, os.fdopen(descriptor, 'wb') as output:
                    shutil.copyfileobj(source, output)
                (destination / member.name).chmod(0o600)
        if found != names:
            raise ValueError('Builder returned an incomplete package stream')
    except (OSError, tarfile.TarError, ValueError, TimeoutError):
        shutil.rmtree(destination, ignore_errors=True)
        raise


def stream_builder_package(home, commit, workspace, destination):
    names = ['Stash-macOS.zip', 'Stash-macOS.dmg', 'SHA256SUMS', 'metadata.json']
    # macOS bsdtar archives extended attributes (com.apple.provenance on every
    # ditto/hdiutil artifact) as AppleDouble "._" companion members by default;
    # the package stream must contain exactly the four release files.
    command = ['/usr/bin/tar', '--no-mac-metadata', '-cf', '-', '-C',
               str(workspace / 'package'), *names]
    process = subprocess.Popen(
        builder_command(home, commit, command, cwd=workspace, workspace_root=workspace),
        env=SUDO_ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        preexec_fn=BUILDER_PREEXEC)
    try:
        reader = IdleTimeoutReader(process.stdout, BUILDER_TRANSFER_TIMEOUT_SECONDS)
        copy_package_stream(reader, destination)
        remaining = max(0, reader.deadline - time.monotonic())
        status = process.wait(timeout=remaining)
        if status:
            raise subprocess.CalledProcessError(status, command)
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        terminate_process_group(process)
        raise
    finally:
        process.stdout.close()


def build_isolated_package(repo, plan, home, output):
    with builder_account_lock():
        original_crontab, original_at_jobs = assert_builder_account_idle()
        prepare_builder_launchd(home)
        workspace = BUILDER_TEMP_ROOT / f'stash-release-{plan["commit"][:12]}-{uuid.uuid4().hex}'
        source = workspace / 'source'
        package = workspace / 'package'
        build_home = workspace / 'home'
        build_tmp = workspace / 'tmp'
        workspace_created = False
        primary_error = None
        try:
            run_as_builder(home, plan['commit'], ['/bin/mkdir', '-m', '0700', str(workspace)])
            workspace_created = True
            run_as_builder(home, plan['commit'], [
                '/bin/mkdir', '-m', '0700', str(source), str(build_home), str(build_tmp)])
            archive_source_to_builder(repo, plan['commit'], home, workspace, source)
            run_as_builder(home, plan['commit'], [
                'python3', str(source / 'Scripts' / 'package_release.py'),
                '--version', plan['version'], '--build-number', str(plan['build_number']),
                '--commit', plan['commit'], '--source-commit', plan['commit'], '--output', str(package),
            ], cwd=source, timeout=BUILDER_BUILD_TIMEOUT_SECONDS,
                workspace_root=workspace)
            stream_builder_package(home, plan['commit'], workspace, output)
        except BaseException as error:
            primary_error = error
            raise
        finally:
            cleanup_errors = []
            first_process_sweep_error = None
            try:
                terminate_builder_account_processes()
            except BaseException as error:
                first_process_sweep_error = error
            if workspace_created:
                try:
                    cleanup_builder_launchd(home, build_home)
                except BaseException as error:
                    cleanup_errors.append(error)
                final_process_sweep_succeeded = False
                try:
                    terminate_builder_account_processes()
                    final_process_sweep_succeeded = True
                except BaseException as error:
                    cleanup_errors.append(error)
                final_launchd_check_succeeded = False
                try:
                    verify_builder_launchd_clean(
                        home, build_home, builder_uid(), original_crontab, original_at_jobs)
                    final_launchd_check_succeeded = True
                except BaseException as error:
                    cleanup_errors.append(error)
                if first_process_sweep_error is not None and not (
                        isinstance(first_process_sweep_error, TimeoutError) and
                        final_process_sweep_succeeded and final_launchd_check_succeeded):
                    cleanup_errors.append(first_process_sweep_error)
            elif first_process_sweep_error is not None:
                cleanup_errors.append(first_process_sweep_error)
            if workspace_created:
                try:
                    run_as_builder(
                        home, plan['commit'], ['/bin/rm', '-rf', '--', str(workspace)],
                        timeout=BUILDER_CLEANUP_TIMEOUT_SECONDS)
                except BaseException as error:
                    cleanup_errors.append(error)
            if cleanup_errors:
                if primary_error is None:
                    raise cleanup_errors[0]
                print(f'Builder cleanup warning: {cleanup_errors[0]}', file=sys.stderr)


def queue_root():
    QUEUE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    QUEUE_ROOT.chmod(0o700)
    return QUEUE_ROOT


def inspect_zip_member(archive, member, limit, collect=False):
    """Stream-decompress one ZIP member while enforcing its actual size."""
    total = 0
    chunks = [] if collect else None
    try:
        with archive.open(member) as content:
            while True:
                chunk = content.read(min(64 * 1024, limit + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    raise ValueError('Package ZIP member exceeds actual size limit')
                if collect:
                    chunks.append(chunk)
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, zlib.error):
        raise ValueError('Package ZIP member is corrupt or unsupported') from None
    if total != member.file_size:
        raise ValueError('Package ZIP member size differs from its declaration')
    return b''.join(chunks) if collect else total


def validate_zip_layout(path):
    """Reject ZIP members that could write outside the expected app bundle."""
    try:
        path = Path(path)
        file_size = path.stat().st_size
        with path.open('rb') as source:
            tail_size = min(file_size, 22 + 65_535)
            source.seek(file_size - tail_size)
            tail = source.read(tail_size)
        signature = b'PK\x05\x06'
        end_record = tail.rfind(signature)
        record = None
        while end_record >= 0 and end_record + 22 <= len(tail):
            candidate = struct.unpack_from('<4s4H2LH', tail, end_record)
            if end_record + 22 + candidate[-1] == len(tail):
                record = candidate
                break
            end_record = tail.rfind(signature, 0, end_record)
        if record is None:
            raise ValueError('Package ZIP is missing a valid end record')
        _, disk_number, central_disk, disk_entries, total_entries, central_size, central_offset, comment_size = record
        if disk_number or central_disk or disk_entries != total_entries:
            raise ValueError('Multi-disk ZIP packages are unsupported')
        if (total_entries == 0xFFFF or central_size == 0xFFFFFFFF or
                central_offset == 0xFFFFFFFF):
            raise ValueError('ZIP64 packages exceed the bounded package contract')
        if total_entries > MAX_ZIP_MEMBERS:
            raise ValueError('Package ZIP contains too many members')
        if central_size > MAX_ZIP_CENTRAL_DIRECTORY_BYTES:
            raise ValueError('Package ZIP central directory exceeds size limit')
        if central_offset + central_size > file_size:
            raise ValueError('Package ZIP central directory is out of bounds')
        with zipfile.ZipFile(path) as archive:
            names = set()
            has_info = False
            members = archive.infolist()
            if len(members) > MAX_ZIP_MEMBERS:
                raise ValueError('Package ZIP contains too many members')
            total_uncompressed = 0
            for member in members:
                if member.file_size < 0 or member.file_size > MAX_ZIP_MEMBER_BYTES:
                    raise ValueError('Package ZIP member exceeds size limit')
                total_uncompressed += member.file_size
                if total_uncompressed > MAX_ZIP_UNCOMPRESSED_BYTES:
                    raise ValueError('Package ZIP exceeds uncompressed size limit')
            for member in members:
                name = member.filename
                path_parts = name.rstrip('/').split('/')
                if (not name or '\\' in name or name.startswith('/') or
                        any(part in {'', '.', '..'} for part in path_parts)):
                    raise ValueError('Package ZIP contains an unsafe path')
                parts = PurePosixPath(name).parts
                if not parts or parts[0] not in {'Stash.app', '__MACOSX'}:
                    raise ValueError('Package ZIP contains an unexpected top-level item')
                if name in names:
                    raise ValueError('Package ZIP contains duplicate paths')
                names.add(name)
                mode = (member.external_attr >> 16) & 0o170000
                if mode == stat.S_IFLNK:
                    if member.file_size > MAX_ZIP_SYMLINK_BYTES:
                        raise ValueError('Package ZIP symbolic link payload exceeds size limit')
                    target = inspect_zip_member(
                        archive, member, member.file_size, collect=True).decode(
                            'utf-8', errors='strict')
                    if target.startswith('/'):
                        raise ValueError('Package ZIP contains an absolute symbolic link')
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                    if resolved != 'Stash.app' and not resolved.startswith('Stash.app/'):
                        raise ValueError('Package ZIP contains an escaping symbolic link')
                elif mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise ValueError('Package ZIP contains a special file')
                else:
                    inspect_zip_member(archive, member, member.file_size)
                if name.rstrip('/') == 'Stash.app/Contents/Info.plist':
                    has_info = True
            if not has_info:
                raise ValueError('Package ZIP is missing the Stash app bundle')
    except (OSError, zipfile.BadZipFile, UnicodeDecodeError):
        raise ValueError('Package ZIP is invalid') from None


def validate_package_contents(directory, plan):
    """Validate package bytes with installed owner-side verifier code."""
    directory = Path(directory)
    validate_zip_layout(directory / 'Stash-macOS.zip')
    assets = release_pipeline.package_assets(directory, plan, require_dmg=True)
    receipt = json.loads(assets['metadata.json'])
    with tempfile.TemporaryDirectory(prefix='stash-package-check-') as temporary:
        extracted = Path(temporary)
        package_release.run(
            '/usr/bin/ditto', '-x', '-k', directory / 'Stash-macOS.zip', extracted,
            timeout=OWNER_VERIFY_TIMEOUT_SECONDS)
        app = extracted / 'Stash.app'
        package_release.verify_app(app, receipt)
        inventory = package_release.bundle_inventory(app)
        package_release.verify_dmg(directory / 'Stash-macOS.dmg', receipt, inventory)
    return assets


def read_pending(directory, commit, repo):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Invalid pending release directory')
    try:
        manifest = json.loads((directory / 'manifest.json').read_text())
    except (OSError, ValueError):
        raise ValueError('Pending release manifest is missing or invalid') from None
    plan = manifest.get('plan') if isinstance(manifest, dict) else None
    if (not isinstance(manifest, dict) or manifest.get('schema') != 1 or not isinstance(plan, dict)
            or plan.get('commit') != commit):
        raise ValueError('Pending release identity conflict')
    count = int(git(repo, 'rev-list', '--count', commit))
    release_pipeline.validate_plan(plan, commit, count)
    assets = release_pipeline.package_assets(directory, plan, require_dmg=True)
    expected = {name: {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
                for name, data in assets.items()}
    if manifest.get('assets') != expected:
        raise ValueError('Pending release asset receipt mismatch')
    return {'directory': str(directory), 'plan': plan, 'manifest': manifest}


def prepare_commit(repo, commit, pending_root=None):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid local merge commit')
    repo = Path(repo).resolve()
    pending_root = Path(pending_root) if pending_root is not None else queue_root()
    pending_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    pending_root.chmod(0o700)
    pending = pending_root / commit
    if pending.exists():
        return read_pending(pending, commit, repo)

    home = builder_home()
    plan = reserve_plan(repo, commit)
    count = int(git(repo, 'rev-list', '--count', commit))
    release_pipeline.validate_plan(plan, commit, count)
    with tempfile.TemporaryDirectory(prefix=f'.{commit[:12]}-', dir=pending_root) as temporary:
        output = Path(temporary) / 'package'
        build_isolated_package(repo, plan, home, output)
        assets = validate_package_contents(output, plan)
        manifest = {
            'schema': 1,
            'plan': plan,
            'created_at': datetime.now(timezone.utc).isoformat(),
            'assets': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
                       for name, data in assets.items()},
        }
        (output / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
        try:
            os.rename(output, pending)
        except FileExistsError:
            return read_pending(pending, commit, repo)
    return read_pending(pending, commit, repo)


def prepare_push(remote_name, records, repo, pending_root=None):
    if remote_name != 'origin':
        return []
    commits = pushed_merge_commits(records, repo)
    with sudo_keepalive():
        return [prepare_commit(repo, commit, pending_root) for commit in commits]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['pre-push'])
    parser.add_argument('remote_name')
    parser.add_argument('remote_url')
    args = parser.parse_args()
    if args.remote_name != 'origin':
        return
    repo = git(Path.cwd(), 'rev-parse', '--show-toplevel')
    if Path(__file__).resolve().is_relative_to(Path(repo).resolve()):
        raise ValueError('Install and run the local release helper outside the checkout')
    configured_origin = git(repo, 'remote', 'get-url', '--push', 'origin').removesuffix('.git').lower()
    requested_remote = args.remote_url.removesuffix('.git').lower()
    if requested_remote != configured_origin:
        raise ValueError('The pre-push origin URL differs from the configured origin')
    prepared = prepare_push(args.remote_name, sys.stdin, repo)
    for release in prepared:
        print(f"Prepared local development release {release['plan']['tag']}")


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        raise SystemExit(str(error))
