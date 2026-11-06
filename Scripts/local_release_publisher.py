#!/usr/bin/env python3
"""Publish verified local release packages after their commit reaches origin/main."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local_release
import release_pipeline
import release_versions


PUBLISHER_LABEL = 'com.kfathy.stash-local-release-publisher'
PACKAGE_RETENTION = timedelta(days=7)
GH_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'


def _validate_queue_root(root):
    root = Path(root)
    try:
        metadata = root.lstat()
    except OSError:
        raise ValueError('Local release queue is missing or inaccessible') from None
    if (root.is_symlink() or not root.is_dir() or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077):
        raise ValueError('Local release queue must be a private directory owned by this account')
    return root


@contextmanager
def _publisher_lock(root):
    path = root / '.publisher.lock'
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_mode & 0o077):
            raise ValueError('Local release publisher lock is not safely owned')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(descriptor)


def _read_created_at(manifest):
    value = manifest.get('created_at')
    if not isinstance(value, str):
        raise ValueError('Pending release creation time is missing')
    try:
        created = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        raise ValueError('Pending release creation time is invalid') from None
    if created.tzinfo is None:
        raise ValueError('Pending release creation time has no timezone')
    return created.astimezone(timezone.utc)


def _entry_directories(root):
    entries = []
    for path in root.iterdir():
        if path.name.startswith('.'):
            continue
        if not re.fullmatch('[0-9a-f]{40}', path.name):
            raise ValueError(f'Unexpected entry in local release queue: {path.name}')
        if path.is_symlink() or not path.is_dir():
            raise ValueError(f'Invalid pending release entry: {path.name}')
        entries.append(path)
    return entries


def _recover_rebuild_backups(repo, root):
    for backup in root.iterdir():
        match = re.fullmatch(r'\.([0-9a-f]{40})\.expired', backup.name)
        if not match:
            continue
        commit = match.group(1)
        pending = root / commit
        old = local_release.read_pending(backup, commit, repo)
        if pending.exists():
            current = local_release.read_pending(pending, commit, repo)
            if current['plan'] != old['plan']:
                raise ValueError(f'Conflicting pending package during rebuild recovery: {commit}')
            shutil.rmtree(backup)
        else:
            os.rename(backup, pending)


def rebuild_expired_package(repo, pending_root, commit, plan):
    """Rebuild an expired package from its original source and stable plan."""
    root = Path(pending_root)
    pending = root / commit
    old = local_release.read_pending(pending, commit, repo)
    if old['plan'] != plan:
        raise ValueError('Expired package plan differs from the queued release identity')
    backup = root / f'.{commit}.expired'
    if backup.exists():
        raise ValueError(f'An interrupted package rebuild already needs recovery: {commit}')
    os.rename(pending, backup)
    try:
        rebuilt = local_release.prepare_commit(repo, commit, root)
        if rebuilt.get('plan') != plan:
            raise ValueError('Rebuilt package changed the queued release identity')
        result = local_release.read_pending(pending, commit, repo)
        if result['plan'] != plan:
            raise ValueError('Rebuilt package source identity changed')
    except BaseException as error:
        if pending.exists():
            try:
                replacement = local_release.read_pending(pending, commit, repo)
            except BaseException:
                raise RuntimeError(
                    f'Cannot restore the expired package safely; inspect queue entry {commit}') from None
            if replacement['plan'] != plan:
                raise RuntimeError(
                    f'Conflicting replacement blocks restoration of queued package {commit}') from None
            shutil.rmtree(backup)
        else:
            os.rename(backup, pending)
        if (isinstance(error, subprocess.CalledProcessError)
                and error.cmd == ['/usr/bin/sudo', '-v']):
            raise RuntimeError(
                'Expired package rebuild needs owner authentication. Run '
                '`bash Scripts/install_local_release_publisher.sh retry` from a terminal '
                'and authenticate sudo; the queued package was retained.') from None
        raise
    shutil.rmtree(backup)
    return result


def release_notes(plan):
    return (
        'Stash local development release.\n\n'
        f"Commit: {plan['commit']}\n"
        f"Version: {plan['version']} (build {plan['build_number']})\n\n"
        'Local verification passed: core tests, universal macOS Release, and iOS simulator builds. '
        'The app is ad-hoc signed and unnotarized; iCloud sync and sharing are unavailable in this package. '
        'Device, cloud, permission, MCP, and commerce acceptance remain open.'
    )


def _remove_pending(path, root):
    path = Path(path)
    if path.parent.resolve() != Path(root).resolve() or path.is_symlink() or not path.is_dir():
        raise ValueError('Refusing to remove an unsafe pending release directory')
    shutil.rmtree(path)


def run_pending(repo, pending_root, api, *, now=None, plan_lookup=None,
                validate_package=None, rebuild_package=None, remove_pending=None):
    """Process each queued merge serially, retaining every failed or waiting entry."""
    root = Path(pending_root)
    if not root.exists():
        return []
    root = _validate_queue_root(root)
    if now is None:
        now = datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError('Publisher clock must be timezone-aware')
    plan_lookup = plan_lookup or release_versions.lookup
    validate_package = validate_package or local_release.validate_package_contents
    rebuild_package = rebuild_package or rebuild_expired_package
    remove_pending = remove_pending or _remove_pending
    with _publisher_lock(root) as acquired:
        if not acquired:
            return []
        _recover_rebuild_backups(repo, root)
        entries = []
        for path in _entry_directories(root):
            entries.append(local_release.read_pending(path, path.name, repo))
        if not entries:
            return []
        if not api.repository_is_private():
            raise ValueError('Refusing to publish Stash development releases from a public repository')
        entries.sort(key=lambda item: item['plan']['build_number'])
        results = []
        for pending in entries:
            plan = pending['plan']
            commit = plan['commit']
            if not api.commit_reachable_from_main(commit):
                results.append({'commit': commit, 'status': 'waiting-for-origin-main'})
                break
            if plan_lookup(api, commit) != plan:
                raise ValueError(f'Queued release differs from durable version assignment: {commit}')
            existing = api.release(plan['tag'])
            if existing is not None and (
                    existing.get('tag_name') != plan['tag'] or
                    existing.get('target_commitish') != plan['commit']):
                raise ValueError(f'Existing release identity conflicts with queued commit: {commit}')
            already_published = existing is not None and existing.get('draft') is False
            created = _read_created_at(pending['manifest'])
            current = now.astimezone(timezone.utc)
            if created > current:
                raise ValueError(f'Queued release has a future creation time: {commit}')
            if not already_published and current - created >= PACKAGE_RETENTION:
                pending = rebuild_package(repo, root, commit, plan)
                if pending.get('plan') != plan:
                    raise ValueError(f'Expired package rebuild changed release identity: {commit}')
            directory = Path(pending['directory'])
            assets = validate_package(directory, plan)
            release = release_pipeline.publish(api, plan, assets, release_notes(plan))
            if not isinstance(release, dict) or release.get('draft') is not False:
                raise ValueError(f'GitHub did not confirm publication for {commit}')
            remove_pending(directory, root)
            results.append({'commit': commit, 'tag': plan['tag'], 'status': 'published'})
        return results


def authenticated_api():
    gh = shutil.which('gh', path=GH_PATH)
    if gh is None:
        raise RuntimeError('GitHub CLI is unavailable; pending releases were retained')
    try:
        token_result = subprocess.run(
            [gh, 'auth', 'token', '--hostname', 'github.com'], env=dict(os.environ, PATH=GH_PATH),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError('GitHub CLI authentication is unavailable; pending releases were retained') from None
    token = token_result.stdout.strip()
    if token_result.returncode or not token:
        raise RuntimeError('GitHub CLI authentication is unavailable; pending releases were retained')
    return release_pipeline.GitHub(local_release.RELEASE_REPOSITORY, token)


def queue_status(pending_root=None):
    root = Path(pending_root) if pending_root is not None else local_release.QUEUE_ROOT
    if not root.exists():
        return []
    root = _validate_queue_root(root)
    commits = {path.name for path in _entry_directories(root)}
    for path in root.iterdir():
        match = re.fullmatch(r'\.([0-9a-f]{40})\.expired', path.name)
        if match:
            commits.add(match.group(1))
    return sorted(commits)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('run', 'retry', 'status'))
    parser.add_argument('--repo', required=True)
    parser.add_argument('--queue')
    args = parser.parse_args(argv)
    root = Path(args.queue) if args.queue else local_release.QUEUE_ROOT
    if args.action == 'status':
        print(json.dumps({'queued_commits': queue_status(root)}))
        return 0
    if not queue_status(root):
        return 0
    api = authenticated_api()
    results = run_pending(args.repo, root, api)
    for item in results:
        if item['status'] == 'published':
            print(f"Published local development release {item['tag']}")
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, RuntimeError) as error:
        raise SystemExit(str(error))
