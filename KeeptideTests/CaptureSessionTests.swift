import AppKit
import CoreText
import ImageIO
import XCTest
@testable import Keeptide

@MainActor
final class CaptureSessionTests: XCTestCase {
    func testInitializedTestSessionBuildsSearchIndex() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)
        let service = try XCTUnwrap(session.searchService)
        let indexFile = configuration.directory.appendingPathComponent("Search/\(SQLiteSearchIndex.fileName)")

        try await SearchTestSupport.waitUntil {
            guard FileManager.default.fileExists(atPath: indexFile.path) else { return false }
            return try await lastSearchPage(service, "").indexState == .ready
        }
        await session.shutdown()

        XCTAssertNil(session.searchService)
        let reopened = try SQLiteSearchIndex(directory: configuration.directory.appendingPathComponent("Search"))
        defer { reopened.close() }
        XCTAssertEqual(try reopened.metadata()?.state, .ready)
    }

    func testSearchIndexFailureDoesNotPreventCapture() async throws {
        let configuration = try makeIsolatedSession()
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: configuration.directory.appendingPathComponent("Search"))
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)

        let page = try await lastSearchPage(try XCTUnwrap(session.searchService), "anything")

        XCTAssertTrue(session.isReady)
        XCTAssertEqual(page.indexState, .unavailable)
        XCTAssertEqual(page.results, [])
        await session.shutdown()
    }

    func testInitializedSessionProvidesPasteServicesUntilShutdown() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        let changes = CallCounter()
        session.onServicesChanged = { changes.count += 1 }
        await session.initialize(testSessionID: configuration.id)

        XCTAssertNotNil(session.pasteService)
        XCTAssertNotNil(session.previewService)
        XCTAssertNotNil(session.contentRepository)
        XCTAssertNotNil(session.usageStore)
        XCTAssertNotNil(session.derivedText)
        XCTAssertEqual(changes.count, 1)

        await session.shutdown()
        XCTAssertNil(session.pasteService)
        XCTAssertNil(session.previewService)
        XCTAssertNil(session.contentRepository)
        XCTAssertNil(session.usageStore)
        XCTAssertNil(session.derivedText)
        XCTAssertEqual(changes.count, 2)
    }

    func testTextIsRecognizedInAnImageTheSessionKept() async throws {
        let configuration = try makeIsolatedSession()
        let clipboard = SessionClipboard()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), clipboardReader: clipboard)
        await session.initialize(testSessionID: configuration.id)
        let derivedText = try XCTUnwrap(session.derivedText)
        // A screenshot drawn here, then a line of text.
        clipboard.copies = [[CapturedRepresentation(typeIdentifier: "public.png", bytes: try Self.screenshot([
            "The quarterly report is due Friday. Finance needs",
            "the numbers by noon so the board pack can go out.",
        ]))]]
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { session.recent.count == 1 }
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { session.recent.count == 2 }
        let image = try XCTUnwrap(session.recent.first { $0.kind == .image }?.history)
        let text = try XCTUnwrap(session.recent.first { $0.kind != .image }?.history)

        derivedText.extractText(from: image, keepingLineBreaks: false)
        derivedText.extractText(from: text, keepingLineBreaks: false)

        // Vision's first run in a process loads its model.
        await waitUntil("both have ended", timeout: .seconds(120)) {
            guard let recognized = derivedText.outcome(for: image, operation: .extractText),
                  derivedText.outcome(for: text, operation: .extractText) != nil else { return false }
            if case .saving = recognized { return false }
            return true
        }
        guard case .saved(let saved)? = derivedText.outcome(for: image, operation: .extractText) else {
            return XCTFail("\(String(describing: derivedText.outcome(for: image, operation: .extractText)))")
        }
        XCTAssertTrue(saved.text.contains("quarterly report"), saved.text)
        XCTAssertTrue(saved.text.contains("board pack"), saved.text)
        XCTAssertEqual(derivedText.outcome(for: text, operation: .extractText),
                       .failed(GenerationError(kind: .contentUnavailable, message: "This image couldn't be read.")),
                       "A text clip has no image to read")
        await session.shutdown()
    }

    /// A PNG of `lines` in dark grey on white, drawn with Core Text.
    private static func screenshot(_ lines: [String]) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1400, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1400, height: 700))
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 40, y: 640 - CGFloat(index) * 40)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testQuickAccessServicesReadUsesFromTheSessionsStore() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)

        // The strip's frequent wing reads the very store that the session's copies and pastes record uses in.
        let usage = try XCTUnwrap(session.quickAccessServices?.usage as? LocalUsageStore)
        XCTAssertTrue(usage === session.usageStore)

        await session.shutdown()
        XCTAssertNil(session.quickAccessServices)
    }

    #if DEBUG
    func testSyntheticSeedListsClipsNewestFirst() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true)

        XCTAssertEqual(session.recent.map(\.title), [
            "Synthetic alpha note", "echo synthetic-beta", "set -e", "合成中文剪贴板条目，用于快捷面板测试",
            "https://example.com/synthetic", "Synthetic rich text", "Copied content",
        ])
        XCTAssertEqual(session.recent.map(\.kind), [.text, .text, .text, .text, .url, .text, .image])
        await session.shutdown()
    }

    func testLibraryCopyRecordsAUseReceipt() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true)
        let ref = try XCTUnwrap(session.recent.first?.history)
        let workspace = try XCTUnwrap(session.libraryWorkspace)

        await workspace.open(ref)
        _ = await workspace.copyCurrent()

        XCTAssertEqual(workspace.actionMessage, "Copied")
        let board = NSPasteboard(name: .init(configuration.pasteboardName))
        XCTAssertEqual(board.string(forType: .string), "Synthetic alpha note")
        let usage = try XCTUnwrap(session.usageStore)
        // The receipt is stored after the copy reports success, without delaying it.
        try await SearchTestSupport.waitUntil { try await usage.summaries(for: [ref]).map(\.useCount) == [1] }
        await session.shutdown()
    }

    #endif

    func testTestSessionsPasteOnlyIntoTheSystemTestHost() async throws {
        let configuration = try makeIsolatedSession()
        let system = FakeDirectPasteSystem()
        let session = CaptureSession(directPaste: system.system)
        await session.initialize(testSessionID: configuration.id)
        let paste = try XCTUnwrap(session.pasteService)

        // TextEdit would paste from the general clipboard, not from the session's.
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.testSessionTarget))
        system.front = .testHost
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .paste(.testHost))
        await session.shutdown()
    }

    func testLibraryCopiesNeverPasteEvenWithATerminalInFront() async throws {
        let configuration = try makeIsolatedSession()
        let system = FakeDirectPasteSystem()
        system.front = .terminal
        // The terminal is in front as the library opens, and stays there.
        let session = CaptureSession(directPaste: system.system)
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true)
        let workspace = try XCTUnwrap(session.libraryWorkspace)
        // One line and a trailing newline: a terminal would take it as a command that needs no review, so a library
        // that pasted would send ⌘V here.
        let clip = try XCTUnwrap(session.recent.first { $0.title == "echo synthetic-beta" }?.history)

        await workspace.open(clip)
        _ = await workspace.copyCurrent()

        // The clip is copied as captured: it is not made a command for the terminal, which would drop its trailing
        // newline.
        XCTAssertEqual(workspace.actionMessage, "Copied")
        XCTAssertEqual(NSPasteboard(name: .init(configuration.pasteboardName)).string(forType: .string),
                       "echo synthetic-beta\n")
        XCTAssertEqual(system.sent, [])
        // The front window is never read for the library.
        XCTAssertEqual(system.probes, 0)
        await session.shutdown()
    }

    #if DEBUG
    func testManualPasteQASeedsAreHarmlessAndCoverTheChecklist() throws {
        let clips = ManualPasteQASession.clips()
        XCTAssertEqual(clips.count, 6)
        let texts = try clips.map { clip in
            String(decoding: try XCTUnwrap(clip.first { $0.0 == "public.utf8-plain-text" }).1, as: UTF8.self)
        }

        // Harmless in a terminal: the commands, the clips of ASCII plain text alone, only echo, and no clip's text
        // has anything else a shell acts on.
        let commands = texts.indices.filter { clips[$0].count == 1 && texts[$0].allSatisfy(\.isASCII) }
            .map { texts[$0] }
        XCTAssertEqual(commands.count, 3)
        for line in commands.flatMap({ $0.split(whereSeparator: \.isNewline) }) {
            XCTAssertTrue(line.drop { $0 == "\t" }.hasPrefix("echo "), String(line))
        }
        for text in texts {
            XCTAssertFalse(text.contains { ";|&$`<>()\\".contains($0) }, text)
        }

        // The checklist. The newest clip, which the panel opens on, is a single line.
        XCTAssertEqual(texts.last, commands.last)
        XCTAssertFalse(try XCTUnwrap(commands.last).contains(where: \.isNewline))
        XCTAssertTrue(commands.contains { $0.hasSuffix("\n") && !$0.dropLast().contains(where: \.isNewline) })
        XCTAssertTrue(commands.contains { $0.dropLast().contains(where: \.isNewline) && $0.contains("\t") })
        XCTAssertTrue(texts.contains { text in
            text.count >= 200 && text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        })
        XCTAssertTrue(clips.contains { $0.map { $0.0 } == ["public.rtf", "public.utf8-plain-text"] })
        let link = try XCTUnwrap(clips.first { $0.first?.0 == "public.url" })
        XCTAssertEqual(link.map { $0.0 }, ["public.url", "public.utf8-plain-text"])
        XCTAssertEqual(link.first?.1, link.last?.1)
        XCTAssertEqual(URL(string: String(decoding: link[0].1, as: UTF8.self))?.host(), "example.com")
    }

    func testManualPasteQASeedsGoIntoALibraryNewestFirst() async throws {
        let fixture = try PasteFixture(self)

        try await SyntheticClipSeeder.seed(ManualPasteQASession.clips(), into: fixture.controller)

        let recent = try await ContentRepository(controller: fixture.controller).recent(limit: 10)
            .filter { $0.history != nil }
        // The panel opens on the newest clip: the single-line command.
        XCTAssertEqual(recent.first?.title, "echo keeptide-qa-single")
        XCTAssertEqual(recent.map(\.kind), [.text, .text, .text, .text, .text, .url])
    }

    #endif

    func testChoosingALibraryOpensNothingAndATestSessionWinsOverQA() throws {
        let userLibrary = URL(fileURLWithPath: "/synthetic/Application Support/Keeptide/Library", isDirectory: true)
        var lookups = 0
        // As outside a test process, where the user's library may be chosen.
        func choose(_ testSessionID: UUID?, manualPasteQA: Bool) throws -> CaptureLibrary? {
            try CaptureLibrary.choose(testSessionID: testSessionID, manualPasteQA: manualPasteQA, isRunningTests: false,
                                      userLibrary: { lookups += 1; return userLibrary }())
        }
        let id = UUID()
        let configuration = CaptureTestConfiguration(id: id)

        // A test session wins over QA. It records, and pastes only into the system test host.
        for manualPasteQA in [false, true] {
            let library = try XCTUnwrap(choose(id, manualPasteQA: manualPasteQA))
            guard case .test(let chosen) = library else { return XCTFail("Chose \(library)") }
            XCTAssertEqual(chosen.id, id)
            XCTAssertEqual(library.directory, configuration.directory)
            XCTAssertEqual(library.preferencesSuite, configuration.preferencesSuite)
            XCTAssertEqual(library.directPasteOnlyTo, CaptureTestConfiguration.systemTestHostBundleIdentifier)
            XCTAssertTrue(library.recordsClipboard)
        }
        #if DEBUG
        // QA only with its flag: a folder and preferences of its own, no recording, and the user's library is not even
        // looked up.
        let qaLibrary = try XCTUnwrap(choose(nil, manualPasteQA: true))
        guard case .manualPasteQA(let qa) = qaLibrary else { return XCTFail("Chose \(qaLibrary)") }
        XCTAssertEqual(qaLibrary.directory, qa.directory)
        XCTAssertEqual(qaLibrary.preferencesSuite, qa.preferencesSuite)
        XCTAssertNil(qaLibrary.directPasteOnlyTo)
        XCTAssertFalse(qaLibrary.recordsClipboard)
        XCTAssertEqual(lookups, 0)
        #else
        // Release excludes manual QA, even if a caller supplies its launch flag.
        XCTAssertNil(try choose(nil, manualPasteQA: true))
        XCTAssertEqual(lookups, 0)
        #endif
        // Otherwise the user's library, with the standard defaults.
        let user = try XCTUnwrap(choose(nil, manualPasteQA: false))
        guard case .user = user else { return XCTFail("Chose \(user)") }
        XCTAssertEqual(user.directory, userLibrary)
        XCTAssertNil(user.preferencesSuite)
        XCTAssertNil(user.directPasteOnlyTo)
        XCTAssertTrue(user.recordsClipboard)
        XCTAssertEqual(lookups, 1)
    }

    func testATestProcessNeverChoosesTheUsersLibrary() throws {
        let userLibrary = URL(fileURLWithPath: "/synthetic/Application Support/Keeptide/Library", isDirectory: true)
        var lookups = 0

        // XCTest runs in this process, as in the app that hosts the unit tests: the user's library, which records the
        // general clipboard, is not chosen, nor even looked up, so nothing opens.
        XCTAssertNil(try CaptureLibrary.choose(testSessionID: nil, manualPasteQA: false,
                                               userLibrary: { lookups += 1; return userLibrary }()))
        XCTAssertNil(try CaptureLibrary.choose(testSessionID: nil, manualPasteQA: false, isRunningTests: true,
                                               userLibrary: { lookups += 1; return userLibrary }()))
        XCTAssertEqual(lookups, 0)
        // A UI test session's library, which records only the session's named clipboard, is chosen as ever.
        let id = UUID()
        let library = try XCTUnwrap(CaptureLibrary.choose(testSessionID: id, manualPasteQA: false,
                                                          isRunningTests: true, userLibrary: userLibrary))
        guard case .test(let chosen) = library else { return XCTFail("Chose \(library)") }
        XCTAssertEqual(chosen.id, id)
    }

    #if DEBUG
    func testTheQALibraryIsNeverTheUsersLibrary() throws {
        // Only the path: nothing in it is opened or read.
        let userLibrary = try CaptureLibrary.userLibraryDirectory()
        XCTAssertTrue(userLibrary.path.hasSuffix("/Application Support/Keeptide/Library"))

        let library = try XCTUnwrap(CaptureLibrary.choose(testSessionID: nil, manualPasteQA: true,
                                                          userLibrary: userLibrary))

        XCTAssertTrue(library.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(library.directory.path.hasPrefix(userLibrary.deletingLastPathComponent().path))
    }

    func testTheManualPasteQASessionSaysItKeepsNoCopies() async throws {
        let qa = ManualPasteQASession(id: UUID())
        addTeardownBlock { qa.remove() }
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let suiteName = "CaptureSessionTests.qaCapture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let clipboard = SessionClipboard()
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), pasteboard: board,
                                     clipboardReader: clipboard)
        await session.open(manualPasteQA: qa)

        // It keeps no copies, and says so wherever Keeptide says why, so that it is never taken for the user's own.
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.captureNotice, "Manual paste QA — new copies are not kept")
        // A copy made while it is open is never even read, over a few rounds of sampling: only its six clips are there.
        clipboard.changeCount += 1
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(clipboard.readsStarted, 0)
        XCTAssertEqual(session.recent.count, 6)
        await session.shutdown()
    }

    func testTheManualPasteQASessionSaysSoInTheMenuAndKeepsNoCopies() async throws {
        let qa = ManualPasteQASession(id: UUID())
        addTeardownBlock { qa.remove() }
        // Opened as the QA library directly, never chosen from launch flags, on a clipboard of the test's own: the QA
        // session the app opens uses the general one.
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let session = CaptureSession(pasteboard: board)
        await session.open(manualPasteQA: qa)
        let configuration = try makeIsolatedSession()
        let keeping = CaptureSession()
        await keeping.initialize(testSessionID: configuration.id)

        // The status menu as the app builds it, as it opens.
        let underXCTest = ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        func openedMenu(for session: CaptureSession) throws -> NSMenu {
            let bar = AppDelegate.makeMenuBarController(environment: AppEnvironment(captureSession: session),
                launchConfiguration: LaunchConfiguration(arguments: [], environment: underXCTest),
                canRequestQuit: { true })
            let menu = try XCTUnwrap(bar.menu)
            bar.menuWillOpen(menu)
            return menu
        }
        func item(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
            try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == identifier })
        }
        let qaMenu = try openedMenu(for: session)
        let keepingMenu = try openedMenu(for: keeping)

        // Only the six harmless clips, and the menu says this is the QA session, which keeps no copies.
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.recent.count, 6)
        let qaNotice = try item("CaptureStatusMenuItem", in: qaMenu)
        XCTAssertEqual(qaNotice.title, "Manual paste QA — new copies are not kept")
        XCTAssertFalse(qaNotice.isHidden)
        XCTAssertFalse(qaNotice.isEnabled)
        // A session that keeps new copies says nothing about them.
        XCTAssertTrue(try item("CaptureStatusMenuItem", in: keepingMenu).isHidden)
        // The QA session copies to the clipboard it was given, the test's own.
        let before = board.changeCount
        let newest = try XCTUnwrap(session.recent.first?.history)
        let workspace = try XCTUnwrap(session.libraryWorkspace)
        await workspace.open(newest)
        _ = await workspace.copyCurrent()
        XCTAssertGreaterThan(board.changeCount, before)
        XCTAssertNotNil(board.string(forType: .string))

        await session.shutdown()
        await keeping.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: qa.directory.path))
    }

    func testManualPasteQASessionRemovesItsLibraryAndPreferences() throws {
        let qa = ManualPasteQASession(id: UUID())
        let other = ManualPasteQASession(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: qa.preferencesSuite))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: other.preferencesSuite))
        addTeardownBlock {
            for session in [qa, other] where FileManager.default.fileExists(atPath: session.directory.path) {
                try FileManager.default.removeItem(at: session.directory)
            }
            defaults.removePersistentDomain(forName: qa.preferencesSuite)
            otherDefaults.removePersistentDomain(forName: other.preferencesSuite)
        }
        // Each session's library is a throwaway folder of its own, never the user's.
        XCTAssertTrue(qa.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNotEqual(qa.directory, other.directory)
        XCTAssertNotEqual(qa.preferencesSuite, other.preferencesSuite)
        for (session, sessionDefaults) in [(qa, defaults), (other, otherDefaults)] {
            try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
            let marker = session.directory.appendingPathComponent("marker")
            XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data("qa".utf8)))
            sessionDefaults.set(["com.example.marker"], forKey: "captureExcludedApplications")
        }

        qa.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: qa.directory.path))
        XCTAssertTrue(defaults.persistentDomain(forName: qa.preferencesSuite)?.isEmpty ?? true)
        // Another session's library and preferences stay.
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.directory.appendingPathComponent("marker").path))
        XCTAssertEqual(otherDefaults.stringArray(forKey: "captureExcludedApplications"), ["com.example.marker"])
    }

    #endif

    private func makeIsolatedSession() throws -> CaptureTestConfiguration {
        let configuration = CaptureTestConfiguration(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: configuration.directory.path) {
                try FileManager.default.removeItem(at: configuration.directory)
            }
            defaults.removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        return configuration
    }

    private func lastSearchPage(_ service: SearchService, _ query: String) async throws -> SearchPage {
        var last: SearchPage?
        for try await page in service.search(SearchRequest(query: query, generation: 1)) { last = page }
        return try XCTUnwrap(last)
    }

    func testMissingLocalStateKeepsATestSessionInRecoveryAndSaysWhy() async throws {
        let configuration = CaptureTestConfiguration(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        defaults.set(["com.example.marker"], forKey: "captureExcludedApplications")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: configuration.directory.path) {
                try FileManager.default.removeItem(at: configuration.directory)
            }
            defaults.removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }

        let store = try PersistenceController(directory: configuration.directory)
        let capture = try ContentStoreFixtures.capture([[
            ("public.utf8-plain-text", Data("content survives local loss".utf8)),
        ]])
        try await ContentStoreFixtures.insert(ContentStoreFixtures.item(capture), capture, into: store)
        try await store.close()
        try removeLocalStoreFiles(in: configuration.directory)

        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)

        XCTAssertFalse(session.isReady)
        XCTAssertEqual(session.captureNotice, "The library requires recovery before it can keep new copies.")

        await session.shutdown()
        let cleanup = CaptureSession()
        await cleanup.initialize(testSessionID: configuration.id, cleanupTestSession: true)
        XCTAssertEqual(cleanup.captureNotice, "Test session removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.directory.path))
        XCTAssertTrue(defaults.persistentDomain(forName: configuration.preferencesSuite)?.isEmpty ?? true)
    }

    func testCleanupInitializationRemovesOnlyItsSyntheticSessionAndKeepsNoCopies() async throws {
        let target = CaptureTestConfiguration(id: UUID())
        let sibling = CaptureTestConfiguration(id: UUID())
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: target.preferencesSuite))
        let siblingDefaults = try XCTUnwrap(UserDefaults(suiteName: sibling.preferencesSuite))
        targetDefaults.set(["com.example.target"], forKey: "captureExcludedApplications")
        siblingDefaults.set(["com.example.sibling"], forKey: "captureExcludedApplications")
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling.directory, withIntermediateDirectories: true)
        let targetMarker = target.directory.appendingPathComponent("target-marker")
        let siblingMarker = sibling.directory.appendingPathComponent("sibling-marker")
        XCTAssertTrue(FileManager.default.createFile(atPath: targetMarker.path, contents: Data("target".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: siblingMarker.path, contents: Data("sibling".utf8)))
        let targetBoard = NSPasteboard(name: .init(target.pasteboardName))
        let siblingBoard = NSPasteboard(name: .init(sibling.pasteboardName))
        targetBoard.clearContents()
        siblingBoard.clearContents()
        XCTAssertTrue(targetBoard.setString("target", forType: .string))
        XCTAssertTrue(siblingBoard.setString("sibling", forType: .string))
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: target.directory.path) {
                try FileManager.default.removeItem(at: target.directory)
            }
            if FileManager.default.fileExists(atPath: sibling.directory.path) {
                try FileManager.default.removeItem(at: sibling.directory)
            }
            targetDefaults.removePersistentDomain(forName: target.preferencesSuite)
            siblingDefaults.removePersistentDomain(forName: sibling.preferencesSuite)
            targetBoard.releaseGlobally()
            siblingBoard.releaseGlobally()
        }

        let cleanup = CaptureSession()
        await cleanup.initialize(testSessionID: target.id, cleanupTestSession: true)

        XCTAssertEqual(cleanup.captureNotice, "Test session removed")
        XCTAssertFalse(cleanup.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.path))
        XCTAssertTrue(targetDefaults.persistentDomain(forName: target.preferencesSuite)?.isEmpty ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingMarker.path))
        XCTAssertEqual(siblingDefaults.stringArray(forKey: "captureExcludedApplications"), ["com.example.sibling"])
        XCTAssertEqual(siblingBoard.string(forType: .string), "sibling")
    }

    func testQuickAccessIsToldNothingWhileNewCopiesAreKept() async throws {
        let configuration = try makeIsolatedSession()
        let clipboard = SessionClipboard()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), clipboardReader: clipboard)

        // Before the library opens there is nothing to say: Keeptide keeps new copies as it opens.
        XCTAssertNil(session.captureNotice)
        await session.initialize(testSessionID: configuration.id)
        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.captureNotice)
        // A new copy is kept, and there is still nothing to say.
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { session.recent.count == 1 }
        XCTAssertNil(session.captureNotice)
        await session.shutdown()
        XCTAssertNil(session.captureNotice)
    }

    func testALibraryThatCannotOpenSaysWhy() async throws {
        let configuration = try makeIsolatedSession()
        // A file where the library's folder goes: the library cannot open, nor keep new copies.
        try FileManager.default.createDirectory(at: configuration.directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: configuration.directory.path, contents: Data()))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults))
        await session.initialize(testSessionID: configuration.id)

        XCTAssertFalse(session.isReady)
        XCTAssertEqual(session.captureNotice, "The local library could not be opened.")
    }

    func testALibraryThatStopsWorkingSaysWhyUntilKeeptideReopens() async throws {
        let configuration = try makeIsolatedSession()
        let clipboard = SessionClipboard()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), clipboardReader: clipboard)
        await session.initialize(testSessionID: configuration.id)
        XCTAssertTrue(session.isReady)

        // A copy fails in a way the monitor takes for the library's: the library is unavailable until Keeptide
        // reopens, and the session says why.
        clipboard.failure = LibraryStoppedWorking()
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { !session.isReady }
        let reason = "The local library is unavailable. Reopen Keeptide to retry."
        XCTAssertEqual(session.captureNotice, reason)
        // Later copies are not even read, and the reason stays.
        clipboard.failure = nil
        clipboard.changeCount += 1
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(clipboard.readsStarted, 1)
        XCTAssertEqual(session.captureNotice, reason)
        await session.shutdown()
    }

    func testAClipboardTheSystemDeniesSaysWhyUntilANewCopyCanBeRead() async throws {
        let configuration = try makeIsolatedSession()
        let clipboard = SessionClipboard()
        clipboard.deniesAccess = true
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), clipboardReader: clipboard)
        await session.initialize(testSessionID: configuration.id)

        // A copy the system does not let Keeptide read: the session says why, and the library stays open.
        clipboard.changeCount += 1
        let reason = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        try await SearchTestSupport.waitUntil { session.captureNotice == reason }
        XCTAssertTrue(session.isReady)
        // Still denied, the next copy is tried, and the session still says why.
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { clipboard.readsStarted == 2 }
        XCTAssertEqual(session.captureNotice, reason)
        // Allowed meanwhile, the next copy is kept without anything turned back on, and there is nothing to say.
        clipboard.deniesAccess = false
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { session.recent.count == 1 }
        XCTAssertEqual(session.recent.first?.title, "Synthetic copy 3")
        XCTAssertNil(session.captureNotice)
        await session.shutdown()
    }

    func testAFullDiskSaysWhyClearsTheSearchCacheAndTriesEachNewCopy() async throws {
        let configuration = try makeIsolatedSession()
        let clipboard = SessionClipboard()
        clipboard.failure = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), clipboardReader: clipboard)
        await session.initialize(testSessionID: configuration.id)

        // A copy that finds the disk full: the session says why, and the rebuildable search cache is cleared.
        clipboard.changeCount += 1
        let reason = "Storage is full. Free some space to keep new copies."
        try await SearchTestSupport.waitUntil { session.captureNotice == reason }
        let index = configuration.directory.appendingPathComponent("Search/\(SQLiteSearchIndex.fileName)")
        try await SearchTestSupport.waitUntil { !FileManager.default.fileExists(atPath: index.path) }
        XCTAssertTrue(session.isReady)
        // The next copy is tried as it comes, and still finds the disk full.
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { clipboard.readsStarted == 2 }
        XCTAssertEqual(session.captureNotice, reason)
        // Once there is room, the next copy is kept, and there is nothing to say.
        clipboard.failure = nil
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { session.recent.count == 1 }
        XCTAssertNil(session.captureNotice)
        await session.shutdown()
    }

    func testShuttingDownWhileACopyIsReadKeepsNothingAndSaysNothing() async throws {
        let configuration = try makeIsolatedSession()
        let clipboard = SessionClipboard()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        let session = CaptureSession(preferences: CapturePreferences(defaults: defaults), clipboardReader: clipboard)
        await session.initialize(testSessionID: configuration.id)

        // Keeptide quits while a copy is still being read: the shutdown waits for the read, which keeps nothing.
        clipboard.holdsReads = true
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { clipboard.readsStarted == 1 }
        var closed = false
        let shutdown = Task { await session.shutdown(); closed = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed)
        clipboard.finishHeldReads()
        await shutdown.value
        XCTAssertNil(session.captureNotice)
        let store = try PersistenceController(directory: configuration.directory)
        let rows = try await ContentRepository(controller: store).recent(limit: 10)
        try await store.close()
        XCTAssertTrue(rows.isEmpty)
    }

    private func removeLocalStoreFiles(in directory: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent("Local.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// An error the capture monitor knows nothing of, which it takes for the library's.
private struct LibraryStoppedWorking: Error {}

/// The clipboard a session's monitor reads in place of its named pasteboard, where a copy is a change of count and
/// holds the synthetic text "Synthetic copy <count>". It can refuse every read, as the system does when it denies
/// Keeptide the clipboard, fail every read with `failure`, or hold reads until the test ends them. The panel's tests in
/// `AppLaunchTests` use it too.
@MainActor
final class SessionClipboard: SnapshotReading {
    var changeCount = 0
    var deniesAccess = false
    var failure: (any Error)?
    var holdsReads = false
    /// What the next copies hold, oldest first. Once they run out, each copy is a line of text.
    var copies: [[CapturedRepresentation]] = []
    private(set) var readsStarted = 0
    private var heldReads: [CheckedContinuation<Void, Never>] = []

    func readAsynchronously(sourceApp: String?, expectedChangeCount: Int) async throws -> CaptureSnapshotValue {
        readsStarted += 1
        if deniesAccess { throw SnapshotReaderError.permissionDenied }
        if let failure { throw failure }
        if holdsReads { await withCheckedContinuation { heldReads.append($0) } }
        let text = CapturedRepresentation(typeIdentifier: "public.utf8-plain-text",
                                          bytes: Data("Synthetic copy \(expectedChangeCount)".utf8))
        let representations = copies.isEmpty ? [text] : copies.removeFirst()
        return CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: representations)],
                                    changeCount: expectedChangeCount, sourceApp: sourceApp)
    }

    func finishHeldReads() {
        heldReads.forEach { $0.resume() }
        heldReads = []
    }
}

@MainActor
private final class CallCounter {
    var count = 0
}
