import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

/// Renders the strip's cards, and the whole panel, to PNG files for a person to compare with the design. It runs only
/// when `KEEPTIDE_SNAPSHOT_DIR` names a folder, which `xcodebuild` passes on from `TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR`;
/// otherwise it is skipped and writes nothing. The tests run inside the sandboxed app, which may not write to a folder
/// outside its container: the files then go to a folder of the same name in the app's temporary directory, and the
/// log says where. Each file is attached to the test's result as well.
///
/// Each card is the real `StripFrameView` in its own `NSHostingView`, laid out in a row as the strip lays them out, on
/// the band's colour and drawn at twice its size. The panel is the real `PanelController` over a temporary library,
/// laid out for a 1440 × 875 screen. It is drawn with the frequent clips turned off, as it was before them, except in
/// the frequent wing's own pictures, whose clips have uses recorded in the library's usage store. Every clip is made up
/// here. Apps that ship with macOS stand in as the clips' sources, and only their icons and names are read.
@MainActor
final class QuickAccessSnapshotTests: XCTestCase {
    private enum App {
        static let preview = "com.apple.Preview"
        static let terminal = "com.apple.Terminal"
        static let safari = "com.apple.Safari"
        static let notes = "com.apple.Notes"
        static let finder = "com.apple.finder"
        static let mail = "com.apple.mail"
    }

    /// One card: the clip, what its details hold, and whether it is the selected one.
    private struct Card {
        let row: QuickAccessRow
        let detail: ClipDetail?
        var isSelected = false
    }

    func testRenderCards() async throws {
        guard let folder = ProcessInfo.processInfo.environment["KEEPTIDE_SNAPSHOT_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR to render the cards")
        }
        let output = SnapshotFolder(requested: URL(fileURLWithPath: folder, isDirectory: true))
        let names = ApplicationNames()
        let now = Date()
        let everySize = CardSize.allCases
        let rows: [(name: String, cards: [Card], sizes: [CardSize], appearances: [Bool])] = [
            ("open", try openRow(now: now), everySize, [true, false]),
            ("search", searchRow(now: now), everySize, [true, false]),
            ("states", try statesRow(now: now), everySize, [true, false]),
            // Text at its extremes, on the smallest card and the largest, in dark mode.
            ("extremes", extremesRow(now: now), [.small, .large], [true]),
            // How often frequent clips were used, where the time goes; the small card shows what does not fit.
            ("frequent", frequentRow(now: now), [.small, .medium], [true, false]),
        ]

        for (name, cards, sizes, appearances) in rows {
            for cardSize in sizes {
                for dark in appearances {
                    let file = "cards-\(name)-\(cardSize.rawValue)-\(dark ? "dark" : "light").png"
                    let png = try await render(cards, cardSize: cardSize, dark: dark, now: now, names: names)
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = file
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    try output.write(png, named: file)
                }
            }
        }
        print("Card snapshots written to \(output.directory.path)")
    }

    func testRenderPanel() async throws {
        guard let folder = ProcessInfo.processInfo.environment["KEEPTIDE_SNAPSHOT_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR to render the panel")
        }
        let output = SnapshotFolder(requested: URL(fileURLWithPath: folder, isDirectory: true))
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await seedPanelClips(into: harness, now: Date())
        try await harness.consumer.synchronize()
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) }, recordUse: { _ in },
                                 didWrite: { _ in })
        let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste,
                                           preview: PreviewService(read: { try await repository.read($0) }))
        let suite = "QuickAccessSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = QuickAccessPreferences(defaults: defaults)
        preferences.cardSize = .medium
        // The band as it was before the frequent clips, with no room below the cards for their icons.
        preferences.showsFrequentClips = false
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let controller = PanelController(state: QuickAccessState(services: { services }), preferences: preferences,
                                         visibleFrame: screen)
        addTeardownBlock { controller.state.close() }
        let window = try XCTUnwrap(controller.window)

        // As it opens: the newest clips, the search folded to its icon.
        controller.state.open()
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let rows = controller.state.selection.rows
            return rows.count == 8 && rows.prefix(6).allSatisfy { controller.state.details[$0.ref] != nil }
        }
        try await write(window, as: "panel-open", into: output)

        // Searching "rebase": the search open with the query, and the three clips that match.
        let field = try XCTUnwrap(window.contentView.flatMap { views(QuickAccessSearchField.self, in: $0).first })
        XCTAssertTrue(window.makeFirstResponder(field))
        try XCTUnwrap(field.currentEditor() as? NSTextView)
            .insertText("rebase", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let state = controller.state
            return state.query == "rebase" && state.phase == .results && state.selection.isComplete
                && state.selection.rows.allSatisfy { state.details[$0.ref] != nil }
        }
        XCTAssertEqual(controller.state.selection.rows.count, 3)
        try await write(window, as: "panel-search", into: output)

        // The same search while the index rebuilds: the notice at the toolbar's left end, Return's hint at its right.
        harness.status.update(.rebuilding)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.deleteBackward(nil)
        editor.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let state = controller.state
            return state.query == "rebase" && state.phase == .results && state.selection.isComplete
                && state.indexNotice == .rebuilding && state.selection.rows.allSatisfy { state.details[$0.ref] != nil }
        }
        try await write(window, as: "panel-rebuilding", into: output)

        // The same on a screen 1024 pt wide, where the open search leaves the notice less room.
        controller.state.close()
        let narrow = PanelController(state: QuickAccessState(services: { services }), preferences: preferences,
                                     visibleFrame: NSRect(x: 0, y: 0, width: 1024, height: 640))
        addTeardownBlock { narrow.state.close() }
        let narrowWindow = try XCTUnwrap(narrow.window)
        narrow.state.open()
        let narrowField = try XCTUnwrap(narrowWindow.contentView.flatMap {
            views(QuickAccessSearchField.self, in: $0).first
        })
        XCTAssertTrue(narrowWindow.makeFirstResponder(narrowField))
        try XCTUnwrap(narrowField.currentEditor() as? NSTextView)
            .insertText("rebase", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let state = narrow.state
            return state.query == "rebase" && state.phase == .results && state.selection.isComplete
                && state.indexNotice == .rebuilding && state.selection.rows.allSatisfy { state.details[$0.ref] != nil }
        }
        try await write(narrowWindow, as: "panel-rebuilding-1024", into: output)
        print("Panel snapshots written to \(output.directory.path)")
    }

    func testRenderDirectPastePanels() async throws {
        guard let folder = ProcessInfo.processInfo.environment["KEEPTIDE_SNAPSHOT_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR to render the panel")
        }
        let output = SnapshotFolder(requested: URL(fileURLWithPath: folder, isDirectory: true))
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let now = Date()
        try await seedPanelClips(into: harness, now: now)
        try await harness.consumer.synchronize()
        let repository = ContentRepository(controller: harness.controller)
        let suite = "QuickAccessSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = QuickAccessPreferences(defaults: defaults)
        preferences.cardSize = .medium
        preferences.showsFrequentClips = false
        // A panel whose session asks `fake` what is in front. The fake never posts a key.
        func panel(asking fake: FakeDirectPasteSystem) -> PanelController {
            let paste = PasteService(pasteboard: board, read: { try await repository.read($0) }, recordUse: { _ in },
                                     didWrite: { _ in }, system: fake.system)
            let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste,
                                               preview: PreviewService(read: { try await repository.read($0) }))
            return PanelController(state: QuickAccessState(services: { services }), preferences: preferences,
                                   visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
        }

        // TextEdit in front, with every check passing: the toolbar's right end names it.
        let pasting = panel(asking: FakeDirectPasteSystem())
        addTeardownBlock { pasting.state.close() }
        pasting.state.open()
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let rows = pasting.state.selection.rows
            return rows.count == 8 && rows.prefix(6).allSatisfy { pasting.state.details[$0.ref] != nil }
        }
        XCTAssertEqual(pasting.state.actions.primaryTitle, "Paste into TextEdit")
        try await write(try XCTUnwrap(pasting.window), as: "panel-paste-target", into: output)
        pasting.state.close()

        // Terminal in front, and the newest clip a command of three lines, one indented with a tab: Return opens the
        // review card in the preview's place.
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(
            "cd ~/Projects/keeptide\n\tgit fetch origin\ngit rebase origin/main\n".utf8))]])
        try await ContentStoreFixtures.insert(
            ItemValue(sourceApp: App.terminal, title: "cd ~/Projects/keeptide", captureID: capture.id,
                      historyEligible: true, lastCopiedAt: now.addingTimeInterval(60), copyCount: 1),
            capture, into: harness.controller)
        try await harness.consumer.synchronize()
        let terminal = FakeDirectPasteSystem()
        terminal.front = .terminal
        let reviewing = panel(asking: terminal)
        addTeardownBlock { reviewing.state.close() }
        reviewing.state.open()
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let rows = reviewing.state.selection.rows
            return rows.count == 9 && rows.prefix(6).allSatisfy { reviewing.state.details[$0.ref] != nil }
        }
        reviewing.perform(.primary)
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) { reviewing.state.commandReview != nil }
        XCTAssertEqual(reviewing.state.commandReview?.command.lineCount, 3)
        try await write(try XCTUnwrap(reviewing.window), as: "panel-review", into: output)
        XCTAssertEqual(terminal.sent, [])
        print("Direct paste snapshots written to \(output.directory.path)")
    }

    func testRenderFrequentWing() async throws {
        guard let folder = ProcessInfo.processInfo.environment["KEEPTIDE_SNAPSHOT_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR to render the frequent wing")
        }
        let output = SnapshotFolder(requested: URL(fileURLWithPath: folder, isDirectory: true))
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let now = Date()
        try await seedPanelClips(into: harness, now: now)
        // How often clips were used, as copies and pastes record it. The command is used often too, but it is among the
        // three newest, which medium cards show whole beside a wing that puts the newest in the middle, so the wing
        // leaves it out.
        for (title, times) in [("Rebase checklist", 12), ("Thursday", 5), ("git-rebase", 3),
                               ("git rebase origin/main", 9)] {
            try await recordUses(of: title, times: times, in: harness, now: now)
        }
        try await harness.consumer.synchronize()
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) }, recordUse: { _ in },
                                 didWrite: { _ in })
        let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste,
                                           preview: PreviewService(read: { try await repository.read($0) }),
                                           usage: LocalUsageStore(controller: harness.controller))
        let suite = "QuickAccessSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = QuickAccessPreferences(defaults: defaults)
        preferences.showsFrequentClips = true
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        // A panel with `cardSize` cards, its session opened as the shortcut opens it: the wing leaves out the newest
        // clips the band shows whole beside it.
        func openPanel(_ cardSize: CardSize, over services: QuickAccessServices) -> PanelController {
            preferences.cardSize = cardSize
            let panel = PanelController(state: QuickAccessState(services: { services }), preferences: preferences,
                                        visibleFrame: screen)
            let metrics = StripLayout.metrics(for: cardSize, visibleWidth: screen.width, showsFrequentClips: true)
            panel.state.open(frequentWingFirstScreen: { StripLayout.recentShownWhole(metrics, frequentCount: $0) })
            return panel
        }

        // As it opens: the three clips used most, from the least used to the most used, then the divider and the newest
        // clip, selected in the middle of the band, with the most used beside it.
        let controller = openPanel(.medium, over: services)
        addTeardownBlock { controller.state.close() }
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        try await waitForDetails(of: controller, rows: 11)
        XCTAssertEqual(state.selection.rows.prefix { $0.isFrequent }.map(\.title),
                       ["git-rebase", "Thursday", "Rebase checklist"])
        XCTAssertEqual(state.selection.rows.prefix { $0.isFrequent }.map(\.frequentUses), [3, 5, 12])
        XCTAssertEqual(state.selection.selectedRow?.title, "Screenshot")
        try await write(window, as: "panel-frequent-open", into: output)

        // The search opened on an empty query, as a click on its icon leaves it: the wing stays.
        let content = try XCTUnwrap(window.contentView)
        try XCTUnwrap(views(QuickAccessSearchControl.self, in: content).first).onUnfold?()
        XCTAssertTrue(state.isSearchExpanded)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selection.frequentCount, 3)
        try await write(window, as: "panel-frequent-search", into: output)

        // Folded again, and six steps to the right: the divider has gone off the band's left end, where the clock rests,
        // and the flame is hidden.
        controller.perform(.escape)
        XCTAssertFalse(state.isSearchExpanded)
        for _ in 0..<6 { controller.perform(.move(1)) }
        XCTAssertEqual(state.selection.selectedRow?.title, "Rebase checklist")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)
        let icons = try XCTUnwrap(views(QuickAccessStripView.self, in: content).first).sectionLabels.subviews
        let flame = try XCTUnwrap(icons.first { $0.accessibilityIdentifier() == "QuickAccessFrequentLabel" })
        let clock = try XCTUnwrap(icons.first { $0.accessibilityIdentifier() == "QuickAccessRecentLabel" })
        XCTAssertTrue(flame.isHidden)
        XCTAssertFalse(clock.isHidden)
        XCTAssertEqual(clock.frame.minX, StripLayout.sectionLabelPinInset, accuracy: 0.5)
        try await write(window, as: "panel-frequent-scrolled", into: output)

        // Small cards: three frequent cards reach the middle, where the band shows the three newest whole, so the wing
        // holds the same three and the newest clip is in the middle.
        controller.state.close()
        let small = openPanel(.small, over: services)
        addTeardownBlock { small.state.close() }
        try await waitForDetails(of: small, rows: 11)
        XCTAssertEqual(small.state.selection.rows.prefix { $0.isFrequent }.map(\.title),
                       ["git-rebase", "Thursday", "Rebase checklist"])
        try await write(try XCTUnwrap(small.window), as: "panel-frequent-open", cardSize: .small, into: output)
        small.state.close()

        // A wing of twenty, in a library of its own: twenty more clips, older than the boards' and each used a
        // different number of times. The most used, F1, and the next, F2, stand just left of the newest clip.
        let twentyHarness = try SearchHarness.make(in: self)
        try await seedPanelClips(into: twentyHarness, now: now)
        let used = Self.twentyFrequent
        for (rank, text) in used.enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
            let item = ItemValue(sourceApp: [App.notes, App.terminal, App.mail][rank % 3], title: text,
                                 captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: now.addingTimeInterval(-Double(4 * 24 * 60 + rank) * 60), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: twentyHarness.controller)
        }
        for (rank, text) in used.enumerated() {
            try await recordUses(of: text, times: 2 * (used.count - rank), in: twentyHarness, now: now)
        }
        try await twentyHarness.consumer.synchronize()
        let twentyRepository = ContentRepository(controller: twentyHarness.controller)
        let twentyServices = QuickAccessServices(
            repository: twentyRepository, search: twentyHarness.service,
            paste: PasteService(pasteboard: board, read: { try await twentyRepository.read($0) }, recordUse: { _ in },
                                didWrite: { _ in }),
            preview: PreviewService(read: { try await twentyRepository.read($0) }),
            usage: LocalUsageStore(controller: twentyHarness.controller))
        let twenty = openPanel(.medium, over: twentyServices)
        addTeardownBlock { twenty.state.close() }
        let twentyState = twenty.state
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let rows = twentyState.selection.rows
            // The cards on the band: the three frequent ones nearest the divider and the newest four.
            return twentyState.phase == .results && rows.count == 48
                && rows[17..<24].allSatisfy { twentyState.details[$0.ref] != nil }
        }
        let wing = twentyState.selection.rows.prefix { $0.isFrequent }
        XCTAssertEqual(wing.count, 20)
        XCTAssertEqual(wing.map(\.title), used.reversed())
        XCTAssertEqual(wing.suffix(2).map(\.frequentUses), [38, 40])
        XCTAssertEqual(twentyState.selection.selectedRow?.title, "Screenshot")
        try await write(try XCTUnwrap(twenty.window), as: "panel-frequent-twenty", into: output)
        print("Frequent wing snapshots written to \(output.directory.path)")
    }

    /// Twenty made-up clips for a wing of twenty, the most used first.
    private static let twentyFrequent = [
        "git status --short", "Thanks, talk soon!", "ssh deploy@staging.example.com", "npm run build -- --watch",
        "See you at 10 in the small room.", "rg --files | wc -l", "Best regards, Sam", "docker compose up -d",
        "https://example.com/handbook", "SELECT * FROM orders LIMIT 20;", "Out of office until Monday.",
        "make test", "Room 4B, second floor", "xcodebuild -list", "Can we move this to Thursday?",
        "brew upgrade --cask", "Invoice #2027-114", "kubectl get pods -A", "Let me check and get back to you.",
        "swift test --parallel",
    ]

    // MARK: The clips

    /// The strip as it opens, newest first: a screenshot, a command, a page, a Chinese note, a PDF and an email.
    private func openRow(now: Date) throws -> [Card] {
        let link = "https://developer.apple.com/documentation/appkit/nspanel"
        let note = "下周三前把设计定稿，周四上午和产品一起过一遍交互细节。"
        let email = "Thursday at 3 works for me. I’ll book the small room on the fourth floor and bring the printouts of both directions."
        return [
            Card(row: row(.image, "Screenshot", from: App.preview, minutesAgo: 0, now: now),
                 detail: ClipDetail(pixelSize: CGSize(width: 2880, height: 1800), thumbnail: try screenshot(),
                                    fillsFrame: true),
                 isSelected: true),
            Card(row: row(.text, "git rebase origin/main", from: App.terminal, minutesAgo: 2, now: now),
                 detail: ClipDetail(excerpt: "git rebase origin/main", characterCount: 22)),
            Card(row: row(.url, link, from: App.safari, minutesAgo: 15, now: now),
                 detail: ClipDetail(excerpt: link, characterCount: link.count,
                                    linkTitle: "NSPanel — AppKit | Apple Developer Documentation")),
            Card(row: row(.text, note, from: App.notes, minutesAgo: 60, now: now),
                 detail: ClipDetail(excerpt: note, characterCount: note.count)),
            Card(row: row(.file, "Quick Access — Review.pdf", from: App.finder, minutesAgo: 180, now: now),
                 detail: ClipDetail(fileNames: ["Quick Access — Review.pdf"])),
            Card(row: row(.text, email, from: App.mail, minutesAgo: 26 * 60, now: now),
                 detail: ClipDetail(excerpt: email, characterCount: email.count)),
        ]
    }

    /// Search results for "rebase" with their hits marked, then a link without a page title, a long paragraph, and a
    /// note whose source app is not known.
    private func searchRow(now: Date) -> [Card] {
        let command = "git rebase origin/main"
        let checklist = "Rebase checklist: fetch, rebase onto main, run tests, push with lease."
        let page = "https://git-scm.com/docs/git-rebase"
        let wiki = "https://zh.wikipedia.org/wiki/%E5%89%AA%E8%B4%B4%E6%9D%BF"
        let paragraph = """
            Quarterly planning notes: the strip opens on the newest clip, search folds into an icon until you type, and \
            each card shows the clip at a size you can read from across the desk without leaning in.
            """
        return [
            Card(row: row(.text, command, from: App.terminal, minutesAgo: 2, now: now,
                          snippet: SearchSnippet(text: command, highlights: [4..<10])),
                 detail: ClipDetail(excerpt: command, characterCount: 22), isSelected: true),
            Card(row: row(.text, "Rebase checklist", from: App.notes, minutesAgo: 26 * 60, now: now,
                          snippet: SearchSnippet(text: checklist, highlights: [0..<6, 25..<31]), savedAsMemo: true),
                 detail: ClipDetail(excerpt: checklist, characterCount: checklist.count)),
            Card(row: row(.url, page, from: App.safari, minutesAgo: 2 * 24 * 60, now: now,
                          snippet: SearchSnippet(text: page, highlights: [29..<35])),
                 detail: ClipDetail(excerpt: page, characterCount: page.count, linkTitle: "Git - git-rebase Documentation")),
            Card(row: row(.url, wiki, from: App.safari, minutesAgo: 3 * 24 * 60, now: now),
                 detail: ClipDetail(excerpt: wiki, characterCount: wiki.count)),
            Card(row: row(.text, "Quarterly planning notes", from: App.mail, minutesAgo: 4 * 24 * 60, now: now),
                 detail: ClipDetail(excerpt: paragraph, characterCount: paragraph.count)),
            Card(row: row(.text, "Short note", from: nil, minutesAgo: 5 * 24 * 60, now: now),
                 detail: ClipDetail(excerpt: "Short note", characterCount: 10)),
        ]
    }

    /// What a card shows beyond the design's boards: details still on their way, text that is gone, a picture too
    /// tall to fill the card, several files, a partly indexed text and a link without a host.
    private func statesRow(now: Date) throws -> [Card] {
        let long = String(repeating: "Partly indexed log line with a timestamp and a request id. ", count: 6)
        return [
            Card(row: row(.text, "Meeting notes", from: App.notes, minutesAgo: 1, now: now), detail: nil),
            Card(row: row(.text, "Standup", from: App.notes, minutesAgo: 8, now: now, savedAsMemo: true,
                          isTextUnavailable: true),
                 detail: ClipDetail()),
            Card(row: row(.image, "Receipt", from: App.preview, minutesAgo: 30, now: now),
                 detail: ClipDetail(pixelSize: CGSize(width: 600, height: 6_000), thumbnail: try receipt(),
                                    fillsFrame: false)),
            Card(row: row(.file, "Budget 2027.numbers", from: App.finder, minutesAgo: 90, now: now),
                 detail: ClipDetail(fileNames: ["Budget 2027.numbers", "Notes.txt", "Photo.heic"], itemCount: 3)),
            Card(row: row(.text, "Partly indexed log", from: App.terminal, minutesAgo: 240, now: now,
                          isPartiallyIndexed: true),
                 detail: ClipDetail(excerpt: long, characterCount: 48_210)),
            Card(row: row(.url, "mailto:someone@example.com", from: App.mail, minutesAgo: 600, now: now),
                 detail: ClipDetail(excerpt: "mailto:someone@example.com", characterCount: 26)),
        ]
    }

    /// Text at its extremes: emoji and nothing else, a single character, and eight lines of code.
    private func extremesRow(now: Date) -> [Card] {
        let emoji = "🎉🚀✨👍🏽👩‍👩‍👧🌏🍜☕️🎧📦✅🔥"
        let code = """
            func greet(_ name: String) -> String {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    return "Hello, world!"
                }
                return "Hello, " + trimmed + "!"
            }
            print(greet("Keeptide"))
            """
        return [
            Card(row: row(.text, emoji, from: App.notes, minutesAgo: 1, now: now),
                 detail: ClipDetail(excerpt: emoji, characterCount: emoji.count), isSelected: true),
            Card(row: row(.text, "A", from: App.notes, minutesAgo: 4, now: now),
                 detail: ClipDetail(excerpt: "A", characterCount: 1)),
            Card(row: row(.text, "func greet(_ name: String) -> String {", from: App.terminal, minutesAgo: 12, now: now),
                 detail: ClipDetail(excerpt: code, characterCount: code.count)),
        ]
    }

    /// Frequent clips, each saying how often it was used where the time would be: a checklist used 12 times, three files
    /// saved as a memo and used 1,234 times, whose marks and count leave a small card's colour band too little room,
    /// and a page used 3 times.
    private func frequentRow(now: Date) -> [Card] {
        let checklist = "Rebase checklist: fetch, rebase onto main, run tests, push with lease."
        let page = "https://git-scm.com/docs/git-rebase"
        return [
            Card(row: row(.text, "Rebase checklist", from: App.notes, minutesAgo: 27 * 60, now: now, uses: 12),
                 detail: ClipDetail(excerpt: checklist, characterCount: checklist.count), isSelected: true),
            Card(row: row(.file, "Budget 2027.numbers", from: App.finder, minutesAgo: 3 * 24 * 60, now: now,
                          savedAsMemo: true, uses: 1_234),
                 detail: ClipDetail(fileNames: ["Budget 2027.numbers", "Notes.txt", "Photo.heic"], itemCount: 3)),
            Card(row: row(.url, page, from: App.safari, minutesAgo: 2 * 24 * 60, now: now, uses: 3),
                 detail: ClipDetail(excerpt: page, characterCount: page.count,
                                    linkTitle: "Git - git-rebase Documentation")),
        ]
    }

    /// `uses` makes the row a frequent one, used that many times.
    private func row(_ kind: ContentKind, _ title: String, from app: String?, minutesAgo: Double, now: Date,
                     snippet: SearchSnippet? = nil, savedAsMemo: Bool = false, isPartiallyIndexed: Bool = false,
                     isTextUnavailable: Bool = false, uses: Int64? = nil) -> QuickAccessRow {
        QuickAccessRow(
            ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 5, count: 32)),
            title: title, snippet: snippet, kind: kind, sourceApp: app, date: now.addingTimeInterval(-minutesAgo * 60),
            savedAsMemo: savedAsMemo, isPartiallyIndexed: isPartiallyIndexed, isTextUnavailable: isTextUnavailable,
            frequentUses: uses
        )
    }

    /// The clips the design's boards show, stored in a temporary library, newest last: two found by "rebase" that
    /// are older than the rest, then an email, a PDF, a Chinese note, a page, a command and a screenshot.
    private func seedPanelClips(into harness: SearchHarness, now: Date) async throws {
        func store(_ title: String, _ representations: [(String, Data)], from app: String,
                   minutesAgo: Double) async throws {
            let capture = try ContentStoreFixtures.capture([representations])
            let item = ItemValue(sourceApp: app, title: title, captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: now.addingTimeInterval(-minutesAgo * 60), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        }
        func text(_ string: String) -> (String, Data) { ("public.utf8-plain-text", Data(string.utf8)) }
        func link(_ url: String, title: String) -> [(String, Data)] {
            [("public.url", Data(url.utf8)), ("public.url-name", Data(title.utf8)), text(url)]
        }
        let checklist = "Rebase checklist: fetch, rebase onto main, run tests, push with lease."
        let email = "Thursday at 3 works for me. I’ll book the small room on the fourth floor and bring the printouts of both directions."
        let note = "下周三前把设计定稿，周四上午和产品一起过一遍交互细节。"
        let page = "https://developer.apple.com/documentation/appkit/nspanel"
        try await store("git-rebase", link("https://git-scm.com/docs/git-rebase", title: "Git - git-rebase Documentation"),
                        from: App.safari, minutesAgo: 2 * 24 * 60)
        try await store("Rebase checklist", [text(checklist)], from: App.notes, minutesAgo: 27 * 60)
        try await store("Thursday", [text(email)], from: App.mail, minutesAgo: 26 * 60)
        // A file is stored by reference, its location kept apart from the clip as the library keeps it.
        let file = try ContentStoreFixtures.localReferenceCapture()
        let reference = try XCTUnwrap(file.representations.first)
        try await FileAccessStore(controller: harness.controller).put(
            LocalFileAccess(id: reference.id, snapshotID: file.id,
                            bytes: Data("file:///Synthetic/Quick%20Access%20%E2%80%94%20Review.pdf".utf8)),
            expecting: harness.controller.identity())
        try await ContentStoreFixtures.insert(
            ItemValue(sourceApp: App.finder, title: "Quick Access — Review.pdf", captureID: file.id, historyEligible: true,
                      lastCopiedAt: now.addingTimeInterval(-180 * 60), copyCount: 1),
            file, into: harness.controller)
        try await store("Note", [text(note)], from: App.notes, minutesAgo: 60)
        try await store("NSPanel", link(page, title: "NSPanel — AppKit | Apple Developer Documentation"),
                        from: App.safari, minutesAgo: 15)
        try await store("git rebase origin/main", [text("git rebase origin/main")], from: App.terminal, minutesAgo: 2)
        let picture = try XCTUnwrap(NSBitmapImageRep(cgImage: try screenshot(scale: 4))
            .representation(using: .png, properties: [:]))
        try await store("Screenshot", [("public.png", picture)], from: App.preview, minutesAgo: 0)
    }

    /// Records `times` successful uses of the stored clip with this title in the library's usage store, a second apart,
    /// the last a minute before `now`, as copies and pastes record them.
    private func recordUses(of title: String, times: Int, in harness: SearchHarness, now: Date) async throws {
        let stored = try await ContentRepository(controller: harness.controller).recent(limit: 100)
        let ref = try XCTUnwrap(stored.first { $0.title == title }?.history, "\(title) is not stored")
        let usage = LocalUsageStore(controller: harness.controller)
        for second in 0..<times {
            try await usage.record(UseReceipt(ref: ref, occurredAt: now.addingTimeInterval(-60 - Double(second)),
                                              outcome: .success))
        }
    }

    /// Waits until the panel lists `count` rows and every clip listed has its details. The strip asks for them only for
    /// the clips it frames, which here, in one wing or the other, are all of them as the panel opens.
    private func waitForDetails(of controller: PanelController, rows count: Int) async throws {
        try await SearchTestSupport.waitUntil(timeout: .seconds(20)) {
            let state = controller.state
            return state.phase == .results && state.selection.rows.count == count
                && state.selection.rows.allSatisfy { state.details[$0.ref] != nil }
        }
    }

    /// Draws the panel's window in dark and in light, at twice its size, over the design's desktop. `cardSize` is the
    /// size the panel's settings give its cards, which names the files.
    private func write(_ window: NSWindow, as name: String, cardSize: CardSize = .medium,
                       into output: SnapshotFolder) async throws {
        for dark in [true, false] {
            let file = "\(name)-\(cardSize.rawValue)-\(dark ? "dark" : "light").png"
            let png = try await renderPanel(window, dark: dark)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = file
            attachment.lifetime = .keepAlways
            add(attachment)
            try output.write(png, named: file)
        }
    }

    /// The window's content in one appearance, over the design's desktop and the window behind the panel. The band's
    /// material is the window server's work: it blurs what lies behind the window, and AppKit draws a flat grey in its
    /// place in a picture like this one. So the band is drawn as it is with Reduce Transparency, in the design's own
    /// colour for it, without the blur.
    private func renderPanel(_ window: NSWindow, dark: Bool) async throws -> Data {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        window.appearance = appearance
        window.colorSpace = .sRGB
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        // SwiftUI draws on the next turn of the run loop.
        try await Task.sleep(for: .milliseconds(300))
        let backdrop = try XCTUnwrap(views(QuickAccessBandBackdrop.self, in: content).first)
        backdrop.reducesTransparency = true
        content.layoutSubtreeIfNeeded()
        let size = content.bounds.size
        func bitmap() throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB))
            rep.size = size
            return rep
        }
        let panel = try bitmap()
        appearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: panel)
        }
        let picture = try bitmap()
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: picture))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        drawDesktop(in: NSRect(origin: .zero, size: size), screenOrigin: window.frame.origin, dark: dark)
        panel.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(picture.representation(using: .png, properties: [:]))
    }

    /// The boards' desktop: a diagonal wash, with a document window over it. `screenOrigin` is where the panel's
    /// window sits on the 1440 × 875 screen, which is all of a 1440 × 900 screen but its menu bar.
    private func drawDesktop(in rect: NSRect, screenOrigin: NSPoint, dark: Bool) {
        func colour(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let wash = dark ? [colour(0x1B2230), colour(0x2A2333), colour(0x1E1A24)]
            : [colour(0xD9DEE3), colour(0xE8E4DC), colour(0xE2D8CA)]
        NSGradient(colors: wash, atLocations: [0, dark ? 0.58 : 0.55, 1], colorSpace: .sRGB)?
            .draw(in: rect, angle: -70)
        // The document window: 1120 × 720, 96 from the screen's left and 64 below its top, in the boards' 900 pt
        // tall screen whose menu bar is 25 tall.
        let document = NSRect(x: 96 - screenOrigin.x, y: 900 - 64 - 720 - screenOrigin.y, width: 1120, height: 720)
        let shape = NSBezierPath(roundedRect: document, xRadius: 14, yRadius: 14)
        (dark ? colour(0x232327) : colour(0xFFFFFF)).setFill()
        shape.fill()
        let sidebar = NSRect(x: document.minX, y: document.minY, width: 230, height: document.height)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (dark ? colour(0x1C1C1F) : colour(0xF4F3F1)).setFill()
        sidebar.fill()
        let lines: [(width: CGFloat, height: CGFloat)] = [(0.44, 22), (0.96, 9), (0.90, 9), (0.93, 9), (0.58, 9),
                                                          (0, 9), (0.92, 9), (0.97, 9), (0.86, 9)]
        var top = document.maxY - 96
        let textWidth = document.width - 230 - 240
        for (index, line) in lines.enumerated() {
            let bar = NSRect(x: sidebar.maxX + 120, y: top - line.height, width: textWidth * line.width,
                             height: line.height)
            (index == 0 ? (dark ? colour(0xE5E5EA) : colour(0x1D1D1F)) : (dark ? colour(0x3A3A3F) : colour(0xDCDAD5)))
                .setFill()
            NSBezierPath(roundedRect: bar, xRadius: line.height / 2, yRadius: line.height / 2).fill()
            top -= line.height + 16
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func views<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// A made-up till receipt, ten times as tall as it is wide.
    private func receipt() throws -> CGImage {
        let (width, height) = (60, 600)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1))
        for line in stride(from: 20, to: height - 20, by: 14) {
            context.fill(CGRect(x: 6, y: line, width: line % 3 == 0 ? 30 : 48, height: 4))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// A made-up screenshot of a window on a desktop, 16:10 like a laptop's screen: 720 × 450 pixels, or `scale` times
    /// as many each way, as a Retina screen's is.
    private func screenshot(scale: Int = 1) throws -> CGImage {
        let (width, height) = (720, 450)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        func fill(_ rect: CGRect, _ red: Double, _ green: Double, _ blue: Double, radius: CGFloat = 0) {
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        // Core Graphics counts up from the bottom.
        func top(_ y: CGFloat, _ h: CGFloat) -> CGFloat { CGFloat(height) - y - h }
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0.23, 0.25, 0.29)
        let window = CGRect(x: 44, y: top(40, 372), width: 632, height: 372)
        fill(window, 0.96, 0.96, 0.97, radius: 16)
        fill(CGRect(x: window.minX, y: top(40, 38), width: window.width, height: 38), 0.90, 0.90, 0.92, radius: 16)
        fill(CGRect(x: window.minX, y: top(62, 16), width: window.width, height: 16), 0.90, 0.90, 0.92)
        for (index, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.78, 0.25)].enumerated() {
            fill(CGRect(x: window.minX + 18 + CGFloat(index) * 22, y: top(53, 13), width: 13, height: 13),
                 color.0, color.1, color.2, radius: 6.5)
        }
        fill(CGRect(x: window.minX, y: top(78, 334), width: 164, height: 334), 0.93, 0.93, 0.94)
        fill(CGRect(x: 240, y: top(112, 22), width: 220, height: 22), 0.11, 0.11, 0.12, radius: 5)
        for (index, length) in [300, 270, 290, 180].enumerated() {
            fill(CGRect(x: 240, y: top(160 + CGFloat(index) * 30, 14), width: CGFloat(length), height: 14),
                 0.82, 0.82, 0.84, radius: 4)
        }
        fill(CGRect(x: 240, y: top(320, 40), width: 110, height: 40), 0.04, 0.52, 1.0, radius: 9)
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: Rendering

    /// Lays the cards out from the band's left end as the strip does when it opens, each in its own hosting view, and
    /// draws them at twice their size, as PNG data.
    private func render(_ cards: [Card], cardSize: CardSize, dark: Bool, now: Date,
                        names: ApplicationNames) async throws -> Data {
        let metrics = StripLayout.metrics(for: cardSize, visibleWidth: 1440)
        // Room above and below the cards for the selection ring and the cards' shadows.
        let (above, below): (CGFloat, CGFloat) = (24, 36)
        let size = NSSize(width: 2 * metrics.dockInset + CGFloat(cards.count) * metrics.step - metrics.gap,
                          height: above + metrics.frameSize.height + below)
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.colorSpace = .sRGB
        addTeardownBlock { window.close() }
        // The band's colour where its glass would be: the switcher's tint, opaque.
        let band = NSView(frame: NSRect(origin: .zero, size: size))
        band.wantsLayer = true
        band.layer?.backgroundColor = dark ? CGColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255, alpha: 1)
            : CGColor(srgbRed: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1)
        window.contentView = band
        for (index, card) in cards.enumerated() {
            // As in the strip, each band takes its colour from the icon its card shows.
            let icon = names.icon(for: card.row.sourceApp)
            let view = StripFrameView(
                content: StripFrameContent.make(row: card.row, detail: card.detail, cardSize: cardSize, now: now),
                applicationIcon: icon, metrics: metrics,
                headerTint: card.row.sourceApp.map { HeaderTint.tint(forIconOf: $0, icon: icon) },
                isSelected: card.isSelected)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            // The ring and the shadow are drawn outside the card.
            host.clipsToBounds = false
            host.frame = NSRect(x: metrics.dockInset + CGFloat(index) * metrics.step, y: below,
                                width: metrics.frameSize.width, height: metrics.frameSize.height)
            band.addSubview(host)
        }
        band.layoutSubtreeIfNeeded()
        // SwiftUI draws on the next turn of the run loop.
        try await Task.sleep(for: .milliseconds(200))
        band.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)?.retagging(with: .sRGB))
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            band.cacheDisplay(in: band.bounds, to: rep)
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// The folder the PNG files go to: the one asked for, or, once the sandbox refuses it, the folder of the same name in
/// the app's temporary directory.
private final class SnapshotFolder {
    private let requested: URL
    private(set) var directory: URL

    init(requested: URL) {
        self.requested = requested
        directory = requested
    }

    func write(_ data: Data, named name: String) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        } catch where directory == requested {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(requested.lastPathComponent, isDirectory: true)
            try write(data, named: name)
        }
    }
}
