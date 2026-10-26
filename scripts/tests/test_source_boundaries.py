#!/usr/bin/env python3

from pathlib import Path
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SHELL_DIRECTORIES = (
    REPOSITORY_ROOT / "Keeptide" / "App",
    REPOSITORY_ROOT / "Keeptide" / "QuickAccess",
    REPOSITORY_ROOT / "Keeptide" / "Library",
)
FORBIDDEN_CLIPBOARD_ACCESS = re.compile(r"\bNSPasteboard\b|\bUIPasteboard\b")


class ProductionShellBoundaryTests(unittest.TestCase):
    def test_foundation_shell_has_no_clipboard_api_access(self) -> None:
        violations: list[str] = []
        for directory in SHELL_DIRECTORIES:
            for source_file in sorted(directory.glob("*.swift")):
                if FORBIDDEN_CLIPBOARD_ACCESS.search(source_file.read_text(encoding="utf-8")):
                    violations.append(str(source_file.relative_to(REPOSITORY_ROOT)))

        self.assertEqual(
            violations,
            [],
            "PR-01 shell must not access clipboard APIs; add clipboard behavior in its owning milestone",
        )


if __name__ == "__main__":
    unittest.main()
