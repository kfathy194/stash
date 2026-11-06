#!/usr/bin/env python3
"""Build, sign, package and verify an unnotarized development release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from release_metadata import validate

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_VERIFY_TIMEOUT_SECONDS = 2 * 60
PACKAGE_BUILD_TIMEOUT_SECONDS = 30 * 60


def run(*args, **kwargs):
    kwargs.setdefault('timeout', PACKAGE_VERIFY_TIMEOUT_SECONDS)
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def verify_app(app, metadata):
    """Validate the extracted public deliverable, including native helper."""
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    expected = {'CFBundleIdentifier':'com.kfathy.stash',
                'CFBundleShortVersionString':metadata['version'],
                'CFBundleVersion':str(metadata['build_number']),
                'LSMinimumSystemVersion':'14.0',
                'StashCloudKitEnabled':False, 'CKSharingSupported':False}
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
        raw = run('codesign', '--display', '--entitlements', '-', '--xml', executable,
                  capture_output=True).stdout
        entitlements = plistlib.loads(raw) if raw.strip() else {}
        if any(key.startswith('com.apple.developer.') or
               key in {'keychain-access-groups', 'com.apple.application-identifier'}
               for key in entitlements):
            raise ValueError('ad-hoc development app claims restricted capabilities')
    run('codesign', '--verify', '--deep', '--strict', app)


def bundle_inventory(app):
    """Compare both packaged bundles byte-for-byte, including executable modes."""
    result = {}
    for item in app.rglob('*'):
        key = str(item.relative_to(app))
        if item.is_symlink(): result[key] = ('link', os.readlink(item))
        elif item.is_file(): result[key] = ('file', item.stat().st_mode & 0o777, hashlib.sha256(item.read_bytes()).hexdigest())
    return result


def verify_dmg(image, metadata, expected_inventory=None):
    """Verify only an image mounted at this operation's fresh private mountpoint."""
    run('hdiutil', 'verify', image)
    details = plistlib.loads(run('hdiutil', 'imageinfo', '-plist', image, capture_output=True).stdout)
    if details.get('Format') != 'UDZO':
        raise ValueError('Disk image must be compressed read-only UDZO')
    temp = tempfile.mkdtemp(prefix='stash-dmg-mount-')
    # macOS exposes /var as /private/var; use the canonical owned mount path.
    mount = Path(temp).resolve()/'volume'
    try:
        mount.mkdir()
        attached = False
        try:
            raw = run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                      '-mountpoint', mount, '-plist', image, capture_output=True).stdout
            attached = True
            entities = plistlib.loads(raw).get('system-entities', [])
            reported = [e.get('mount-point') for e in entities if isinstance(e.get('mount-point'), str)]
            if not os.path.ismount(mount) or not any(Path(point).is_absolute() and Path(point).samefile(mount) for point in reported):
                raise ValueError(f'Disk image mounted at an unexpected location: expected {mount}, reported {reported}')
            shortcut = mount/'Applications'
            if not shortcut.is_symlink() or os.readlink(shortcut) != '/Applications':
                raise ValueError('Disk image Applications shortcut is invalid')
            verify_app(mount/'Stash.app', metadata)
            if expected_inventory is not None and bundle_inventory(mount/'Stash.app') != expected_inventory:
                raise ValueError('DMG and ZIP app contents differ')
        finally:
            # Even a malformed/failed attach response can leave our private mount active.
            # Never enumerate/detach unrelated devices or volumes.
            if attached or os.path.ismount(mount):
                run('hdiutil', 'detach', mount)

    finally:
        # Never recursively clean a mount when detach failed; preserve its private path.
        if not os.path.ismount(mount): shutil.rmtree(temp)


def create_dmg(app, image, metadata, expected_inventory):
    with tempfile.TemporaryDirectory(prefix='stash-dmg-stage-') as temp:
        stage = Path(temp)
        run('ditto', app, stage/'Stash.app')
        (stage/'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-srcfolder', stage, '-volname', 'Stash',
            '-fs', 'HFS+', '-format', 'UDZO', image)
    verify_dmg(image, metadata, expected_inventory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--source-commit')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    metadata = validate(args.version, args.build_number, args.commit)
    if args.source_commit is None:
        head = run('git', 'rev-parse', 'HEAD', cwd=ROOT, capture_output=True, text=True).stdout.strip()
        if metadata['commit'] != head:
            raise ValueError('release commit does not match checked-out HEAD')
    else:
        if (ROOT / '.git').exists():
            raise ValueError('exported source mode requires a snapshot without Git metadata')
        if args.source_commit != metadata['commit']:
            raise ValueError('release commit does not match exported source snapshot')
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
        run('bash', ROOT/'Scripts/verify.sh', cwd=ROOT, env=env,
            timeout=PACKAGE_BUILD_TIMEOUT_SECONDS)
        app = build/'verify/mac/Build/Products/Release/Stash.app'
        info_path = app/'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info.update(StashCloudKitEnabled=False, CKSharingSupported=False)
        info_path.write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', '-', '--options', 'runtime', app/'Contents/Helpers/StashMCP')
        run('codesign', '--force', '--sign', '-', '--options', 'runtime',
            '--entitlements', ROOT/'Config/StashMacDevelopment.entitlements', app)
        verify_app(app, metadata)
        archive = build/'Stash-macOS.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
        extracted = build/'extracted'
        run('ditto', '-x', '-k', archive, extracted)
        verify_app(extracted/'Stash.app', metadata)
        image = build/'Stash-macOS.dmg'
        create_dmg(app, image, metadata, bundle_inventory(extracted/'Stash.app'))
        metadata.update(package_format=2, dmg_sha256=hashlib.sha256(image.read_bytes()).hexdigest(), sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                        signing='ad-hoc', notarized=False)
        output.mkdir(parents=True, exist_ok=True)
        # Exclusive creation preserves the original staging contract.
        for package in (archive, image):
            with (output/package.name).open('xb') as destination:
                with package.open('rb') as source:
                    shutil.copyfileobj(source, destination)
        (output/'SHA256SUMS').write_text(f"{metadata['sha256']}  Stash-macOS.zip\n{metadata['dmg_sha256']}  Stash-macOS.dmg\n")
        (output/'metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
        print(json.dumps(metadata))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        raise SystemExit(str(error))
