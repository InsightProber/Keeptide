"""Protect the release workflow's triggers and write-permission boundary."""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/release-dmg.yml'


class ReleaseWorkflowTests(unittest.TestCase):
    def workflow(self):
        self.assertTrue(WORKFLOW.is_file(), 'DMG workflow is missing')
        return WORKFLOW.read_text()

    def test_only_published_release_can_enter_write_job(self):
        source = self.workflow()
        self.assertRegex(source, r'(?m)^  release:\n    types: \[published\]$')
        self.assertIn('  pull_request:', source)
        self.assertIn('  workflow_dispatch:', source)
        self.assertNotIn('pull_request_target', source)
        build, publish = source.split('  publish:')
        self.assertNotIn('contents: write', build)
        self.assertIn("if: github.event_name == 'release'", publish)
        self.assertIn('needs: build', publish)
        self.assertIn('contents: write', publish)
        self.assertIn('--release-id "$RELEASE_ID"', publish)
        self.assertNotIn('--clobber', source)

    def test_package_verification_is_required_before_artifact_transfer(self):
        source = self.workflow()
        self.assertIn('python3 scripts/package_dmg.py', source)
        self.assertIn('python3 scripts/release_dmg.py prepare', source)
        self.assertIn('python3 -m unittest discover -s scripts/tests', source)
        self.assertNotIn('continue-on-error', source)
        self.assertNotIn('always()', source)
        self.assertIn('if-no-files-found: error', source)
        self.assertIn('artifact-ids: ${{ needs.build.outputs.artifact_id }}', source)
        self.assertIn('persist-credentials: false', source)
        self.assertIn('fetch-depth: 0', source)
        self.assertIn('digest-mismatch: error', source)
        self.assertIn('cancel-in-progress: false', source)

    def test_actions_are_pinned_and_untrusted_values_not_shell_interpolated(self):
        source = self.workflow()
        for action in re.findall(r'uses: (\S+)', source):
            self.assertRegex(action, r'^[\w/-]+@[0-9a-f]{40}$')
        for line in source.splitlines():
            if '${{' in line:
                self.assertNotIn('run:', line)
                self.assertNotIn('python3 ', line)
                self.assertNotIn('gh ', line)
        self.assertNotRegex(source, r'(?m)^  (push|schedule):')


if __name__ == '__main__':
    unittest.main()
