#!/usr/bin/env python3
"""Build, sign, package and verify an unnotarized development release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from release_metadata import validate

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def verify_app(app, metadata):
    """Validate the extracted public deliverable, including native helper."""
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    expected = {'CFBundleIdentifier':'com.kfathy.stash',
                'CFBundleShortVersionString':metadata['version'],
                'CFBundleVersion':str(metadata['build_number']),
                'LSMinimumSystemVersion':'14.0'}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'packaged {key} differs from release metadata')
    for item in app.rglob('*'):
        if item.is_symlink() and not item.resolve().is_relative_to(app.resolve()):
            raise ValueError('bundle contains an outside symlink')
    for executable in [app/'Contents/MacOS/Stash', app/'Contents/Helpers/StashMCP']:
        if not os.access(executable, os.X_OK):
            raise ValueError(f'missing executable: {executable.name}')
        archs = run('lipo', '-archs', executable, capture_output=True, text=True).stdout.split()
        if set(archs) != {'arm64', 'x86_64'}:
            raise ValueError(f'{executable.name} is not universal')
    for executable in [app/'Contents/MacOS/Stash', app/'Contents/Helpers/StashMCP']:
        run('codesign', '--verify', '--strict', executable)
    run('codesign', '--verify', '--deep', '--strict', app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    metadata = validate(args.version, args.build_number, args.commit)
    head = run('git', 'rev-parse', 'HEAD', cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if metadata['commit'] != head:
        raise ValueError('release commit does not match checked-out HEAD')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError('output directory must be empty; refusing to replace existing assets')
    # Xcode may mount a read-only Metal toolchain beneath the isolated home.
    # Best-effort scratch cleanup must not mask verification failures or turn
    # an already validated package into a failure; the hosted runner is ephemeral.
    with tempfile.TemporaryDirectory(prefix='stash-release-', ignore_cleanup_errors=True) as temp:
        build = Path(temp)
        env = dict(os.environ, STASH_RELEASE_VERSION=metadata['version'],
                   STASH_BUILD_NUMBER=str(metadata['build_number']), STASH_CHECK_ROOT=str(build/'verify'))
        run('bash', ROOT/'Scripts/verify.sh', cwd=ROOT, env=env)
        app = build/'verify/mac/Build/Products/Release/Stash.app'
        run('codesign', '--force', '--sign', '-', '--options', 'runtime', app/'Contents/Helpers/StashMCP')
        run('codesign', '--force', '--sign', '-', '--options', 'runtime',
            '--entitlements', ROOT/'Config/StashMac.entitlements', app)
        verify_app(app, metadata)
        archive = build/'Stash-macOS.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
        extracted = build/'extracted'
        run('ditto', '-x', '-k', archive, extracted)
        verify_app(extracted/'Stash.app', metadata)
        metadata.update(sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                        signing='ad-hoc', notarized=False)
        output.mkdir(parents=True, exist_ok=True)
        # Exclusive creation prevents replacing previously staged/published bytes.
        with (output/archive.name).open('xb') as destination:
            with archive.open('rb') as source:
                import shutil
                shutil.copyfileobj(source, destination)
        (output/'SHA256SUMS').write_text(f"{metadata['sha256']}  {archive.name}\n")
        (output/'metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
        print(json.dumps(metadata))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        raise SystemExit(str(error))
