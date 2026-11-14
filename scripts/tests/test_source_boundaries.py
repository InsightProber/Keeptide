#!/usr/bin/env python3

from pathlib import Path
import plistlib
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
CLOUD_MODULE = APP_SOURCES / "CloudModels"
LINK_PREVIEW_MODULE = APP_SOURCES / "LinkPreviews"
NETWORK_MODULES = (CLOUD_MODULE, LINK_PREVIEW_MODULE)
PASTEBOARD_READER = REPOSITORY_ROOT / "KeeptidePasteboardReader"
UNIT_TESTS = REPOSITORY_ROOT / "KeeptideTests"
UI_TESTS = REPOSITORY_ROOT / "KeeptideUITests"
APP_ENTITLEMENTS = REPOSITORY_ROOT / "Config" / "Keeptide.entitlements"
PROJECT = REPOSITORY_ROOT / "Keeptide.xcodeproj" / "project.pbxproj"
APP_SOURCES_PHASE = "A07000000000000000000001"
READER_ENTITLEMENTS = REPOSITORY_ROOT / "Config" / "PasteboardReader.entitlements"
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
LIVE_WIRING = re.compile(
    r"CaptureSession\s*\(\s*preferences\s*:\s*capturePreferences\s*,"
    r"\s*directPaste\s*:\s*\.live\s*\)"
)
# Reaching the network: URL loading, the Network framework, CFNetwork's sockets and HTTP messages, looking a host up,
# and opening a socket; and loading what a page links to, as web views, link previews, AsyncImage and the HTML importer
# do. `contentsOf:` initializers also read files, so they can't be told apart here; AGENTS.md rules them out instead.
NETWORK_ACCESS = re.compile(
    r"\b(?:NS)?URLSession\w*|\b(?:NS|NSMutable)?URLRequest\b|\bNSURLConnection\b|\bimport\s+Network\b"
    r"|\bNW(?:Connection|Listener|Browser|PathMonitor|Endpoint|Parameters|ProtocolFramer)\w*"
    r"|\bCFSocket\w*|\bCFStreamCreatePairWithSocket\w*|\bCFHTTPMessage\w*|\bCFReadStreamCreateForHTTPRequest\b"
    r"|\bgetaddrinfo\b|\bgethostbyname\w*|\bCFHost\w*|\b(?:NS)?NetService\w*|\bgetStreamsToHost\b"
    r"|\bsocket\s*\(\s*(?:AF|PF)_"
    r"|\bimport\s+(?:WebKit|LinkPresentation)\b|\bWKWebView\b|\bLPMetadataProvider\b|\bAsyncImage\b"
    r"|\bresourceBytes\b|\bNSAttributedString\s*\(\s*html\b|\bDocumentType\.(?:html|webArchive)\b"
    r"|\bdocumentType\s*:\s*\.(?:html|webArchive)\b"
)
# How the link preview module may reach the network: the system's LinkPresentation and WebKit, nothing of its own.
LINK_PREVIEW_NETWORK = re.compile(r"\bimport\s+(?:WebKit|LinkPresentation)\b|\bWKWebView\b|\bLPMetadataProvider\b")
# The system's link loader named in a test, other than to ask how it reads a failure: a test that built one would load
# a real website, however it built it.
TEST_LINK_LOADER = re.compile(r"\bSystemLinkMetadataLoader\b(?!\.reason\b)")
# Writing to the log, which must never carry what the network modules send or receive.
LOGGING = re.compile(r"\b(?:print|debugPrint|dump|NSLog|os_log)\s*\(|\bLogger\s*\(|\bimport\s+(?:os|OSLog)\b")
# A model client built in a test: it must be given a stand-in for the network.
TEST_CLIENT = re.compile(r"\bModelClient\s*\(((?:[^()]|\([^()]*\))*)\)")
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
    def test_live_wiring_pattern_allows_only_the_explicit_preference_injection_shape(self) -> None:
        accepted = "CaptureSession(preferences: capturePreferences, directPaste: .live)"
        self.assertIsNotNone(LIVE_WIRING.fullmatch(accepted))
        for rejected in (
            "CaptureSession(directPaste: .live)",
            "CaptureSession(preferences: otherPreferences, directPaste: .live)",
            "CaptureSession(preferences: capturePreferences, pasteboard: board, directPaste: .live)",
        ):
            self.assertIsNone(LIVE_WIRING.fullmatch(rejected), rejected)

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
            "The app delegate must use .live once, in the explicit capturePreferences CaptureSession wiring",
        )

    def test_no_input_monitoring_apis(self) -> None:
        self.assertEqual(
            matching_lines(INPUT_MONITORING, (APP_SOURCES,)),
            [],
            "Keeptide must not read the keyboard's state or watch other apps' events",
        )


class NetworkBoundaryTests(unittest.TestCase):
    def test_the_network_pattern_finds_each_way_to_reach_the_network(self) -> None:
        for code in ("URLSession.shared", "URLSessionConfiguration.ephemeral", "let request = URLRequest(url: url)",
                     "NSMutableURLRequest(url: url)", "NSURLConnection", "import Network", "NWConnection(host: h",
                     "NWPathMonitor()", "CFSocketCreate(nil", "CFStreamCreatePairWithSocketToHost(nil",
                     "CFHTTPMessageCreateRequest(nil", "getaddrinfo(name",
                     # Web content and link previews load what pages link to, and so does the HTML importer.
                     "import WebKit", "WKWebView(frame: .zero)", "import LinkPresentation", "LPMetadataProvider()",
                     "AsyncImage(url: url)", "for try await byte in url.resourceBytes",
                     "NSAttributedString(html: data, documentAttributes: nil)",
                     "[.documentType: NSAttributedString.DocumentType.html]", "options: [.documentType: .html]",
                     ".documentType: .webArchive",
                     # Finding a host, or opening a socket, without URL loading.
                     "Stream.getStreamsToHost(withName: h", "CFHostCreateWithName(nil", "NetService(domain: d",
                     "NSNetService", "gethostbyname(name", "socket(AF_INET, SOCK_STREAM, 0)"):
            self.assertIsNotNone(NETWORK_ACCESS.search(code), code)
        for code in ("connect()", "requestedURL", "let urlRequestCount = 0", "import NetworkExtras",
                     "[.documentType: NSAttributedString.DocumentType.rtf]", "socketCount"):
            self.assertIsNone(NETWORK_ACCESS.search(code), code)

    def test_only_the_cloud_and_link_preview_modules_reach_the_network(self) -> None:
        for module in NETWORK_MODULES:
            self.assertTrue(any(module.rglob("*.swift")), f"{module} has no sources")
        module_sources = frozenset(
            path.relative_to(REPOSITORY_ROOT).as_posix() for module in NETWORK_MODULES for path in module.rglob("*.swift")
        )
        self.assertEqual(
            matching_lines(NETWORK_ACCESS, (APP_SOURCES,), module_sources),
            [],
            "Only Keeptide/CloudModels/ and Keeptide/LinkPreviews/ may reach the network",
        )
        # The reader inherits Keeptide's sandbox, outgoing connections included; its code never uses them.
        self.assertEqual(
            matching_lines(NETWORK_ACCESS, (PASTEBOARD_READER,)),
            [],
            "The pasteboard reader never reaches the network",
        )

    def test_link_previews_reach_the_network_only_through_the_system(self) -> None:
        # Pages are loaded through LinkPresentation and WebKit alone, never through URL loading or sockets of the
        # module's own.
        offenders: list[str] = []
        for source_file in sorted(LINK_PREVIEW_MODULE.rglob("*.swift")):
            code = code_only(source_file.read_text(encoding="utf-8"))
            for match in NETWORK_ACCESS.finditer(code):
                if not LINK_PREVIEW_NETWORK.fullmatch(match.group(0)):
                    line = code.count("\n", 0, match.start()) + 1
                    offenders.append(f"{source_file.relative_to(REPOSITORY_ROOT).as_posix()}:{line} {match.group(0)}")
        self.assertEqual(offenders, [], "Keeptide/LinkPreviews/ loads pages only through LinkPresentation and WebKit")

    def test_the_network_modules_reach_nothing_but_the_network_and_log_nothing(self) -> None:
        for module in NETWORK_MODULES:
            for pattern, why in (
                (FORBIDDEN_CLIPBOARD_ACCESS, "reads or writes the clipboard"),
                (KEYBOARD_EVENT_CREATION_OR_POSTING, "makes or posts keyboard events"),
                (APPLICATION_ACTIVATION, "activates an app"),
                (LOGGING, "writes to the log"),
            ):
                self.assertEqual(matching_lines(pattern, (module,)), [], f"Keeptide/{module.name}/ {why}")

    def test_the_network_modules_are_compiled_into_the_app_alone(self) -> None:
        # The reader may compile shared sources; never a network module's.
        project = PROJECT.read_text(encoding="utf-8")
        phases = dict(re.findall(
            r"(\w{24}) /\* Sources \*/ = \{isa = PBXSourcesBuildPhase;[^\n]*?files = \(([^)]*)\)", project
        ))
        self.assertIn(APP_SOURCES_PHASE, phases)
        compiled = {phase: set(re.findall(r"/\* (\S+) in Sources \*/", files)) for phase, files in phases.items()}
        for module in NETWORK_MODULES:
            module_files = {path.name for path in module.rglob("*.swift")}
            self.assertTrue(module_files <= compiled[APP_SOURCES_PHASE], f"The app compiles Keeptide/{module.name}/")
            for phase, names in compiled.items():
                if phase != APP_SOURCES_PHASE:
                    self.assertEqual(names & module_files, set(), f"Sources phase {phase} compiles Keeptide/{module.name}/")

    def test_tests_build_a_model_client_only_with_a_stand_in_for_the_network(self) -> None:
        # The test host may connect out; a test that reached a provider would make a real, billed request.
        for pattern_case in ("ModelClient(protocolClasses: [StubService.self])",
                             "ModelClient(hosts: Set([\"h\"]), protocolClasses: [StubService.self])"):
            self.assertIn("protocolClasses:", TEST_CLIENT.search(pattern_case).group(1), pattern_case)
        clients: list[str] = []
        for directory in (UNIT_TESTS, UI_TESTS):
            for source_file in sorted(directory.rglob("*.swift")):
                code = code_only(source_file.read_text(encoding="utf-8"))
                for match in TEST_CLIENT.finditer(code):
                    if "protocolClasses:" not in match.group(1):
                        line = code.count("\n", 0, match.start()) + 1
                        clients.append(f"{source_file.relative_to(REPOSITORY_ROOT).as_posix()}:{line}")
        self.assertEqual(clients, [], "Tests must give each ModelClient a stand-in for the network")

    def test_tests_never_build_the_system_link_loader(self) -> None:
        # The test host may connect out; a test that built the system's loader would load a real website.
        for code in ("SystemLinkMetadataLoader()", "SystemLinkMetadataLoader (timeout: 1)", "SystemLinkMetadataLoader.init()",
                     "let loader: SystemLinkMetadataLoader = .init()", "[SystemLinkMetadataLoader]()"):
            self.assertIsNotNone(TEST_LINK_LOADER.search(code), code)
        for code in ("SystemLinkMetadataLoader.reason(for: error)", "SystemLinkMetadataLoaderTests"):
            self.assertIsNone(TEST_LINK_LOADER.search(code), code)
        builds: list[str] = []
        for directory in (UNIT_TESTS, UI_TESTS):
            for source_file in sorted(directory.rglob("*.swift")):
                code = code_only(source_file.read_text(encoding="utf-8"))
                for match in TEST_LINK_LOADER.finditer(code):
                    line = code.count("\n", 0, match.start()) + 1
                    builds.append(f"{source_file.relative_to(REPOSITORY_ROOT).as_posix()}:{line}")
        self.assertEqual(builds, [], "Tests must never build the system's link loader")


class EntitlementTests(unittest.TestCase):
    def test_keeptide_may_connect_out_and_do_nothing_more(self) -> None:
        with APP_ENTITLEMENTS.open("rb") as file:
            self.assertEqual(plistlib.load(file), {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.files.user-selected.read-write": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                # Outgoing connections only, for the cloud and link preview modules; nothing listens.
                "com.apple.security.network.client": True,
            })

    def test_the_pasteboard_reader_only_inherits_keeptides_sandbox(self) -> None:
        with READER_ENTITLEMENTS.open("rb") as file:
            self.assertEqual(plistlib.load(file), {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.inherit": True,
            })


if __name__ == "__main__":
    unittest.main()
