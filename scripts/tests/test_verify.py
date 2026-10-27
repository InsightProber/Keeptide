#!/usr/bin/env python3

import os
import json
from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPOSITORY_ROOT / "scripts" / "verify.sh"


class VerifyScriptTests(unittest.TestCase):
    @contextmanager
    def fake_xcode(self, summary=None, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            developer = root / "Xcode.app/Contents/Developer"
            developer.mkdir(parents=True)
            capture = root / "arguments.txt"
            binaries = root / "bin"
            binaries.mkdir()
            build = binaries / "xcodebuild"
            build.write_text(
                '#!/bin/sh\nif [ "$1" = "-version" ]; then exit 0; fi\n'
                'printf "%s\\n" "$@" > "$CAPTURE_PATH"\n'
                f'exit {exit_code}\n', encoding="utf-8")
            result = binaries / "xcrun"
            result.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_SUMMARY"\n', encoding="utf-8")
            for executable in (build, result):
                executable.chmod(0o755)
            env = os.environ.copy()
            env.update(DEVELOPER_DIR=str(developer), PATH=f"{binaries}:{env['PATH']}",
                       CAPTURE_PATH=str(capture), TEST_SUMMARY=json.dumps(summary or {
                           "totalTestCount": 3, "passedTests": 3, "failedTests": 0,
                           "skippedTests": 0, "result": "Passed"}))
            yield env, capture

    def test_zero_selected_tests_fail_even_when_xcodebuild_succeeds(self):
        with self.fake_xcode({"totalTestCount": 0, "passedTests": 0, "failedTests": 0,
                              "skippedTests": 0, "result": "Passed"}) as (env, _):
            result = self.run_verify("unit", "TypoTests", environment=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No tests executed", result.stderr)

    def test_all_skipped_tests_do_not_pass_verification(self):
        with self.fake_xcode({"totalTestCount": 2, "passedTests": 0, "failedTests": 0,
                              "skippedTests": 2, "result": "Passed"}) as (env, _):
            result = self.run_verify("ui", "SkippedTests", environment=env)
            self.assertNotEqual(result.returncode, 0)

    def test_unit_without_class_runs_entire_target(self):
        with self.fake_xcode() as (env, capture):
            result = self.run_verify("unit", environment=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("-only-testing:KeeptideTests", capture.read_text().splitlines())

    def test_failed_build_is_not_masked_by_result_parsing(self):
        with self.fake_xcode(exit_code=65) as (env, _):
            self.assertEqual(self.run_verify("unit", "ExampleTests", environment=env).returncode, 65)

    def test_missing_test_count_is_not_success(self):
        with self.fake_xcode({"result": "Passed"}) as (env, _):
            self.assertNotEqual(self.run_verify("unit", "ExampleTests", environment=env).returncode, 0)

    def run_verify(self, *arguments: str, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [str(VERIFY_SCRIPT), *arguments],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        except FileNotFoundError:
            return subprocess.CompletedProcess(
                [str(VERIFY_SCRIPT), *arguments],
                returncode=127,
                stdout="",
                stderr="verify.sh is missing",
            )

    def test_missing_full_xcode_fails_with_actionable_message(self) -> None:
        environment = os.environ.copy()
        environment["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"

        result = self.run_verify("release-build", environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Full Xcode is required", result.stderr)
        self.assertIn("DEVELOPER_DIR", result.stderr)

    def test_unit_routes_to_requested_test_class(self):
        with self.fake_xcode() as (env, capture):
            result = self.run_verify("unit", "AppLaunchTests", environment=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("-only-testing:KeeptideTests/AppLaunchTests", capture.read_text().splitlines())

    def test_ui_routes_to_requested_target(self):
        with self.fake_xcode() as (env, capture):
            result = self.run_verify("ui", environment=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("-only-testing:KeeptideUITests", capture.read_text().splitlines())

    def test_warnings_build_checks_swift_warnings(self):
        with self.fake_xcode() as (env, capture):
            result = self.run_verify("warnings-build", environment=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = capture.read_text().splitlines()
            self.assertIn("build", arguments)
            self.assertIn("Debug", arguments)
            self.assertIn("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", arguments)

    def test_malformed_result_fails(self):
        with self.fake_xcode() as (env, _):
            env["TEST_SUMMARY"] = "not json"
            result = self.run_verify("unit", environment=env)
            self.assertNotEqual(result.returncode, 0)

    def test_result_tool_failure_is_not_success(self):
        with self.fake_xcode() as (env, _):
            tool = Path(env["PATH"].split(":")[0]) / "xcrun"
            tool.write_text("#!/bin/sh\nexit 72\n")
            self.assertEqual(self.run_verify("unit", environment=env).returncode, 72)


if __name__ == "__main__":
    unittest.main()
