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
                                      onCommand: onCommand)
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

/// Why a recognition that just ended left the text column without text, said to VoiceOver as it ends: there is none in
/// the image, or why it failed. The panel asks on every change it sees, and not the column's view: SwiftUI doesn't
/// always deliver a view's `onChange`. Each ending is said once, as the column changes to it for the same image; an
/// ending shown for another image, as the panel opens, or that isn't the latest recognition's, says nothing.
struct TextColumnEndings {
    /// The column as it was last shown.
    private var shown: (ref: ContentRef, column: TextColumn)?

    /// The words for the column now shown, if any, given the column shown before; it remembers this one.
    mutating func words(for column: (ref: ContentRef, column: TextColumn)?, isJustMade: Bool,
                        isOpen: Bool) -> String? {
        let before = shown
        shown = column
        guard isOpen, isJustMade, let column, let before, before.ref == column.ref,
              before.column != column.column else { return nil }
        switch column.column {
        case .noText: return TextColumnWords.noText
        case .failed(let error): return error.message
        case .loading, .notStarted, .recognizing, .text, .unsaved: return nil
        }
    }

    /// Forgets the column shown before, as the panel closes.
    mutating func reset() {
        shown = nil
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

    static func subtitle(for column: TextColumn) -> String {
        switch column {
        case .recognizing(let snapshot) where snapshot.phase == .queued: "Waiting to recognize on this Mac…"
        case .recognizing: "Recognizing on this Mac…"
        case .text(let text, let keepsLineBreaks, _), .unsaved(let text, let keepsLineBreaks):
            "Recognized on this Mac, \(amount(of: text, keepingLineBreaks: keepsLineBreaks))"
        case .noText: "Recognized on this Mac"
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
            // The one display, in the same place while the recognition runs and once its text is made.
            if let shown {
                StreamingTextView(text: shown.text, mode: shown.mode,
                                  announcements: .init(start: "Recognizing text", finish: "Text recognized"),
                                  allowsCopyingAll: shown.mode != .writing,
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
            case .unsaved:
                Text(TextColumnWords.notSaved).font(.system(size: 11)).foregroundStyle(.secondary)
            case .noText:
                Text(TextColumnWords.noText).font(.system(size: 14)).foregroundStyle(.secondary)
            case .failed(let error):
                Text(error.message).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The column shows only for an image listed now, so it may have come back since.
                Button(TextColumnWords.tryAgain) { onCommand(.extractText) }
                    .buttonStyle(TrayCapsuleButtonStyle())
                    .help("\(TextColumnWords.tryAgain) (⇧⌘T)")
            case .recognizing, .text:
                EmptyView()
            }
        }
    }

    /// The text the display shows, and how: typed out while it is made, then finished, or at once.
    private var shown: (text: String, mode: StreamingTextDisplay.Mode)? {
        switch column {
        case .recognizing(let snapshot):
            let mode = StreamingTextDisplay.Mode(snapshot.phase)
            // A recognition that found nothing has nothing to finish; why there is no text is said instead.
            return (snapshot.text(), mode == .finishing && !snapshot.hasText ? .still : mode)
        case .text(let text, _, _), .unsaved(let text, _):
            return (text, isJustMade ? .finishing : .still)
        case .loading, .notStarted, .noText, .failed:
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
