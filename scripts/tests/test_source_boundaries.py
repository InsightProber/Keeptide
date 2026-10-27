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
    def test_views_do_not_access_clipboard_outside_capture_composition(self) -> None:
        violations: list[str] = []
        for directory in SHELL_DIRECTORIES:
            for source_file in sorted(directory.rglob("*.swift")):
                text = source_file.read_text(encoding="utf-8")
                if source_file == REPOSITORY_ROOT / "Keeptide/App/CaptureSession.swift":
                    # Permit only handle injection and named-board composition;
                    # this file must still delegate every body read and write.
                    permitted = {
                        "@ObservationIgnored private var pasteboard: NSPasteboard?",
                        "pasteboard: NSPasteboard? = nil) {",
                        "let board: NSPasteboard",
                        "board = NSPasteboard(name: .init(configuration.pasteboardName))",
                    }
                    text = "\n".join(line for line in text.splitlines() if line.strip() not in permitted)
                    self.assertIsNone(re.search(
                        r"\b(?:board|pasteboard)\??\.(?:pasteboardItems|data|string|readObjects|writeObjects|clearContents|setData|setString)\b", text
                    ), "CaptureSession must delegate clipboard bodies to its reader/writer")
                if FORBIDDEN_CLIPBOARD_ACCESS.search(text):
                    violations.append(str(source_file.relative_to(REPOSITORY_ROOT)))

        self.assertEqual(
            violations,
            [],
            "Views and window controllers must use CaptureSession rather than access clipboard APIs",
        )


if __name__ == "__main__":
    unittest.main()
