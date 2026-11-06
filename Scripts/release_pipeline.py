#!/usr/bin/env python3
"""Main-merge release planning and publication using the GitHub REST boundary."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


def merged_revision(event):
    pr = event.get('pull_request', {})
    sha = pr.get('merge_commit_sha', '')
    if event.get('action') != 'closed' or pr.get('merged') is not True or pr.get('base', {}).get('ref') != 'main' or not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('Expected a completed PR merge into main')
    return sha


def identity(version, commit_count, sha):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or commit_count < 1 or not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('Invalid release identity')
    number = commit_count + 2
    return dict(version=version, build_number=number, commit=sha, tag=f'v{version}-dev.{number}')


class GitHubError(RuntimeError):
    def __init__(self, method, status):
        self.status = status
        super().__init__(f'GitHub {method} failed ({status}); release not completed')


class GitHubTransportError(RuntimeError):
    pass


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
            raise ValueError('Invalid repository')
        self.base = 'https://api.github.com/repos/' + repository
        self.token = token

    def request(self, method, path, data=None, raw=False):
        url = self.base + path
        if not url.startswith((self.base + '/', 'https://uploads.github.com/repos/')):
            raise ValueError('Invalid API target')
        content = data if raw else (json.dumps(data).encode() if data is not None else None)
        req = urllib.request.Request(url, content, method=method, headers={
            'Authorization': 'Bearer ' + self.token, 'Accept':'application/vnd.github+json',
            'X-GitHub-Api-Version':'2022-11-28', 'Content-Type':'application/octet-stream' if raw else 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            error.close()
            if error.code == 404 and method == 'GET': return None
            raise GitHubError(method, error.code) from None
        except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError):
            raise GitHubTransportError('GitHub connection failed; reread durable state before retry') from None

    def release(self, tag):
        # Tag lookup only promises published releases. Interrupted drafts must
        # be discovered through the authenticated, paginated release listing.
        published = self.request('GET', '/releases/tags/' + urllib.parse.quote(tag, safe=''))
        if published is not None:
            return published
        matches = []
        page = 1
        while True:
            releases = self.request('GET', f'/releases?per_page=100&page={page}')
            if not isinstance(releases, list):
                raise ValueError('Cannot inspect staged releases')
            matches.extend(item for item in releases if item.get('tag_name') == tag)
            if len(releases) < 100:
                break
            page += 1
        if len(matches) > 1:
            raise ValueError('Multiple staged releases have the same tag')
        return matches[0] if matches else None

    def release_by_id(self, release_id):
        release = self.request('GET', f'/releases/{release_id}')
        if release is None:
            raise ValueError('Staged release disappeared')
        return release
    def create(self, plan, notes):
        return self.request('POST', '/releases', dict(tag_name=plan['tag'], target_commitish=plan['commit'], name=plan['tag'], body=notes, draft=True, prerelease=True))
    def upload(self, release, name, data):
        # The repository-scoped upload endpoint does not require following an untrusted URL.
        path=f'/releases/{release["id"]}/assets?name=' + urllib.parse.quote(name, safe='')
        old=self.base; self.base=old.replace('api.github.com','uploads.github.com')
        try: return self.request('POST', path, data, raw=True)
        finally: self.base=old
    def notes(self, release, body):
        # Draft updates can replace an omitted, not-yet-created tag with an
        # untagged placeholder. Preserve source identity on every update.
        return self.request('PATCH', f'/releases/{release["id"]}',
                            {'body':body, 'tag_name':release['tag_name'],
                             'target_commitish':release['target_commitish'],
                             'draft':True, 'prerelease':True})
    def delete(self, asset):
        return self.request('DELETE', f'/releases/assets/{asset["id"]}')
    def tag_commit(self, tag):
        ref=self.request('GET', '/git/ref/tags/' + urllib.parse.quote(tag, safe=''))
        if ref is None: return None
        obj=ref['object']
        while obj['type'] == 'tag': obj=self.request('GET', '/git/tags/'+obj['sha'])['object']
        return obj['sha'] if obj['type'] == 'commit' else None
    def publish(self, release):
        return self.request('PATCH', f'/releases/{release["id"]}',
                            {'tag_name':release['tag_name'],
                             'target_commitish':release['target_commitish'],
                             'draft':False, 'prerelease':True, 'make_latest':'false'})


def validate_plan(plan, source, commit_count):
    if not isinstance(plan, dict) or type(plan.get('build_number')) is not int or not isinstance(plan.get('version'), str):
        raise ValueError('Invalid release plan')
    if plan != identity(plan['version'], commit_count, source):
        raise ValueError('Release plan/source identity mismatch')
    return plan


def package_assets(directory, plan):
    directory=Path(directory)
    archive=(directory/'Stash-macOS.zip').read_bytes()
    digest=hashlib.sha256(archive).hexdigest()
    checksums=(directory/'SHA256SUMS').read_bytes()
    if checksums.decode().strip() != digest + '  Stash-macOS.zip':
        raise ValueError('ZIP checksum mismatch')
    metadata=(directory/'metadata.json').read_bytes()
    receipt=json.loads(metadata)
    for key in ('version','build_number','commit'):
        if receipt.get(key) != plan[key]: raise ValueError('Package identity mismatch')
    if receipt.get('sha256') != digest or receipt.get('signing') != 'ad-hoc' or receipt.get('notarized') is not False:
        raise ValueError('Package verification receipt mismatch')
    return {'Stash-macOS.zip':archive, 'SHA256SUMS':checksums, 'metadata.json':metadata}


def publish(api, plan, assets, notes):
    tag_commit=api.tag_commit(plan['tag'])
    if tag_commit is not None and tag_commit != plan['commit']:
        raise ValueError('Existing tag points at another commit')
    expected={name: ['sha256:'+hashlib.sha256(data).hexdigest(),len(data)] for name,data in assets.items()}
    release=api.release(plan['tag'])
    if release is None:
        manifest=json.dumps({'plan':plan,'assets':expected}, sort_keys=True)
        release=api.create(plan,notes+'\n\n<!-- stash-release:'+manifest+' -->')
    if release.get('target_commitish') != plan['commit'] or release.get('tag_name') != plan['tag']:
        raise ValueError('Release source identity conflict')
    if not release['draft']:
        marker=re.search(r'<!-- stash-release:(.*?) -->',release.get('body',''))
        if not marker: raise ValueError('Published verification manifest missing')
        saved=json.loads(marker.group(1))
        if saved['plan'] != plan: raise ValueError('Published manifest identity conflict')
        expected=saved['assets']
        if set(expected) != {'Stash-macOS.zip','SHA256SUMS','metadata.json'}:
            raise ValueError('Published manifest asset set incomplete')
        for value in expected.values():
            if not isinstance(value,list) or len(value)!=2 or not isinstance(value[0],str) or not re.fullmatch('sha256:[0-9a-f]{64}',value[0]) or not isinstance(value[1],int) or value[1] < 1:
                raise ValueError('Published manifest asset receipt invalid')
    existing={asset['name']:asset for asset in release.get('assets',[])}
    if len(existing) != len(release.get('assets',[])) or set(existing)-set(expected):
        raise ValueError('Unexpected or duplicate release assets')
    published=not release['draft']
    if published and tag_commit != plan['commit']:
        raise ValueError('Published tag is missing or changed')
    for name,(digest,size) in expected.items():
        asset=existing.get(name)
        matches=asset and asset.get('digest')==digest and asset.get('size')==size
        if published:
            if not matches: raise ValueError('Published asset conflict; replacement forbidden')
        elif not matches:
            if asset: api.delete(asset)
            api.upload(release,name,assets[name])
    if published: return release
    # A rebuilt draft needs a matching durable manifest before becoming immutable.
    manifest=json.dumps({'plan':plan,'assets':expected},sort_keys=True)
    api.notes(release,notes+'\n\n<!-- stash-release:'+manifest+' -->')
    # Re-read after all uploads rather than trusting local upload progress.
    staged=api.release_by_id(release['id'])
    if not staged['draft'] or staged.get('tag_name') != plan['tag'] or staged.get('target_commitish') != plan['commit']:
        raise ValueError('Staged release identity or state changed')
    actual={a['name']:[a.get('digest'),a.get('size')] for a in staged.get('assets',[])}
    if actual != expected: raise ValueError('Incomplete staged asset set')
    return api.publish(staged)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action', choices=['plan','publish','reserve','bootstrap-versions','materialize'])
    parser.add_argument('--directory', default='release-output')
    for field in ('version', 'build-number', 'commit', 'tag'):
        parser.add_argument('--' + field)
    args=parser.parse_args()
    if args.action == 'bootstrap-versions':
        from release_versions import bootstrap
        print(json.dumps(bootstrap(GitHub(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN']))))
        return
    event=json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    sha=merged_revision(event)
    head=subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip()
    if head != sha: raise ValueError('Checkout is not the merged revision')
    count=int(subprocess.check_output(['git','rev-list','--count',sha], text=True))
    if args.action == 'materialize':
        if not isinstance(args.build_number, str) or not re.fullmatch('[1-9][0-9]*', args.build_number):
            raise ValueError('Invalid forwarded build number')
        plan = dict(version=args.version, build_number=int(args.build_number), commit=args.commit, tag=args.tag)
        validate_plan(plan, sha, count)
        Path('release-plan.json').write_text(json.dumps(plan))
        return
    if args.action in ('plan', 'reserve'):
        version=Path('Config/ReleaseVersion.txt').read_text().strip() if args.action == 'plan' else None
        if args.action == 'reserve':
            from release_versions import reserve
            plan=reserve(GitHub(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN']),event,count)
        else:
            plan=identity(version,count,sha)
        Path('release-plan.json').write_text(json.dumps(plan))
        with open(os.environ['GITHUB_OUTPUT'],'a') as output:
            for key,value in plan.items(): output.write(f'{key}={value}\n')
    else:
        plan=json.loads(Path('release-plan.json').read_text())
        validate_plan(plan, sha, count)
        assets=package_assets(args.directory,plan)
        notes=f"PR #{event['pull_request']['number']}\nCommit: {sha}\nVersion: {plan['version']} (build {plan['build_number']})\n\nCore tests, universal macOS Release and iOS simulator builds passed.\nDevelopment prerelease: ad-hoc signed and unnotarized; iCloud sync/sharing unavailable. Device, cloud, permission, MCP and commerce acceptance remain open."
        api = GitHub(os.environ['GITHUB_REPOSITORY'],os.environ['GH_TOKEN'])
        from release_versions import lookup
        if lookup(api, sha) != plan:
            raise ValueError('Release plan differs from original ledger assignment')
        publish(api,plan,assets,notes)

if __name__ == '__main__':
    # The allocator imports this public adapter; retain the CLI's exception types.
    import sys
    sys.modules['release_pipeline'] = sys.modules[__name__]
    main()
