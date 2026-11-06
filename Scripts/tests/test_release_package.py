import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

def archive_package_module(root):
    import shutil
    scripts = root/'Scripts'
    scripts.mkdir(parents=True)
    for name in ('package_release.py', 'release_metadata.py'):
        shutil.copy2(ROOT/'Scripts'/name, scripts/name)
    spec = importlib.util.spec_from_file_location('archive_package_release', scripts/'package_release.py')
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(scripts))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(scripts))
    return module


def checkout_package_module(root):
    import shutil
    module = archive_package_module(root)
    (root/'Config').mkdir()
    shutil.copy2(ROOT/'Config/StashMacDevelopment.entitlements', root/'Config')
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    subprocess.run(['git', '-c', 'user.name=Fixture',
                    '-c', 'user.email=fixture@example.invalid',
                    '-c', 'core.hooksPath=/dev/null', 'commit', '--no-gpg-sign',
                    '--allow-empty', '-qm', 'package fixture'], cwd=root, check=True)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    return module, commit


class ReleasePackageTests(unittest.TestCase):
    def test_verifier_commands_have_a_bounded_timeout(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            helper = archive_package_module(Path(temp))
            with patch.object(helper.subprocess, 'run') as run:
                helper.run('/usr/bin/codesign', '--verify', '--strict', 'App')

            self.assertEqual(run.call_args.kwargs['timeout'],
                             helper.PACKAGE_VERIFY_TIMEOUT_SECONDS)
            self.assertTrue(run.call_args.kwargs['check'])

    def test_invalid_metadata_never_starts_build_or_creates_output(self):
        for args in [('0.1.0-dev.1','3','a'*40),('0.1.0','0','a'*40),('0.1.0','3','main')]:
            with tempfile.TemporaryDirectory() as temp:
                out=Path(temp)/'output'
                result=subprocess.run([sys.executable,str(ROOT/'Scripts/package_release.py'),'--version',args[0],'--build-number',args[1],'--commit',args[2],'--output',str(out)],capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(out.exists())
                self.assertIn('invalid release metadata',result.stderr)

    def test_wrong_source_commit_is_rejected_before_build(self):
        import os
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'bash').write_text('#!/bin/sh\nexit 7\n'); (root/'bash').chmod(0o755)
            package, _ = checkout_package_module(root/'source')
            result=subprocess.run([sys.executable,str(package.ROOT/'Scripts/package_release.py'),'--version','0.1.0','--build-number','42','--commit','0'*40,'--output',str(root/'out')],capture_output=True,text=True,env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH']))
            self.assertIn('does not match checked-out HEAD',result.stderr)
            self.assertFalse((root/'out').exists())

    def test_exported_source_commit_skips_git_checkout_metadata(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            package_release = archive_package_module(Path(temp))
            self.assertFalse((Path(temp)/'.git').exists())
            self._assert_exported_source_mode(package_release)

    def _assert_exported_source_mode(self, package_release):
        from unittest.mock import patch
        commit = 'a' * 40
        output = package_release.ROOT/'output'
        class BuildReached(Exception): pass
        argv = ['package_release.py', '--version', '0.1.0', '--build-number', '42',
                '--commit', commit, '--source-commit', commit, '--output', str(output)]
        with patch.object(sys, 'argv', argv), \
                patch.object(package_release, 'run', side_effect=BuildReached) as run:
            with self.assertRaises(BuildReached):
                package_release.main()

        self.assertEqual(run.call_args.args[0], 'bash')
        self.assertEqual(run.call_args.kwargs['timeout'],
                         package_release.PACKAGE_BUILD_TIMEOUT_SECONDS)

    def test_exported_source_commit_mismatch_fails_before_build(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            package_release = archive_package_module(Path(temp))
            output = Path(temp)/'output'
            argv = ['package_release.py', '--version', '0.1.0', '--build-number', '42',
                    '--commit', 'a' * 40, '--source-commit', 'b' * 40, '--output', str(output)]
            with patch.object(sys, 'argv', argv), patch.object(package_release, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'exported source snapshot'):
                    package_release.main()

            run.assert_not_called()

    def test_generation_preserves_explicit_metadata(self):
        import os
        import shutil
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'Scripts').mkdir(); (root/'Config').mkdir()
            for name in ['generate_project.py','release_metadata.py']:
                shutil.copy2(ROOT/'Scripts'/name,root/'Scripts'/name)
            shutil.copy2(ROOT/'Config/ReleaseVersion.txt',root/'Config/ReleaseVersion.txt')
            env=dict(os.environ,STASH_RELEASE_VERSION='2.3.4',STASH_BUILD_NUMBER='42')
            subprocess.run([sys.executable,str(root/'Scripts/generate_project.py')],env=env,check=True,capture_output=True)
            project=(root/'Stash.xcodeproj/project.pbxproj').read_text()
            self.assertIn('MARKETING_VERSION = "2.3.4";',project)
            self.assertIn('CURRENT_PROJECT_VERSION = "42";',project)



class ExtractedBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import plistlib
        import shutil
        sys.path.insert(0, str(ROOT/'Scripts'))
        import package_release
        cls.package = package_release
        cls.workspace = tempfile.TemporaryDirectory()
        cls.root = Path(cls.workspace.name)
        cls.app = cls.root/'Stash.app'
        for folder in ['Contents/MacOS','Contents/Helpers']:
            (cls.app/folder).mkdir(parents=True)
        source=cls.root/'main.c'; source.write_text('int main(void) { return 0; }\n')
        for arch in ['arm64','x86_64']:
            subprocess.run(['clang','-arch',arch,str(source),'-o',str(cls.root/arch)],check=True,capture_output=True)
        subprocess.run(['lipo','-create',str(cls.root/'arm64'),str(cls.root/'x86_64'),'-output',str(cls.app/'Contents/MacOS/Stash')],check=True)
        shutil.copy2(cls.app/'Contents/MacOS/Stash',cls.app/'Contents/Helpers/StashMCP')
        (cls.app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.kfathy.stash','CFBundleExecutable':'Stash','CFBundlePackageType':'APPL','CFBundleVersion':'42','CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'14.0','StashCloudKitEnabled':False,'CKSharingSupported':False}))
        subprocess.run(['codesign','--force','--sign','-',str(cls.app/'Contents/Helpers/StashMCP')],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign','-',str(cls.app)],check=True,capture_output=True)
        cls.metadata={'version':'0.1.0','build_number':42}

    @classmethod
    def tearDownClass(cls): cls.workspace.cleanup()

    def setUp(self):
        import shutil
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.copy=Path(self.temp.name)/'Stash.app'
        shutil.copytree(self.app,self.copy,symlinks=True)

    def test_signed_universal_extracted_app_passes(self):
        self.package.verify_app(self.copy,self.metadata)

    def test_packaged_fixture_launches_without_provisioning_profile(self):
        import json
        import plistlib
        import shutil
        from unittest.mock import patch
        output = Path(self.temp.name)/'output'
        package, commit = checkout_package_module(Path(self.temp.name)/'source')
        real_run = package.run
        def build_or_run(*args, **kwargs):
            if str(args[0]) != 'bash':
                return real_run(*args, **kwargs)
            app = Path(kwargs['env']['STASH_CHECK_ROOT'])/'mac/Build/Products/Release/Stash.app'
            shutil.copytree(self.app, app)
            info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
            info.update(StashCloudKitEnabled=True, CKSharingSupported=True,
                        CFBundleShortVersionString=kwargs['env']['STASH_RELEASE_VERSION'],
                        CFBundleVersion=kwargs['env']['STASH_BUILD_NUMBER'])
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        argv = ['package_release.py', '--version', '0.1.7', '--build-number', '42',
                '--commit', commit, '--output', str(output)]
        with patch.object(sys, 'argv', argv), patch.object(package, 'run', build_or_run):
            package.main()
        extracted = Path(self.temp.name)/'extracted'
        subprocess.run(['ditto', '-x', '-k', str(output/'Stash-macOS.zip'), str(extracted)], check=True)
        app = extracted/'Stash.app'
        result = subprocess.run([str(app/'Contents/MacOS/Stash')], capture_output=True)
        self.assertEqual(result.returncode, 0, 'macOS must permit this ad-hoc executable to start')
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        self.assertIs(info['StashCloudKitEnabled'], False)
        self.assertIs(info['CKSharingSupported'], False)
        receipt = json.loads((output/'metadata.json').read_text())
        self.assertEqual((info['CFBundleShortVersionString'], info['CFBundleVersion']), ('0.1.7', '42'))
        self.assertEqual((receipt['version'], receipt['build_number'], receipt['commit']), ('0.1.7', 42, commit))
        import release_pipeline
        plan = release_pipeline.identity('0.1.7', 40, commit)
        self.assertEqual(set(release_pipeline.package_assets(output, plan)), {'Stash-macOS.zip','Stash-macOS.dmg','SHA256SUMS','metadata.json'})
        self.assertTrue((output/'Stash-macOS.dmg').is_file())
        self.package.verify_dmg(output/'Stash-macOS.dmg', receipt)

    def test_dmg_validation_failure_detaches_only_its_owned_mount(self):
        import plistlib
        image=Path(self.temp.name)/'fixture.dmg'
        self.package.create_dmg(self.copy,image,self.metadata,self.package.bundle_inventory(self.copy))
        with self.assertRaisesRegex(ValueError,'CFBundleVersion'):
            self.package.verify_dmg(image,dict(self.metadata,build_number=99))
        attached=plistlib.loads(subprocess.check_output(['hdiutil','info','-plist']))
        self.assertFalse(any(isinstance(i.get('image-path'),str) and Path(i['image-path']).resolve()==image.resolve() for i in attached.get('images',[])))

    def test_restricted_icloud_claims_fail_even_with_valid_signature(self):
        import plistlib
        entitlements = Path(self.temp.name)/'restricted.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.developer.icloud-services':['CloudKit']}))
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                        '--entitlements', str(entitlements), str(self.copy)], check=True, capture_output=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(self.copy)], check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, 'restricted'):
            self.package.verify_app(self.copy, self.metadata)

    def test_readonly_build_cache_cleanup_preserves_package_result(self):
        # Xcode can mount Metal's read-only toolchain beneath the isolated home.
        # Inject EROFS at the filesystem boundary; keep signing/ZIP checks real.
        import errno
        import hashlib
        import json
        import os
        import shutil
        from unittest.mock import patch
        package, commit = checkout_package_module(Path(self.temp.name)/'source')
        real_run = package.run
        real_unlink = os.unlink
        for fail_build in (False, True):
            with self.subTest(fail_build=fail_build):
                output = Path(self.temp.name)/('failed' if fail_build else 'output')
                build_roots = []
                def build_or_run(*args, **kwargs):
                    if str(args[0]) != 'bash':
                        return real_run(*args, **kwargs)
                    build = Path(kwargs['env']['STASH_CHECK_ROOT'])
                    build_roots.append(build.parent)
                    cache = build/'home/Library/Developer/DVTDownloads/MetalToolchain/mounts/cache'
                    cache.parent.mkdir(parents=True)
                    cache.write_bytes(b'read-only mount fixture')
                    if fail_build:
                        raise subprocess.CalledProcessError(65, ['xcodebuild'])
                    shutil.copytree(self.app, build/'mac/Build/Products/Release/Stash.app')
                def unlink(path, *args, **kwargs):
                    if Path(path).name == 'cache':
                        raise OSError(errno.EROFS, 'Read-only file system', str(path))
                    return real_unlink(path, *args, **kwargs)
                argv = ['package_release.py', '--version', '0.1.0', '--build-number', '42',
                        '--commit', commit, '--output', str(output)]
                try:
                    with patch.object(sys, 'argv', argv), patch.object(package, 'run', build_or_run), patch.object(os, 'unlink', unlink):
                        if fail_build:
                            with self.assertRaises(subprocess.CalledProcessError) as caught:
                                package.main()
                            self.assertEqual(caught.exception.returncode, 65)
                            self.assertFalse(output.exists())
                        else:
                            package.main()
                            receipt = json.loads((output/'metadata.json').read_text())
                            digest = hashlib.sha256((output/'Stash-macOS.zip').read_bytes()).hexdigest()
                            self.assertEqual(receipt['sha256'], digest)
                            self.assertEqual(receipt['commit'], commit)
                            self.assertEqual(receipt['build_number'], 42)
                finally:
                    for build_root in build_roots:
                        shutil.rmtree(build_root, ignore_errors=True)

    def test_missing_helper_is_rejected(self):
        (self.copy/'Contents/Helpers/StashMCP').unlink()
        with self.assertRaises(ValueError):self.package.verify_app(self.copy,self.metadata)

    def test_single_architecture_is_rejected(self):
        import shutil
        shutil.copyfile(self.root/'arm64',self.copy/'Contents/Helpers/StashMCP')
        with self.assertRaises(ValueError):self.package.verify_app(self.copy,self.metadata)

    def test_tampered_signature_is_rejected(self):
        with (self.copy/'Contents/Helpers/StashMCP').open('ab') as f:f.write(b'tampered')
        with self.assertRaises(subprocess.CalledProcessError):self.package.verify_app(self.copy,self.metadata)

    def test_outside_symlink_is_rejected(self):
        (self.copy/'Contents/outside').symlink_to('/tmp')
        with self.assertRaises(ValueError):self.package.verify_app(self.copy,self.metadata)

    def test_wrong_build_metadata_is_rejected(self):
        with self.assertRaises(ValueError):self.package.verify_app(self.copy,dict(self.metadata,build_number=99))

if __name__=='__main__': unittest.main()
