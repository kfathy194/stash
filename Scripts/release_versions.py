"""Durable sequential release reservations. No operation touches source history."""
import base64
import json
import re

from release_pipeline import GitHubError, GitHubTransportError, identity, merged_revision

BRANCH = 'heads/stash-release-versions'
MARKER = 'tags/stash-release-versions-bootstrap-v1'
MIGRATION = 'stash-sequential-versions-v1'
BASELINE = '0.1.0'
FILE = 'release-versions.json'
SEED_MESSAGE = 'Stash release versions: ' + MIGRATION


def _sha(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{40}', value):
        raise ValueError('Invalid Git object identity in version state')
    return value


def _ref(api, name):
    value = api.request('GET', '/git/ref/' + name)
    if value is None:
        return None
    if not isinstance(value, dict) or not isinstance(value.get('object'), dict) or value['object'].get('type') != 'commit':
        raise ValueError('Invalid version-state reference')
    return _sha(value['object'].get('sha'))


def _empty(api):
    return dict(schema=1, migration=MIGRATION, repository=api.ledger_repository,
                baseline=BASELINE, next_patch=1, assignments={})


def _validate(api, state):
    if not isinstance(state, dict) or set(state) != set(_empty(api)):
        raise ValueError('Invalid version ledger schema')
    for key in ('schema', 'migration', 'repository', 'baseline'):
        if type(state[key]) is not type(_empty(api)[key]) or state[key] != _empty(api)[key]:
            raise ValueError('Incompatible version ledger ownership or baseline')
    assignments = state['assignments']
    if not isinstance(assignments, dict) or type(state['next_patch']) is not int or state['next_patch'] != len(assignments) + 1:
        raise ValueError('Inconsistent version ledger counter')
    patches = set()
    for source, plan in assignments.items():
        _sha(source)
        if not isinstance(plan, dict) or type(plan.get('build_number')) is not int or plan['build_number'] < 3:
            raise ValueError('Invalid recorded build number')
        version = plan.get('version')
        if not isinstance(version, str) or not re.fullmatch(r'0\.1\.[1-9][0-9]*', version):
            raise ValueError('Invalid assigned version')
        patch = int(version.rsplit('.', 1)[1])
        if patch in patches or plan != identity(version, plan['build_number'] - 2, source):
            raise ValueError('Conflicting version assignment')
        patches.add(patch)
    if patches != set(range(1, len(assignments) + 1)):
        raise ValueError('Nonsequential version ledger')
    return state


def _read(api, sha):
    commit = api.request('GET', '/git/commits/' + _sha(sha))
    if not isinstance(commit, dict) or commit.get('sha') != sha or not isinstance(commit.get('tree'), dict) or not isinstance(commit.get('parents'), list):
        raise ValueError('Missing or invalid version ledger commit')
    parents = [_sha(p.get('sha')) if isinstance(p, dict) else _sha(None) for p in commit['parents']]
    tree = api.request('GET', '/git/trees/' + _sha(commit['tree'].get('sha')))
    if not isinstance(tree, dict) or tree.get('truncated', False) or not isinstance(tree.get('tree'), list) or len(tree['tree']) != 1:
        raise ValueError('Invalid version ledger tree')
    entry = tree['tree'][0]
    if not isinstance(entry, dict) or entry.get('path') != FILE or entry.get('mode') != '100644' or entry.get('type') != 'blob':
        raise ValueError('Unexpected version ledger files')
    blob = api.request('GET', '/git/blobs/' + _sha(entry.get('sha')))
    if not isinstance(blob, dict) or blob.get('encoding') != 'base64' or not isinstance(blob.get('content'), str):
        raise ValueError('Missing or invalid version ledger blob')
    try:
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError('Duplicate ledger key')
                result[key] = value
            return result
        state = json.loads(base64.b64decode(''.join(blob['content'].split()), validate=True), object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise ValueError('Corrupt version ledger JSON') from None
    return _validate(api, state), parents, commit.get('message')


def _state(api):
    seed = _ref(api, MARKER)
    head = _ref(api, BRANCH)
    if seed is None or head is None:
        raise ValueError('Version ledger is not initialized or was deleted; explicit migration investigation required')
    current = head
    chain = []
    seen = set()
    while True:
        if current in seen: raise ValueError('Cyclic version ledger history')
        seen.add(current)
        state, parents, message = _read(api, current)
        if current == seed:
            if state != _empty(api) or parents or message != SEED_MESSAGE:
                raise ValueError('Conflicting bootstrap marker')
            break
        if len(parents) != 1: raise ValueError('Version ledger is not an owned append-only history')
        chain.append(state)
        current = parents[0]
    previous = state
    for following in reversed(chain):
        old = previous['assignments']
        new = following['assignments']
        if len(new) != len(old) + 1 or any(new.get(k) != v for k, v in old.items()):
            raise ValueError('Version assignments were changed or removed')
        previous = following
    return head, previous


def _candidate(api, state, parent=None):
    content = base64.b64encode(json.dumps(state, sort_keys=True, separators=(',', ':')).encode()).decode()
    def created(path, body):
        result = api.request('POST', path, body)
        if not isinstance(result, dict): raise ValueError('Invalid Git creation response')
        return _sha(result.get('sha'))
    blob = created('/git/blobs', dict(content=content, encoding='base64'))
    tree = created('/git/trees', dict(tree=[dict(path=FILE, mode='100644', type='blob', sha=blob)]))
    return created('/git/commits', dict(message='Reserve Stash release version' if parent else SEED_MESSAGE,
                   tree=tree, parents=[parent] if parent else [],
                   author=dict(name='Stash release allocator', email='stash-release@users.noreply.github.com', date='2026-10-27T00:00:00Z')))


def _prior_versions(api):
    refs = api.request('GET', '/git/matching-refs/tags/v0.1.')
    if not isinstance(refs, list): raise ValueError('Cannot inspect migration tags')
    for item in refs:
        if not isinstance(item, dict) or not isinstance(item.get('ref'), str): raise ValueError('Invalid migration tag response')
        if re.match(r'refs/tags/v0\.1\.[1-9][0-9]*(?:-|$)', item['ref']):
            raise ValueError('New-policy tags already exist; migration requires investigation')
    page = 1
    while True:
        releases = api.request('GET', f'/releases?per_page=100&page={page}')
        if not isinstance(releases, list): raise ValueError('Cannot inspect migration releases')
        for release in releases:
            if not isinstance(release, dict) or not isinstance(release.get('tag_name'), str): raise ValueError('Invalid migration release response')
            if re.match(r'v0\.1\.[1-9][0-9]*(?:-|$)', release['tag_name']):
                raise ValueError('New-policy releases already exist; migration requires investigation')
        if len(releases) < 100: break
        page += 1


def bootstrap(api, max_attempts=8):
    """Explicit, idempotent bootstrap for the fixed approved migration identity."""
    for _ in range(max_attempts):
        marker, head = _ref(api, MARKER), _ref(api, BRANCH)
        if marker is not None:
            _state(api)  # A deleted branch must never be recreated from its seed.
            return dict(migration=MIGRATION, baseline=BASELINE)
        if head is None:
            _prior_versions(api)
            seed = _candidate(api, _empty(api))
            name = BRANCH
        else:
            state, parents, message = _read(api, head)
            if state != _empty(api) or parents or message != SEED_MESSAGE:
                raise ValueError('Unmarked version branch is not the owned empty seed')
            _prior_versions(api)
            seed, name = head, MARKER
        try:
            api.request('POST', '/git/refs', dict(ref='refs/' + name, sha=seed))
        except GitHubError as error:
            if error.status not in (409, 422) or _ref(api, name) is None: raise
        except GitHubTransportError:
            # Creation may have committed. Reread before doing anything else.
            pass
    raise RuntimeError('Version bootstrap contention exhausted; inspect state and retry')


def reserve(api, event, commit_count, max_attempts=8):
    """Return one durable plan for a completed main merge; never initialize state."""
    source = merged_revision(event)
    if type(commit_count) is not int or commit_count < 1:
        raise ValueError('Invalid merged-source commit count')
    for _ in range(max_attempts):
        head, state = _state(api)
        if source in state['assignments']:
            plan = state['assignments'][source]
            if plan['build_number'] != commit_count + 2:
                raise ValueError('Recorded source/build identity conflict')
            return plan
        plan = identity('0.1.' + str(state['next_patch']), commit_count, source)
        state['assignments'][source] = plan
        state['next_patch'] += 1
        candidate = _candidate(api, state, head)
        try:
            api.request('PATCH', '/git/refs/' + BRANCH, dict(sha=candidate, force=False))
        except GitHubError as error:
            if error.status not in (409, 422) and error.status < 500: raise
            observed, authoritative = _state(api)
            if source in authoritative['assignments']:
                continue
            if observed == head: raise
        except GitHubTransportError:
            pass
        # Always reread, including on success: never claim an unpersisted plan.
    # A committed final attempt still deserves source-first recovery.
    _, state = _state(api)
    if source in state['assignments'] and state['assignments'][source]['build_number'] == commit_count + 2:
        return state['assignments'][source]
    raise RuntimeError('Version reservation contention exhausted; retry the same merged source')


def lookup(api, source):
    """Read an existing immutable assignment; never reserve or initialize."""
    _sha(source)
    _, state = _state(api)
    if source not in state['assignments']:
        raise ValueError('Merged source is not assigned a release version')
    return state['assignments'][source]
