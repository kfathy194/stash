"""Check the icon resources that Apple's compiler delivers to macOS."""
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BrandPackageTests(unittest.TestCase):
    def test_mac_icon_compiles_for_current_appearances_and_legacy_sizes(self):
        with tempfile.TemporaryDirectory(prefix='stash-icon-test-') as temp:
            output = Path(temp)
            icon = ROOT/'StashMac/AppIcon.icon'
            self.assertEqual((icon/'Assets/Stash-macOS-master.png').read_bytes(),
                             (ROOT/'Branding/Stash-macOS-master.png').read_bytes())
            sources = [ROOT/'StashMac/Assets.xcassets', icon]
            subprocess.run(['xcrun', 'actool', *map(str, sources), '--compile', temp,
                            '--platform', 'macosx', '--minimum-deployment-target', '14.0',
                            '--app-icon', 'AppIcon', '--target-device', 'mac',
                            '--output-partial-info-plist', str(output/'Info.plist')],
                           check=True, capture_output=True, timeout=120)
            info = plistlib.loads((output/'Info.plist').read_bytes())
            self.assertTrue((output/(info['CFBundleIconFile']+'.icns')).is_file())
            assets = json.loads(subprocess.check_output(
                ['/usr/bin/assetutil', '--info', str(output/'Assets.car')], timeout=120))
            appearances = {asset.get('Appearance') for asset in assets
                           if asset.get('Name') == 'AppIcon' and
                           asset.get('AssetType') == 'IconImageStack'}
            self.assertTrue({'NSAppearanceNameAqua', 'NSAppearanceNameDarkAqua',
                             'ISAppearanceTintable'} <= appearances,
                            'macOS needs modern icon renditions, not only a legacy bitmap')
            sizes = {asset.get('PixelWidth') for asset in assets
                     if asset.get('Name') == 'AppIcon' and
                     asset.get('AssetType') == 'Icon Image'}
            self.assertTrue({32, 64, 128, 256, 512, 1024} <= sizes)

        # The dedicated fallback must retain every native representation.
        data = (ROOT/'Branding/Stash.icns').read_bytes()
        self.assertEqual(data[:4], b'icns')
        self.assertEqual(struct.unpack('>I', data[4:8])[0], len(data))
        kinds = set()
        offset = 8
        while offset < len(data):
            kind, length = struct.unpack('>4sI', data[offset:offset+8])
            self.assertGreater(length, 8)
            kinds.add(kind)
            offset += length
        self.assertEqual(offset, len(data))
        self.assertTrue({b'icp4', b'icp5', b'icp6', b'ic07', b'ic08', b'ic09', b'ic10',
                         b'ic11', b'ic12', b'ic13', b'ic14'} <= kinds)
