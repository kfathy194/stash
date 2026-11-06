"""Repository routing at the real GitHub HTTP boundary; no live requests."""
import importlib.util
import io
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'release_pipeline', Path(__file__).parents[1] / 'release_pipeline.py')
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


class RepositoryRoutingTests(unittest.TestCase):
    def test_private_visibility_uses_the_canonical_repository_endpoint(self):
        def response(request, **kwargs):
            self.assertEqual(request.get_method(), 'GET')
            if request.full_url == 'https://api.github.com/repos/owner/repo':
                return io.BytesIO(b'{"private": true}')
            raise pipeline.urllib.error.HTTPError(
                request.full_url, 404, 'Not Found', {}, io.BytesIO())

        api = pipeline.GitHub('owner/repo', 'fixture-token')
        with patch.object(pipeline.urllib.request, 'urlopen', side_effect=response):
            self.assertTrue(api.repository_is_private())

    def test_repository_root_support_does_not_allow_other_api_targets(self):
        api = pipeline.GitHub('owner/repo', 'fixture-token')
        with patch.object(pipeline.urllib.request, 'urlopen') as transport:
            for path in ('-other/releases', '?other=repository',
                         'https://example.invalid/repos/owner/repo'):
                with self.subTest(path=path):
                    with self.assertRaisesRegex(ValueError, 'Invalid API target'):
                        api.request('GET', path)
            transport.assert_not_called()
