"""Private release routing survives renames without following the reused name."""
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_pipeline


class PrivateRepositoryIdentityTests(unittest.TestCase):
    def test_resolves_private_repository_by_immutable_identity_before_and_after_rename(self):
        for name in ('kfathy194/stash', 'kfathy194/stash-app'):
            with self.subTest(name=name):
                def response(request, **_kwargs):
                    self.assertEqual(request.full_url, 'https://api.github.com/repositories/1432010029')
                    return io.BytesIO(json.dumps({
                        'id': 1432010029, 'node_id': 'R_kgDOVVq9LQ',
                        'owner': {'login': 'kfathy194'}, 'full_name': name,
                        'private': True,
                    }).encode())
                with patch.object(release_pipeline.urllib.request, 'urlopen', side_effect=response):
                    api = release_pipeline.private_stash_repository('fixture-token')
                self.assertEqual(api.base, 'https://api.github.com/repos/' + name)
                self.assertEqual(api.ledger_repository, 'kfathy194/stash')

    def test_rejects_public_or_unexpected_repository_identity(self):
        expected = {
            'id': 1432010029, 'node_id': 'R_kgDOVVq9LQ',
            'owner': {'login': 'kfathy194'}, 'full_name': 'kfathy194/stash-app',
            'private': True,
        }
        for change in ({'id': 99}, {'node_id': 'wrong'}, {'private': False},
                       {'owner': {'login': 'other'}}, {'full_name': 'other/stash-app'}):
            with self.subTest(change=change):
                with patch.object(release_pipeline.urllib.request, 'urlopen',
                                  return_value=io.BytesIO(json.dumps({**expected, **change}).encode())):
                    with self.assertRaisesRegex(ValueError, 'private release repository'):
                        release_pipeline.private_stash_repository('fixture-token')
