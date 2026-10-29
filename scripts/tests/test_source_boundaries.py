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
# The patterns match across line breaks, and Swift allows white space on either side of a call's opening parenthesis.
KEYBOARD_EVENT_POSTING = re.compile(r"\.post\s*\(\s*tap\s*:|\bCGEventPost\w*|\bpostToPid\b|\bpostToPSN\b")
KEYBOARD_EVENT_CREATION_OR_POSTING = re.compile(
    r"\bCGEvent\s*\(\s*keyboardEventSource\b|" + KEYBOARD_EVENT_POSTING.pattern
)
APPLICATION_ACTIVATION = re.compile(
    r"\b(?:NSApp|NSApplication\.shared)\??\.activate\b|\.activate\s*\(\s*(?:\)|options\b|from\b)"
    r"|\bactivate\s*\(\s*ignoringOtherApps\b|\bactivateIgnoringOtherApps\b|\.unhide\s*\("
)
LIVE_SYSTEM = re.compile(r"\.live\b")
LIVE_WIRING = re.compile(r"CaptureSession\s*\(\s*directPaste\s*:\s*\.live\s*\)")
# Reading the keyboard's state or watching other apps' events needs Input Monitoring access.
INPUT_MONITORING = re.compile(
    r"\bCGEventSource\.keyState\b|\bCGEventSourceKeyState\b|\bCGEvent\.tapCreate\w*|\bCGEventTapCreate\w*"
    r"|\baddGlobalMonitorForEvents\b|\bCG(?:Request|Preflight)ListenEventAccess\b|\bIOHID(?:Request|Check)Access\b"
)


def matching_lines(pattern: re.Pattern[str], directories: tuple[Path, ...],
                   allowed: frozenset[str] = frozenset()) -> list[str]:
    """Each `path:line` under `directories`, other than the allowed files, where `pattern` matches the Swift source.
    A match may run over several lines; it is reported at the line where it starts. Every directory must exist, so
    that a moved or renamed folder fails instead of passing with nothing to check."""
    matches: list[str] = []
    for directory in directories:
        if not directory.is_dir():
            raise AssertionError(f"{directory} is not a directory")
        for source_file in sorted(directory.rglob("*.swift")):
            path = source_file.relative_to(REPOSITORY_ROOT).as_posix()
            if path in allowed:
                continue
            text = source_file.read_text(encoding="utf-8")
            for match in pattern.finditer(text):
                matches.append(f"{path}:{text.count(chr(10), 0, match.start()) + 1}")
    return matches


def code_only(source: str) -> str:
    """`source` with its comments and the contents of its string literals blanked out, keeping line breaks. Block
    comments may nest, as in Swift, and a `//` inside a string is not a comment."""
    def blank(text: str) -> str:
        return "".join(character if character == "\n" else " " for character in text)

    kept: list[str] = []
    depth = 0  # nested block comments
    in_string = False
    index = 0
    while index < len(source):
        character, pair = source[index], source[index:index + 2]
        if depth and pair in ("/*", "*/"):
            depth += 1 if pair == "/*" else -1
            kept.append("  ")
            index += 2
        elif depth:
            kept.append(blank(character))
            index += 1
        elif in_string and character == "\\":
            kept.append(blank(pair))
            index += 2
        elif in_string:
            in_string = character != '"'
            kept.append(character if character == '"' else blank(character))
            index += 1
        elif pair == "//":
            end = source.find("\n", index)
            end = len(source) if end == -1 else end
            kept.append(blank(source[index:end]))
            index = end
        elif pair == "/*":
            depth = 1
            kept.append("  ")
            index += 2
        else:
            in_string = character == '"'
            kept.append(character)
            index += 1
    return "".join(kept)


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
        # The app delegate's one `.live`, outside comments and strings, gives the capture session the live system.
        # Without it nothing pastes, and no test could tell: none may use the live system.
        code = code_only((REPOSITORY_ROOT / APP_DELEGATE).read_text(encoding="utf-8"))
        self.assertEqual(
            (len(LIVE_SYSTEM.findall(code)), len(LIVE_WIRING.findall(code))),
            (1, 1),
            "The app delegate must use .live once, in CaptureSession(directPaste: .live)",
        )

    def test_no_input_monitoring_apis(self) -> None:
        self.assertEqual(
            matching_lines(INPUT_MONITORING, (APP_SOURCES,)),
            [],
            "Keeptide must not read the keyboard's state or watch other apps' events",
        )


if __name__ == "__main__":
    unittest.main()
