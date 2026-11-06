"""Checks the native paste-delivery boundary with disposable simulated OS state."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
class PasteDeliveryTests(unittest.TestCase):
    def test_superseded_clipboard_never_reaches_destination(self):
        with tempfile.TemporaryDirectory(prefix='stash-paste-check-') as directory:
            executable = Path(directory) / 'paste-checks'
            compiled = subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                                       str(ROOT / 'StashMac/PasteDelivery.swift'),
                                       str(ROOT / 'Scripts/tests/fixtures/PasteDeliveryChecks.swift'),
                                       '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
