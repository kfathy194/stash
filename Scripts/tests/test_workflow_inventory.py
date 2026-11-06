from pathlib import Path
import tempfile
import unittest


WORKFLOWS = Path(__file__).parents[2] / '.github' / 'workflows'
RETIRED_WORKFLOWS = {
    'bootstrap-release-versions.yml',
    'development-release.yml',
    'release-verification.yml',
}
RELEASE_JOB_MARKERS = (
    'scripts/verify.sh',
    'xcodebuild',
    'swift test',
    'python3 -m unittest',
    'unittest discover',
    'pytest',
    'package_release.py',
    'release_pipeline.py reserve',
    'release_pipeline.py bootstrap-versions',
    'release_pipeline.py materialize',
    'release_pipeline.py publish',
    'release_versions.py',
    'release-output',
    'development prerelease',
    'release package verification',
    'bootstrap release version ledger',
)


class WorkflowInventoryTests(unittest.TestCase):
    def test_no_github_workflow_can_build_verify_or_package_releases(self):
        self.assertEqual([], release_workflow_files(WORKFLOWS),
                         'A release build, verification, or package workflow remains')

    def test_inventory_detects_repository_build_and_test_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflow = root / 'nested.yml'
            workflow.write_text('name: Routine checks\njobs: {verify: {run: xcodebuild test}}\n')
            self.assertEqual(['nested.yml'], release_workflow_files(root))


def release_workflow_files(workflow_root):
    workflow_root = Path(workflow_root)
    workflow_files = sorted(
        path for path in workflow_root.rglob('*')
        if path.is_file() and path.suffix.lower() in ('.yml', '.yaml'))
    offenders = []
    for path in workflow_files:
        content = ' '.join(path.read_text().lower().split())
        if path.name in RETIRED_WORKFLOWS or any(
                marker in content for marker in RELEASE_JOB_MARKERS):
            offenders.append(path.relative_to(workflow_root).as_posix())
    return offenders


if __name__ == '__main__':
    unittest.main()
