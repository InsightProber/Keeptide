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
    let onCommand: (QuickAccessCommand) -> Void

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= Self.sideBySideWidth
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ImageColumn(preview: preview, applicationName: applicationName,
                            isRecognizing: column.isRecognizing)
                ColumnDivider(vertical: sideBySide)
                TextInImageColumn(column: column, ref: ref, pixelSize: preview?.pixelSize, onCommand: onCommand)
            }
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

    static func subtitle(for column: TextColumn) -> String {
        switch column {
        case .recognizing: "Recognizing on this Mac…"
        case .text(let text, _), .unsaved(let text): "Recognized on this Mac, \(lines(in: text))"
        case .noText: "Recognized on this Mac"
        case .loading, .notStarted, .failed: "On this Mac"
        }
    }

    /// "Recognizing text in a 2,880 × 1,800 image…", or without the size when it isn't known.
    static func recognizing(pixelSize: CGSize?) -> String {
        guard let pixelSize, pixelSize.width >= 1, pixelSize.height >= 1 else { return "Recognizing text in the image…" }
        return "Recognizing text in a \(Int(pixelSize.width).formatted()) × \(Int(pixelSize.height).formatted()) image…"
    }

    /// "1 line", "5 lines": the lines with text in them.
    static func lines(in text: String) -> String {
        let count = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
        return count == 1 ? "1 line" : "\(count.formatted()) lines"
    }
}

extension TextColumn {
    var isRecognizing: Bool {
        if case .recognizing = self { return true }
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
/// accent colour passes down over it, and holds still with Reduce Motion.
private struct ImageColumn: View {
    let preview: PreviewContent?
    let applicationName: String?
    let isRecognizing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Image").font(.system(size: 12, weight: .bold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            Group {
                if case .image(let image, _)? = preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay { if isRecognizing { ScanLine().clipShape(RoundedRectangle(cornerRadius: 8)) } }
                        .accessibilityLabel(applicationName.map { "Image, from \($0)" } ?? "Image")
                } else {
                    ProgressView().controlSize(.small)
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

    /// "From Preview, 2,880 × 1,800".
    private var subtitle: String {
        var parts: [String] = []
        if let applicationName { parts.append("From \(applicationName)") }
        if let size = preview?.pixelSize, size.width >= 1, size.height >= 1 {
            parts.append("\(Int(size.width).formatted()) × \(Int(size.height).formatted())")
        }
        return parts.isEmpty ? " " : parts.joined(separator: ", ")
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
/// it, the recognition under way, or why there is none.
private struct TextInImageColumn: View {
    let column: TextColumn
    let ref: ContentRef
    let pixelSize: CGSize?
    let onCommand: (QuickAccessCommand) -> Void
    /// The image whose text this column watched being recognized: its text is typed out once, and text kept from
    /// before shows whole.
    @State private var watched: ContentRef?
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
        .onChange(of: column, initial: true) { old, column in
            if column.isRecognizing { watched = ref }
            // VoiceOver hears why there is no text, as it comes; the text itself announces its start and end.
            guard old != column else { return }
            switch column {
            case .noText: AccessibilityNotification.Announcement(TextColumnWords.noText).post()
            case .failed(let error): AccessibilityNotification.Announcement(error.message).post()
            default: break
            }
        }
        .task(id: column.isRecognizing ? ref : nil) {
            saysWhatItDoes = false
            guard column.isRecognizing else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { saysWhatItDoes = true }
        }
    }

    @ViewBuilder private var content: some View {
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
        case .recognizing(let snapshot):
            VStack(alignment: .leading, spacing: 8) {
                if saysWhatItDoes, !snapshot.hasText {
                    Text(TextColumnWords.recognizing(pixelSize: pixelSize))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                text(snapshot.text(), mode: .writing)
            }
        case .text(let made, _):
            text(made, mode: watched == ref ? .finishing : .still)
        case .unsaved(let made):
            VStack(alignment: .leading, spacing: 8) {
                text(made, mode: .still)
                Text(TextColumnWords.notSaved).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .noText:
            Text(TextColumnWords.noText).font(.system(size: 14)).foregroundStyle(.secondary)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 12) {
                Text(error.message).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if error.kind != .contentUnavailable {
                    Button(TextColumnWords.tryAgain) { onCommand(.extractText) }
                        .buttonStyle(TrayCapsuleButtonStyle())
                }
            }
        }
    }

    private func text(_ text: String, mode: StreamingTextDisplay.Mode) -> some View {
        StreamingTextView(text: text, mode: mode,
                          announcements: .init(start: "Recognizing text", finish: "Text recognized"),
                          allowsCopyingAll: mode != .writing)
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
                .accessibilityAddTraits(segment.isChosen ? .isSelected : [])
                .accessibilityIdentifier("QuickAccessPreviewSegment.\(segment.id)")
            }
        }
        .padding(2)
        .background(Color(nsColor: ToolbarPalette.segmentsFill), in: Capsule())
    }
}
