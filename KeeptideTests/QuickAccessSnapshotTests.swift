import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

/// Renders the strip's cards to PNG files for a person to compare with the design. It runs only when
/// `KEEPTIDE_SNAPSHOT_DIR` names a folder, which `xcodebuild` passes on from `TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR`;
/// otherwise it is skipped and writes nothing. The tests run inside the sandboxed app, which may not write to a folder
/// outside its container: the files then go to a folder of the same name in the app's temporary directory, and the
/// log says where. Each file is attached to the test's result as well.
///
/// Each card is the real `StripFrameView` in its own `NSHostingView`, laid out in a row as the strip lays them out, on
/// the band's colour and drawn at twice its size. Every clip is made up here. Apps that ship with macOS stand in as the
/// clips' sources, and only their icons and names are read.
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
        let rows: [(name: String, cards: [Card])] = [
            ("open", try openRow(now: now)), ("search", searchRow(now: now)), ("states", try statesRow(now: now)),
        ]

        for (name, cards) in rows {
            for cardSize in CardSize.allCases {
                for dark in [true, false] {
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

    private func row(_ kind: ContentKind, _ title: String, from app: String?, minutesAgo: Double, now: Date,
                     snippet: SearchSnippet? = nil, savedAsMemo: Bool = false, isPartiallyIndexed: Bool = false,
                     isTextUnavailable: Bool = false) -> QuickAccessRow {
        QuickAccessRow(
            ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 5, count: 32)),
            title: title, snippet: snippet, kind: kind, sourceApp: app, date: now.addingTimeInterval(-minutesAgo * 60),
            savedAsMemo: savedAsMemo, isPartiallyIndexed: isPartiallyIndexed, isTextUnavailable: isTextUnavailable
        )
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

    /// A made-up screenshot of a window on a desktop, 16:10 like a laptop's screen.
    private func screenshot() throws -> CGImage {
        let (width, height) = (720, 450)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
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
