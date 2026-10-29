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

APP_SOURCES = REPOSITORY_ROOT / "Keeptide"
UNIT_TESTS = REPOSITORY_ROOT / "KeeptideTests"
UI_TESTS = REPOSITORY_ROOT / "KeeptideUITests"
ACCESSIBILITY_GATE = "Keeptide/Paste/AccessibilityGate.swift"
APP_DELEGATE = "Keeptide/App/KeeptideApp.swift"
# Reading another app's interface, or the screen, needs Accessibility or Screen Recording access; direct paste asks
# only to post events.
ACCESSIBILITY_ELEMENT_OR_SCREEN_CAPTURE = re.compile(
    r"\bAXUIElement\w*|\bAXIsProcessTrusted\w*|\bCGWindowListCreateImage\w*|\bCGDisplayCreateImage\w*"
    r"|\bCGDisplayStream\w*|\bScreenCaptureKit\b|\bSCStream\w*|\bSCShareableContent\b"
    r"|\bCG(?:Preflight|Request)ScreenCaptureAccess\b"
)
KEYBOARD_EVENT_POSTING = re.compile(r"\.post\(\s*tap:|\bCGEventPost\w*|\bpostToPid\b|\bpostToPSN\b")
KEYBOARD_EVENT_CREATION_OR_POSTING = re.compile(
    r"\bCGEvent\(\s*keyboardEventSource\b|" + KEYBOARD_EVENT_POSTING.pattern
)
APPLICATION_ACTIVATION = re.compile(
    r"\b(?:NSApp|NSApplication\.shared)\.activate|\.activate\((?:\)|options|from)|activateIgnoringOtherApps"
    r"|\.unhide\("
)
LIVE_SYSTEM = re.compile(r"\.live\b")
# Reading the keyboard's state or watching other apps' events needs Input Monitoring access.
INPUT_MONITORING = re.compile(
    r"\bCGEventSource\.keyState\b|\bCGEventSourceKeyState\b|\bCGEvent\.tapCreate\w*|\bCGEventTapCreate\w*"
    r"|\baddGlobalMonitorForEvents\b"
)


def matching_lines(pattern: re.Pattern[str], directories: tuple[Path, ...],
                   allowed: frozenset[str] = frozenset()) -> list[str]:
    """Each `path:line` under `directories`, other than the allowed files, whose Swift source matches `pattern`."""
    matches: list[str] = []
    for directory in directories:
        for source_file in sorted(directory.rglob("*.swift")):
            path = source_file.relative_to(REPOSITORY_ROOT).as_posix()
            if path in allowed:
                continue
            for number, line in enumerate(source_file.read_text(encoding="utf-8").splitlines(), start=1):
                if pattern.search(line):
                    matches.append(f"{path}:{number}")
    return matches


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
                        "pasteboard: NSPasteboard? = nil,",
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


class DirectPasteBoundaryTests(unittest.TestCase):
    def test_no_accessibility_element_or_screen_capture_apis(self) -> None:
        self.assertEqual(
            matching_lines(ACCESSIBILITY_ELEMENT_OR_SCREEN_CAPTURE, (APP_SOURCES,)),
            [],
            "Keeptide must not read other apps' interfaces or the screen",
        )

    def test_keyboard_events_are_posted_only_by_the_accessibility_gate(self) -> None:
        self.assertEqual(
            matching_lines(KEYBOARD_EVENT_CREATION_OR_POSTING, (APP_SOURCES,), frozenset({ACCESSIBILITY_GATE})),
            [],
            "Only the accessibility gate makes and posts keyboard events",
        )
        # Tests may build events, but a posted ⌘V would paste the general clipboard into the app in front.
        self.assertEqual(
            matching_lines(KEYBOARD_EVENT_POSTING, (UNIT_TESTS, UI_TESTS)),
            [],
            "Tests must never post events",
        )

    def test_quick_access_and_paste_never_activate_apps(self) -> None:
        self.assertEqual(
            matching_lines(APPLICATION_ACTIVATION, (APP_SOURCES / "QuickAccess", APP_SOURCES / "Paste")),
            [],
            "The panel and direct paste must not activate Keeptide or the app they paste into",
        )

    def test_live_direct_paste_is_wired_only_by_the_app_delegate(self) -> None:
        self.assertEqual(
            matching_lines(LIVE_SYSTEM, (APP_SOURCES, UNIT_TESTS), frozenset({ACCESSIBILITY_GATE, APP_DELEGATE})),
            [],
            "Only the app delegate may use the live direct paste system; tests use a fake or .unavailable",
        )
        # Without it nothing pastes, and no test could tell: none may use the live system.
        self.assertIsNotNone(
            re.search(r"CaptureSession\(\s*directPaste:\s*\.live\s*\)",
                      (REPOSITORY_ROOT / APP_DELEGATE).read_text(encoding="utf-8")),
            "The app delegate must give the capture session the live direct paste system",
        )

    def test_no_input_monitoring_apis(self) -> None:
        self.assertEqual(
            matching_lines(INPUT_MONITORING, (APP_SOURCES,)),
            [],
            "Keeptide must not read the keyboard's state or watch other apps' events",
        )


if __name__ == "__main__":
    unittest.main()
