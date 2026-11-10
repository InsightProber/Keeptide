import AppKit
import SwiftUI

/// The preview with the text recognized in an image beside it, on the card's tray: the image on the left, the text on
/// the right, with a thin line between them and nothing of their own under either. Where the card is narrow, the text
/// goes under the image.
struct QuickAccessSplitPreview: View {
    /// Narrower than this, the columns go one above the other.
    static let sideBySideWidth: CGFloat = 720

    let preview: PreviewContent?
    /// The app the image was copied from, when it is known.
    let applicationName: String?
    let column: TextColumn
    let ref: ContentRef
    /// Whether the text in the column is what the latest recognition just made.
    let isJustMade: Bool
    let onCommand: (QuickAccessCommand) -> Void
    /// Copies what the text's own Copy takes: the selection, or all of it.
    let onCopy: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the text has faded in beside the image: the one movement as the preview splits.
    @State private var showsText = false

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= Self.sideBySideWidth
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ImageColumn(preview: preview, applicationName: applicationName, isScanning: column.isScanning)
                Group {
                    ColumnDivider(vertical: sideBySide)
                    // A column of its own for each image: the text and its selection never carry over.
                    TextInImageColumn(column: column, pixelSize: preview?.pixelSize, isJustMade: isJustMade,
                                      onCommand: onCommand, onCopy: onCopy)
                        .id(ref)
                }
                .opacity(showsText || reduceMotion ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsText = true }
        }
    }
}

/// Why a recognition that just ended left the text column without new text, said to VoiceOver as it ends: there is
/// none in the image, or why it failed, and whether that left the text from before. The panel asks on every change it
/// sees, and not the column's view: SwiftUI doesn't always deliver a view's `onChange`. An ending is told by `ending`,
/// the latest recognition's while the column shows it. What the column says of an ending is said once, as it changes:
/// a new ending, or the same one in other words, as when text it made can't be kept. What the column shows as it
/// begins to show an image, as the panel opens or the selection comes to it, is only shown, even once it has read
/// what it needs; so is an ending that isn't the latest.
struct TextColumnEndings {
    /// The image the column shows, and the ending it showed as it began to show it.
    private var shown: (ref: ContentRef, ending: UUID?)?
    /// What the column last showed of the image once it had read what it needs: the ending and its words. Nil while it
    /// still reads, as it began to show the image.
    private var known: (ending: UUID?, words: String?)?
    /// The ending said last, and what was said of it.
    private var said: (ending: UUID, words: String)?

    /// The words for the column now shown, if any; it remembers what the column shows.
    mutating func words(for column: (ref: ContentRef, column: TextColumn, ending: UUID?)?, isOpen: Bool) -> String? {
        guard let column else {
            shown = nil
            known = nil
            return nil
        }
        let now = (ending: column.ending, words: Self.words(for: column.column))
        let isRead = column.column != .loading
        guard isOpen, let before = shown, before.ref == column.ref else {
            shown = (column.ref, column.ending)
            known = isRead ? now : nil
            return nil
        }
        guard isRead else { return nil }
        let was = known
        known = now
        // Read as the column began to show the image, an ending it had then is only shown.
        if was == nil, now.ending == before.ending { return nil }
        if let was, was == now { return nil }
        guard let ending = now.ending, let words = now.words,
              said?.ending != ending || said?.words != words else { return nil }
        said = (ending, words)
        return words
    }

    /// Forgets what the column showed and what was said, as the panel closes.
    mutating func reset() {
        shown = nil
        known = nil
        said = nil
    }

    private static func words(for column: TextColumn) -> String? {
        switch column {
        case .noText: TextColumnWords.noText
        case .failed(let error): error.message
        case .failedAgain(let kept, let error): TextColumnWords.failedAgain(leaving: kept, because: error)
        case .loading, .notStarted, .recognizing, .text, .unsaved: nil
        }
    }
}

/// The text column's own words, as the column and its subtitle say them.
enum TextColumnWords {
    static let title = "Text in Image"
    static let extract = "Extract Text"
    static let noText = "No text found in this image."
    static let notSaved = "The text couldn't be saved."
    static let tryAgain = "Try Again"
    static let unreadableImage = "This image couldn't be read."

    /// What the column says as recognizing an image again comes to nothing and leaves what it had, its text or that it
    /// had none: that the recognition failed, or, where the item became unavailable meanwhile, as when it went to
    /// Recently Deleted, that.
    static func failedAgain(leaving kept: TextColumn, because error: GenerationError) -> String {
        let what = error.kind == .contentUnavailable ? error.message : "Couldn't recognize the text again."
        switch kept {
        case .text, .unsaved: return what + " The earlier text is unchanged."
        case .loading, .notStarted, .recognizing, .noText, .failed, .failedAgain: return what
        }
    }

    static func subtitle(for column: TextColumn) -> String {
        switch column {
        case .recognizing(let snapshot) where snapshot.phase == .queued: "Waiting to recognize on this Mac…"
        case .recognizing: "Recognizing on this Mac…"
        case .text(let text, let keepsLineBreaks, _), .unsaved(let text, let keepsLineBreaks):
            "Recognized on this Mac, \(amount(of: text, keepingLineBreaks: keepsLineBreaks))"
        case .noText: "Recognized on this Mac"
        case .failedAgain(let kept, _): subtitle(for: kept)
        case .loading, .notStarted, .failed: "On this Mac"
        }
    }

    /// "Recognizing text in a 2,880 × 1,800 image…", or without the size when it isn't one an image could have.
    static func recognizing(pixelSize: CGSize?) -> String {
        guard let pixelSize, let width = wholePixels(pixelSize.width), let height = wholePixels(pixelSize.height) else {
            return "Recognizing text in the image…"
        }
        return "Recognizing text in a \(width.formatted()) × \(height.formatted()) image…"
    }

    /// "1 line", "5 lines", or with the lines joined, "1 paragraph", "3 paragraphs": the lines with text in them.
    static func amount(of text: String, keepingLineBreaks: Bool) -> String {
        let count = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        let noun = switch (keepingLineBreaks, count == 1) {
        case (true, true): "line"
        case (true, false): "lines"
        case (false, true): "paragraph"
        case (false, false): "paragraphs"
        }
        return "\(count.formatted()) \(noun)"
    }

    /// A side of an image in whole pixels, or nil where it is none an image could have.
    static func wholePixels(_ side: CGFloat) -> Int? {
        guard side.isFinite, side >= 1, side <= CGFloat(Int32.max) else { return nil }
        return Int(side.rounded())
    }
}

extension TextColumn {
    /// Recognition is waiting or under way: it can be stopped.
    var isRecognizing: Bool {
        if case .recognizing = self { return true }
        return false
    }

    /// Recognition is under way, not waiting for its turn.
    var isScanning: Bool {
        if case .recognizing(let snapshot) = self { return snapshot.phase != .queued }
        return false
    }

    /// The latest recognition failed, whether or not it left text from before: it can be tried again.
    var isFailed: Bool {
        switch self {
        case .failed, .failedAgain: true
        case .loading, .notStarted, .recognizing, .text, .unsaved, .noText: false
        }
    }
}

extension PreviewContent {
    /// The size of the whole picture, for an image.
    var pixelSize: CGSize? {
        if case .image(_, let pixelSize) = self { return pixelSize }
        return nil
    }
}

/// The image on the tray, under its title and where it came from. While its text is recognized, a thin line in the
/// accent colour passes down over it, and holds still with Reduce Motion. In place of an image that can't be shown, the
/// column says why.
private struct ImageColumn: View {
    let preview: PreviewContent?
    let applicationName: String?
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Image").font(.system(size: 12, weight: .bold))
            // Its line keeps its place, read by VoiceOver only when it says something.
            Text(subtitle ?? " ").font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityHidden(subtitle == nil)
            Group {
                if case .image(let image, _)? = preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay { if isScanning { ScanLine().clipShape(RoundedRectangle(cornerRadius: 8)) } }
                        .accessibilityLabel(applicationName.map { "Image, from \($0)" } ?? "Image")
                } else if case .failed(let refusal)? = preview {
                    message(refusal.message)
                } else if preview == nil {
                    ProgressView().controlSize(.small)
                } else {
                    message(TextColumnWords.unreadableImage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Why the image isn't shown, where it would be.
    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "From Preview, 2,880 × 1,800", or nil when neither is known.
    private var subtitle: String? {
        var parts: [String] = []
        if let applicationName { parts.append("From \(applicationName)") }
        if let size = preview?.pixelSize, let width = TextColumnWords.wholePixels(size.width),
           let height = TextColumnWords.wholePixels(size.height) {
            parts.append("\(width.formatted()) × \(height.formatted())")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The accent line that passes down over an image while its text is recognized.
private struct ScanLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            GeometryReader { geometry in
                let period = 1.6
                let phase = reduceMotion ? 1 / 3
                    : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: geometry.size.height * phase)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The line between the columns: 1 pt, white at 8 percent in dark mode, or with Increase Contrast at 25 percent.
private struct ColumnDivider: View {
    let vertical: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let strength = contrast == .increased ? 0.25 : 0.08
        let color = colorScheme == .dark ? Color.white.opacity(strength) : Color.black.opacity(strength * 0.75)
        Group {
            if vertical {
                color.frame(width: 1).padding(.top, 8).padding(.bottom, 20)
            } else {
                color.frame(height: 1).padding(.horizontal, 24)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The text recognized in the image, under its title and how it was made, or what stands for it: an offer to extract
/// it, the recognition under way, or why there is none. One display shows the text from the moment recognition starts
/// until it is made, so the text is typed out as it comes and VoiceOver hears the recognition start and end; text kept
/// from before, or brought back by stopping a recognition, shows at once. Why a recognition found no text, or none
/// could be made or kept, the panel says as it ends (`TextColumnEndings`). The column is the image's own: another image
/// has another column.
private struct TextInImageColumn: View {
    let column: TextColumn
    let pixelSize: CGSize?
    /// Whether what the column shows is how the latest recognition of its image just ended.
    let isJustMade: Bool
    let onCommand: (QuickAccessCommand) -> Void
    let onCopy: (String) -> Void
    /// Whether the recognition has run long enough to say what it is doing.
    @State private var saysWhatItDoes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TextColumnWords.title).font(.system(size: 12, weight: .bold))
            Text(TextColumnWords.subtitle(for: column)).font(.system(size: 11)).foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TextColumnWords.title), on this Mac")
        .accessibilityIdentifier("QuickAccessTextInImage")
        .task(id: column.isScanning) {
            saysWhatItDoes = false
            guard column.isScanning else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { saysWhatItDoes = true }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if saysWhatItDoes, case .recognizing(let snapshot) = column, !snapshot.hasText {
                Text(TextColumnWords.recognizing(pixelSize: pixelSize))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            // Recognizing again failed: what the column had stays, under why.
            if case .failedAgain(let kept, let error) = column {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TextColumnWords.failedAgain(leaving: kept, because: error))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error.message)
                    Button(TextColumnWords.tryAgain) { onCommand(.extractText) }
                        .buttonStyle(TrayCapsuleButtonStyle())
                        .help("\(TextColumnWords.tryAgain) (⇧⌘T)")
                }
            }
            // The one display, in the same place while the recognition runs and once its text is made.
            if let shown {
                StreamingTextView(text: shown.text, mode: shown.mode,
                                  announcements: .init(start: "Recognizing text", finish: "Text recognized"),
                                  allowsCopyingAll: shown.mode != .writing && shown.isWhole,
                                  onCopy: { [onCopy] in onCopy($0) },
                                  onKeyDown: { [onCommand] event in
                                      PreviewTextKeys.handle(event, hasMarkedText: false, onCommand: onCommand)
                                  })
            }
            switch column {
            case .loading:
                ProgressView().controlSize(.small)
            case .notStarted:
                Button { onCommand(.extractText) } label: {
                    HStack(spacing: 8) {
                        Text(TextColumnWords.extract)
                        ReviewKeycap(symbol: "⇧⌘T")
                    }
                }
                .buttonStyle(TrayCapsuleButtonStyle())
                .accessibilityLabel(TextColumnWords.extract)
                .accessibilityIdentifier("QuickAccessExtractText")
                .help("\(TextColumnWords.extract) (⇧⌘T)")
            case .unsaved, .failedAgain(.unsaved, _):
                Text(TextColumnWords.notSaved).font(.system(size: 11)).foregroundStyle(.secondary)
            case .noText, .failedAgain(.noText, _):
                Text(TextColumnWords.noText).font(.system(size: 14)).foregroundStyle(.secondary)
            case .failed(let error):
                Text(error.message).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The column shows only for an image listed now, so it may have come back since.
                Button(TextColumnWords.tryAgain) { onCommand(.extractText) }
                    .buttonStyle(TrayCapsuleButtonStyle())
                    .help("\(TextColumnWords.tryAgain) (⇧⌘T)")
            case .recognizing, .text, .failedAgain:
                EmptyView()
            }
        }
    }

    /// The text the display shows, how: typed out while it is made, then finished, or at once, and whether it is whole,
    /// so that copying it all, with nothing selected, takes it. Part of a text is copied by selecting it.
    private var shown: (text: String, mode: StreamingTextDisplay.Mode, isWhole: Bool)? {
        switch column {
        case .recognizing(let snapshot):
            let mode = StreamingTextDisplay.Mode(snapshot.phase)
            // A recognition that found nothing has nothing to finish; why there is no text is said instead.
            return (snapshot.text(), mode == .finishing && !snapshot.hasText ? .still : mode,
                    snapshot.phase == .finished(.completed))
        case .text(let text, _, let status):
            return (text, isJustMade ? .finishing : .still, status == .complete)
        case .unsaved(let text, _):
            // Recognition on this Mac ends whole or not at all.
            return (text, isJustMade ? .finishing : .still, true)
        // What a failed recognition left, as it was: not typed out again.
        case .failedAgain(.text(let text, _, let status), _):
            return (text, .still, status == .complete)
        case .failedAgain(.unsaved(let text, _), _):
            return (text, .still, true)
        case .loading, .notStarted, .noText, .failed, .failedAgain:
            return nil
        }
    }
}

/// A capsule on the tray, in the toolbar's colours: the column's Extract Text and Try Again, and the bar's own.
struct TrayCapsuleButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(nsColor: isOn ? ToolbarPalette.chosenFilterText : ToolbarPalette.glyph))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(nsColor: fill(pressed: configuration.isPressed)), in: Capsule())
            .contentShape(Capsule())
    }

    private func fill(pressed: Bool) -> NSColor {
        if pressed { return ToolbarPalette.pressedFill }
        return isOn ? ToolbarPalette.chosenFilterFill : ToolbarPalette.foldedSearchFill
    }
}

/// A round button on the tray, as the preview's close button: the bar's Copy and Save as Snippet.
struct TrayRoundButton: View {
    let symbol: String
    let label: String
    let help: String
    let identifier: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: ToolbarPalette.glyph))
                .frame(width: QuickAccessSearchControl.foldedWidth, height: QuickAccessSearchControl.foldedWidth)
                .background(Color(nsColor: ToolbarPalette.foldedSearchFill), in: Circle())
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .help(help)
    }
}

/// Segments on the tray, as the band's All | Snippets: Preview, and Text for an image.
struct TraySegments: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let isChosen: Bool
        var isEnabled = true
        /// The segment's help tag, with its key.
        var help: String?
        let action: () -> Void
    }

    let segments: [Segment]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                Button(action: segment.action) {
                    Text(segment.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: segment.isChosen ? ToolbarPalette.chosenFilterText
                                                                        : ToolbarPalette.secondary))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if segment.isChosen {
                                Capsule().fill(Color(nsColor: ToolbarPalette.chosenSegmentFill))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!segment.isEnabled)
                .opacity(segment.isEnabled ? 1 : 0.5)
                .help(segment.help ?? "")
                .accessibilityAddTraits(segment.isChosen ? .isSelected : [])
                .accessibilityIdentifier("QuickAccessPreviewSegment.\(segment.id)")
            }
        }
        .padding(2)
        .background(Color(nsColor: ToolbarPalette.segmentsFill), in: Capsule())
    }
}
