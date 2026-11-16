import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// The text recognized in an image, beside the image in the Library's detail: opened for the item the detail shows,
/// by Item › Extract Text and the row's menu, and closed with its close button, with Escape, or as the detail moves to
/// another item. What it shows is worked out as quick access works it out (`ResultColumnContents`).
@MainActor @Observable
final class LibraryTextColumn {
    /// What the column reads and acts through.
    struct Services {
        let derivedText: DerivedTextCoordinator
        /// Writes text to the clipboard as Keeptide's own copy, which capture skips; false where it couldn't.
        let copyText: @MainActor (String) -> Bool
        /// Saves text as a snippet of its own.
        let saveSnippet: @MainActor (String) async throws -> Void
        /// Whether recognized text keeps the image's line breaks, as Settings says.
        let keepsLineBreaks: @MainActor () -> Bool
        /// Says something to VoiceOver from the Library's window.
        let announce: @MainActor (String) -> Void
    }

    static let copiedNoteDuration: Duration = .seconds(1.5)

    /// The image whose text the column shows; nil while it is closed.
    private(set) var ref: ContentRef?
    /// What the store kept of the image's text, once it has said. Until it is what it said of `ref`, the column is
    /// still reading.
    private var kept: KeptResult?
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Tells one opening of the column from the next, so that a read or a save that ends after the column closed leaves
    /// the next opening alone.
    @ObservationIgnored private var opening = UUID()
    /// The opening whose save is under way, if any: it saves once at a time.
    @ObservationIgnored private var savingOpening: UUID?
    /// Whether the column's text was copied just now: the column says so for a moment.
    private(set) var isCopied = false
    @ObservationIgnored private var copiedNote: Task<Void, Never>?
    /// What saving the column's text as a snippet came to, said beside its buttons until the column closes.
    private(set) var saveMessage: String?
    /// The texts saved as snippets while the column was open: saving one again says it is there already.
    @ObservationIgnored private var savedTexts: Set<String> = []
    @ObservationIgnored private var endings = ResultColumnEndings()
    @ObservationIgnored private let services: @MainActor () -> Services?

    init(services: @escaping @MainActor () -> Services?) {
        self.services = services
    }

    /// What the column shows; nil while it is closed or without the library.
    var column: TextColumn? {
        guard let ref, let derivedText = services()?.derivedText else { return nil }
        return ResultColumnContents.text(for: ref, in: derivedText, kept: kept).column
    }

    /// The whole text the column shows, made now or kept from before: what Copy and Save as Snippet take.
    var text: String? { column?.wholeText }

    /// The latest recognition's ending that the column shows, which tells one ending from another; nil while it
    /// shows something else.
    var ending: UUID? {
        guard let ref, let derivedText = services()?.derivedText else { return nil }
        return derivedText.latestEnding(for: ref, operation: .extractText)
    }

    /// Whether the column shows how the latest recognition of its image just ended: the text it made, that it found
    /// none, or why it failed, rather than text kept from before.
    var isJustMade: Bool { ending != nil }

    /// Whether a recognition is under way or waiting its turn: the column offers to stop it.
    var isRecognizing: Bool { column?.isRecognizing == true }

    /// Whether there is a recognition to stop: one under way or waiting its turn, or one asked for that waits on what
    /// the store kept.
    var canStop: Bool {
        guard let ref, let derivedText = services()?.derivedText else { return false }
        return isRecognizing || derivedText.isWaitingToStart(ref, operation: .extractText)
    }

    /// Opens the column for `ref` and recognizes its text unless something was made of it already, as quick access
    /// does. Asked for while the column says a recognition failed, it tries again.
    func show(_ ref: ContentRef) {
        guard let services = services() else { return }
        if self.ref == ref, column?.isFailed == true {
            extractText()
            return
        }
        if self.ref != ref {
            open(ref, services.derivedText)
            services.announce("\(TextColumnWords.title), on this Mac")
        }
        services.derivedText.extractTextUnlessMade(from: ref, keepingLineBreaks: services.keepsLineBreaks())
    }

    /// Opens the column for `ref`, reading what was kept of its text.
    private func open(_ ref: ContentRef, _ derivedText: DerivedTextCoordinator) {
        close()
        self.ref = ref
        let opening = opening
        reading = Task { [weak self] in
            let saved = await derivedText.savedResult(for: ref, operation: .extractText)
            guard !Task.isCancelled, let self, self.opening == opening else { return }
            kept = KeptResult(source: ref, result: saved)
        }
    }

    /// Recognizes the column's image again, as Try Again does.
    func extractText() {
        guard let ref, let services = services() else { return }
        services.derivedText.extractText(from: ref, keepingLineBreaks: services.keepsLineBreaks())
    }

    func stop() {
        guard let ref else { return }
        services()?.derivedText.stop(ref, operation: .extractText)
    }

    /// Closes the column. A recognition under way goes on, and a save under way ends saying nothing.
    func close() {
        reading?.cancel()
        reading = nil
        opening = UUID()
        ref = nil
        kept = nil
        copiedNote?.cancel()
        copiedNote = nil
        isCopied = false
        saveMessage = nil
        savedTexts = []
    }

    /// The detail now shows `ref` as an image, or nothing: the column closes unless it is that image's.
    func follow(_ ref: ContentRef?) {
        guard self.ref != nil, self.ref != ref else { return }
        close()
    }

    /// Copies the column's whole text, or `part` of it as its own Copy hands it over, and says so. Returns whether the
    /// clipboard was written.
    @discardableResult
    func copy(_ part: String? = nil) -> Bool {
        guard ref != nil, let text = part ?? text, let services = services(), services.copyText(text) else {
            return false
        }
        isCopied = true
        services.announce("Copied")
        copiedNote?.cancel()
        copiedNote = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedNoteDuration)
            guard !Task.isCancelled else { return }
            self?.isCopied = false
        }
        return true
    }

    /// Saves the column's whole text as a snippet of its own, and returns what that came to, as the column says it;
    /// nil where there was no whole text to save, a save was under way already, or the column closed meanwhile.
    @discardableResult
    func saveAsSnippet() async -> String? {
        let opening = opening
        guard ref != nil, savingOpening != opening, let text, let services = services() else { return nil }
        guard !savedTexts.contains(text) else { return say("Already in Snippets", services) }
        savingOpening = opening
        defer { if savingOpening == opening { savingOpening = nil } }
        do {
            try await services.saveSnippet(text)
            guard self.opening == opening else { return nil }
            savedTexts.insert(text)
            return say("Text saved to Snippets", services)
        } catch {
            guard self.opening == opening else { return nil }
            return say("The text couldn't be saved. Try again.", services)
        }
    }

    private func say(_ message: String, _ services: Services) -> String {
        saveMessage = message
        services.announce(message)
        return message
    }

    /// What VoiceOver hears as a recognition ends here without new text, once per ending; nil otherwise. What the
    /// column shows as it opens is only shown.
    func endingToAnnounce() -> String? {
        let shown = ref.flatMap { ref in
            column.map { (ref: ref, ending: ending, words: $0.endingWords, isRead: $0.isRead) }
        }
        return endings.words(for: shown, isOpen: true)
    }

    /// Says how a recognition just ended without new text, where it did.
    func announceEnding() {
        guard let words = endingToAnnounce() else { return }
        services()?.announce(words)
    }
}

/// Where the Library's result column goes beside the item.
enum LibraryResultLayout {
    /// Narrower than this, the detail shows the column under the item.
    static let sideBySideWidth: CGFloat = 640

    static func isSideBySide(width: CGFloat) -> Bool { width >= sideBySideWidth }
}

/// What keys pressed in the Library's result text do before the text takes them: Escape closes the column, and ⌘.
/// stops a recognition, and never closes the column, so that one pressed just as the recognition ends isn't taken as
/// Escape. Held down, either has acted already.
@MainActor
enum LibraryResultKeys {
    /// True when the column took the key.
    static func handle(_ event: NSEvent, _ column: LibraryTextColumn) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isEscape = Int(event.keyCode) == kVK_Escape && modifiers.subtracting(.shift).isEmpty
        // ⇧⌘. too, where the keyboard needs Shift for the full stop.
        let isCommandPeriod = event.charactersIgnoringModifiers == "." && modifiers.subtracting(.shift) == .command
        guard isEscape || isCommandPeriod else { return false }
        guard !event.isARepeat else { return true }
        if isEscape { column.close() } else { column.stop() }
        return true
    }
}

/// The open item beside what was made of it: side by side where the detail is at least 640 points wide, the result
/// under the item where it is narrower, with a thin line between them as in quick access.
struct LibraryResultSplit<Content: View, Column: View>: View {
    let showsColumn: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let column: () -> Column

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = LibraryResultLayout.isSideBySide(width: geometry.size.width)
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsColumn {
                    ColumnDivider(vertical: sideBySide)
                    column().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// The Library's text column: quick access's, with the Library's own buttons at the end of its title. Escape in its
/// text closes it and gives the keyboard back to the list. Each image has a column of its own: the text and its
/// selection never carry over.
struct LibraryTextColumnView: View {
    let textColumn: LibraryTextColumn
    let column: TextColumn
    let returnFocusToList: () -> Void

    var body: some View {
        TextInImageColumn(column: column, pixelSize: nil, isJustMade: textColumn.isJustMade,
                          identifiers: .init(column: "LibraryTextInImage", extract: "LibraryExtractText"),
                          onCommand: { command in
                              if case .extractText = command { textColumn.extractText() }
                          },
                          onCopy: { textColumn.copy($0) },
                          onKeyDown: { event in
                              guard LibraryResultKeys.handle(event, textColumn) else { return false }
                              if textColumn.ref == nil { returnFocusToList() }
                              return true
                          }) {
            LibraryTextColumnButtons(textColumn: textColumn)
        }
        .id(textColumn.ref)
    }
}

/// The Library's buttons for the text beside an image, at the end of the column's title: Stop while it is recognized,
/// then Copy and Save as Snippet, dimmed until the text is whole, and Close. Under them, a note of a copy or a save.
/// Item › Copy Text and Save Text as Snippet do the same from the keyboard.
struct LibraryTextColumnButtons: View {
    let textColumn: LibraryTextColumn

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if textColumn.isRecognizing {
                    Button { textColumn.stop() } label: {
                        HStack(spacing: 6) {
                            Text("Stop")
                            ReviewKeycap(symbol: "⌘.")
                        }
                    }
                    .buttonStyle(TrayCapsuleButtonStyle())
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("LibraryStopTextRecognition")
                    .help("Stop Recognizing (⌘.)")
                }
                Group {
                    TrayRoundButton(symbol: "doc.on.doc", label: "Copy Text", help: "Copy Text",
                                    identifier: "LibraryCopyText") { textColumn.copy() }
                    TrayRoundButton(symbol: "bookmark", label: "Save Text as Snippet", help: "Save Text as Snippet",
                                    identifier: "LibrarySaveText") { Task { await textColumn.saveAsSnippet() } }
                }
                .disabled(textColumn.text == nil)
                TrayRoundButton(symbol: "xmark", label: "Close", help: "Close (Esc)",
                                identifier: "LibraryCloseResultColumn") { textColumn.close() }
            }
            if let note = textColumn.isCopied ? "Copied" : textColumn.saveMessage {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("LibraryTextColumnNote")
            }
        }
    }
}

/// Says to VoiceOver how a recognition in the text column ended without new text. It follows the column itself, so
/// that only it, and not the whole Library, follows each step of a recognition; it asks on every change of what the
/// column shows or of the ending it shows.
struct LibraryTextColumnAnnouncer: View {
    let textColumn: LibraryTextColumn

    private struct Shown: Equatable {
        let column: TextColumn?
        let ending: UUID?
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: Shown(column: textColumn.column, ending: textColumn.ending)) { _, _ in
                textColumn.announceEnding()
            }
    }
}
