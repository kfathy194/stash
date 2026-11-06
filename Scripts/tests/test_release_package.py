import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class ReleasePackageTests(unittest.TestCase):
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
            result=subprocess.run([sys.executable,str(ROOT/'Scripts/package_release.py'),'--version','0.1.0','--build-number','42','--commit','0'*40,'--output',str(root/'out')],capture_output=True,text=True,env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH']))
            self.assertIn('does not match checked-out HEAD',result.stderr)
            self.assertFalse((root/'out').exists())

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
        (cls.app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.kfathy.stash','CFBundleExecutable':'Stash','CFBundlePackageType':'APPL','CFBundleVersion':'42','CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'14.0'}))
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

    def test_readonly_build_cache_cleanup_preserves_package_result(self):
        # Xcode can mount Metal's read-only toolchain beneath the isolated home.
        # Inject EROFS at the filesystem boundary; keep signing/ZIP checks real.
        import errno
        import hashlib
        import json
        import os
        import shutil
        from unittest.mock import patch
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        real_run = self.package.run
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
                    with patch.object(sys, 'argv', argv), patch.object(self.package, 'run', build_or_run), patch.object(os, 'unlink', unlink):
                        if fail_build:
                            with self.assertRaises(subprocess.CalledProcessError) as caught:
                                self.package.main()
                            self.assertEqual(caught.exception.returncode, 65)
                            self.assertFalse(output.exists())
                        else:
                            self.package.main()
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
