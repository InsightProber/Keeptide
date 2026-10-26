#!/usr/bin/env python3

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPOSITORY_ROOT / "scripts" / "verify.sh"


class VerifyScriptTests(unittest.TestCase):
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

    def test_unit_routes_to_requested_test_class(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            developer_directory = temporary_path / "Xcode.app" / "Contents" / "Developer"
            developer_directory.mkdir(parents=True)
            capture_path = temporary_path / "arguments.txt"
            fake_bin = temporary_path / "bin"
            fake_bin.mkdir()
            fake_xcodebuild = fake_bin / "xcodebuild"
            fake_xcodebuild.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = \"-version\" ]; then\n"
                "  printf 'Xcode 26.0\\nBuild version 17A000\\n'\n"
                "  exit 0\n"
                "fi\n"
                f"printf '%s\\n' \"$@\" > {capture_path!s}\n",
                encoding="utf-8",
            )
            fake_xcodebuild.chmod(fake_xcodebuild.stat().st_mode | stat.S_IXUSR)
            environment = os.environ.copy()
            environment["DEVELOPER_DIR"] = str(developer_directory)
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"

            result = self.run_verify("unit", "AppLaunchTests", environment=environment)

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = capture_path.read_text(encoding="utf-8").splitlines()
            self.assertIn("test", arguments)
            self.assertIn("-project", arguments)
            self.assertIn("Keeptide.xcodeproj", arguments)
            self.assertIn("-scheme", arguments)
            self.assertIn("Keeptide", arguments)
            self.assertIn("-only-testing:KeeptideTests/AppLaunchTests", arguments)

    def test_ui_routes_to_ui_test_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            developer_directory = temporary_path / "Xcode.app" / "Contents" / "Developer"
            developer_directory.mkdir(parents=True)
            capture_path = temporary_path / "arguments.txt"
            fake_bin = temporary_path / "bin"
            fake_bin.mkdir()
            fake_xcodebuild = fake_bin / "xcodebuild"
            fake_xcodebuild.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = \"-version\" ]; then exit 0; fi\n"
                f"printf '%s\\n' \"$@\" > {capture_path!s}\n",
                encoding="utf-8",
            )
            fake_xcodebuild.chmod(fake_xcodebuild.stat().st_mode | stat.S_IXUSR)
            environment = os.environ.copy()
            environment["DEVELOPER_DIR"] = str(developer_directory)
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"

            result = self.run_verify("ui", "NativeShellUITests", environment=environment)

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = capture_path.read_text(encoding="utf-8").splitlines()
            self.assertIn("-only-testing:KeeptideUITests/NativeShellUITests", arguments)


if __name__ == "__main__":
    unittest.main()
