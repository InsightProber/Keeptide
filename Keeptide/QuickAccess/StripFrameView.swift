import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small mark in the top right corner of a frame.
enum StripMarker: Equatable {
    case savedAsMemo, partiallyIndexed
}

/// What one frame of the strip shows, decided apart from the drawing so that it can be tested.
struct StripFrameContent: Equatable {
    enum Body: Equatable {
        case text(AttributedString, size: CGFloat)
        case link(host: String, rest: String)
        case image(CGImage, fills: Bool)
        case file(name: String, typeIdentifier: String?)
        /// The kind's symbol and the clip's title. It stands in until the details arrive (a text search
        /// result shows its snippet at once instead) and for a clip whose details hold nothing to draw.
        case placeholder(symbol: String, title: String)
    }

    /// A saved memo's own title, when its body does not already begin with it.
    var memoTitle: String?
    var body: Body
    /// The caption at the frame's bottom edge.
    var info: String?
    /// How many more items than the shown one the clip holds.
    var extraItems: Int
    var markers: [StripMarker]
    var isTextUnavailable: Bool
    /// Width over height of a picture, from its header. ImageIO rounds the thumbnail's size, which
    /// for a hairline of a picture makes a very different shape, so a picture shown whole takes its
    /// shape from here and not from the thumbnail.
    var imageAspectRatio: CGFloat?

    /// `detail` is nil until the details have arrived, and when they could not be read. A text search
    /// result already has its snippet, so it shows it without them and only its caption waits.
    static func make(row: QuickAccessRow, detail: ClipDetail?, density: StripDensity) -> StripFrameContent {
        var content = StripFrameContent(
            body: .placeholder(symbol: row.kind.symbolName, title: row.displayTitle),
            extraItems: 0, markers: [], isTextUnavailable: row.isTextUnavailable
        )
        if row.savedAsMemo { content.markers.append(.savedAsMemo) }
        if row.isPartiallyIndexed { content.markers.append(.partiallyIndexed) }
        guard let detail else {
            content.showSnippet(of: row, density: density)
            return content
        }

        content.extraItems = max(0, detail.itemCount - 1)
        content.info = info(for: row.kind, detail: detail)
        switch row.kind {
        case .text:
            if !content.showSnippet(of: row, density: density), let excerpt = detail.excerpt, !excerpt.isEmpty {
                content.setText(AttributedString(excerpt), plain: excerpt, for: row, density: density)
            }
        case .url:
            guard let address = detail.excerpt, !address.isEmpty else { break }
            if let (host, rest) = split(link: address) {
                content.body = .link(host: host, rest: rest)
                content.memoTitle = memoTitle(of: row, over: address)
            } else {
                content.setText(AttributedString(address), plain: address, for: row, density: density)
            }
        case .image:
            if let thumbnail = detail.thumbnail {
                content.body = .image(thumbnail, fills: detail.fillsFrame)
                if let size = detail.pixelSize, size.width > 0, size.height > 0 {
                    content.imageAspectRatio = size.width / size.height
                }
            }
        case .file:
            if let name = detail.fileNames.first {
                let pathExtension = (name as NSString).pathExtension
                let type = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
                content.body = .file(name: name, typeIdentifier: type?.identifier)
            } else {
                content.body = .file(name: row.displayTitle, typeIdentifier: nil)
            }
        case .other:
            break
        }
        return content
    }

    /// The text of the caption: a picture's size, a text's or link's length, what a file clip holds, or
    /// how many items several are. Several items that are not files read as items whatever they are.
    private static func info(for kind: ContentKind, detail: ClipDetail) -> String? {
        if kind == .file {
            // A file whose name could not be read is still a file, so the names are made up to the items.
            let unreadable = Array(repeating: "", count: max(0, detail.itemCount - detail.fileNames.count))
            return ClipInfoFormatter.files(detail.fileNames + unreadable)
        }
        if detail.itemCount > 1 { return ClipInfoFormatter.items(detail.itemCount) }
        switch kind {
        case .image: return detail.pixelSize.map(ClipInfoFormatter.pixels)
        case .text, .url: return detail.characterCount.map { ClipInfoFormatter.characters($0) }
        case .file, .other: return nil
        }
    }

    /// Shows the snippet a text search result brings along, with its hits in bold. Only a text frame
    /// does that; the other kinds look as they do for a recent clip. Returns whether there was one.
    @discardableResult
    private mutating func showSnippet(of row: QuickAccessRow, density: StripDensity) -> Bool {
        guard row.kind == .text, let snippet = row.snippet, !snippet.text.isEmpty else { return false }
        setText(QuickAccessRowContent.highlighted(snippet), plain: snippet.text, for: row, density: density)
        return true
    }

    /// Sets a text body at the size its length gives. Under a memo title it goes no larger than the
    /// size after the title's, so that the title stands out.
    private mutating func setText(_ text: AttributedString, plain: String, for row: QuickAccessRow, density: StripDensity) {
        var size = StripTypography.bodySize(for: plain, density: density)
        if let title = Self.memoTitle(of: row, over: plain) {
            memoTitle = title
            size = min(size, Self.nextSize(after: StripTypography.bodySize(for: title, density: density), density: density))
        }
        body = .text(text, size: size)
    }

    /// A memo's title earns a line of its own only when the body does not begin with it.
    private static func memoTitle(of row: QuickAccessRow, over body: String) -> String? {
        row.savedAsMemo && !row.title.isEmpty && !body.hasPrefix(row.title) ? row.title : nil
    }

    /// The next size down the table, or the same size at its end.
    private static func nextSize(after size: CGFloat, density: StripDensity) -> CGFloat {
        let tiers = StripTypography.type(for: density).tiers
        guard let index = tiers.firstIndex(of: size) else { return size }
        return tiers[min(index + 1, tiers.count - 1)]
    }

    /// The host, and everything after it as written: port, path, query and fragment. Nil when the text
    /// has no host to split off.
    private static func split(link text: String) -> (host: String, rest: String)? {
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        var rest = components.port.map { ":\($0)" } ?? ""
        rest += components.percentEncodedPath
        if let query = components.percentEncodedQuery { rest += "?" + query }
        if let fragment = components.percentEncodedFragment { rest += "#" + fragment }
        return (host, rest)
    }
}

extension ContentKind {
    /// The word VoiceOver says for a frame.
    var accessibilityName: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .image: "Image"
        case .file: "File"
        case .other: "Clip"
        }
    }
}

/// One frame of the strip: an opaque sheet showing the clip itself, with a caption in its bottom edge.
/// It fills the size it is given. A selected frame's ring is drawn outside that size, 3 pt from its
/// edge and 2 pt wide (3 pt with Increase Contrast), so whatever hosts the frame must not clip it.
struct StripFrameView: View {
    let content: StripFrameContent
    let applicationIcon: NSImage
    let density: StripDensity
    let isSelected: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    private static let selectionGap: CGFloat = 3
    /// The black behind a picture's caption and corner marks. White text on it keeps a contrast of
    /// 6:1 even over a white picture, where 4.5:1 is the least that is asked.
    private static let scrim = Color.black.opacity(0.62)

    private var type: StripType { StripTypography.type(for: density) }

    var body: some View {
        GeometryReader { proxy in
            card(in: proxy.size)
        }
    }

    private func card(in size: CGSize) -> some View {
        let radius = cornerRadius(forWidth: size.width)
        return ZStack {
            Color(nsColor: .textBackgroundColor)
            if case .image(let image, true) = content.body {
                filledImage(image, in: size)
            } else {
                paperLayout
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { selectionRing(radius: radius) }
    }

    /// 12 pt at the full size, smaller with the frame but never under 8 pt, as `StripLayout` sets it.
    private func cornerRadius(forWidth width: CGFloat) -> CGFloat {
        let full = StripLayout.metrics(for: density, visibleWidth: StripLayout.maximumBandWidth + 2 * StripLayout.sideMargin)
        return max(8, 12 * min(1, width / full.frameSize.width))
    }

    // MARK: Layouts

    /// The body on the paper, with the marks beside or above it and the caption below.
    private var paperLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch content.body {
            case .file, .image:
                // These sit in the middle, so the marks get a row of their own above them.
                VStack(alignment: .trailing, spacing: 2) {
                    if hasCornerMarks { cornerMarks(onImage: false) }
                    bodyRegion
                }
            case .text, .link, .placeholder:
                // These start in the corner, so the marks take a column beside them.
                HStack(alignment: .top, spacing: 6) {
                    bodyRegion
                    if hasCornerMarks { cornerMarks(onImage: false) }
                }
            }
            caption(onImage: false)
        }
        .padding(type.padding)
    }

    /// Takes all the room the marks and the caption leave. What does not fit is cut off.
    private var bodyRegion: some View {
        GeometryReader { region in
            bodyContent(in: region.size)
                .frame(width: region.size.width, height: region.size.height, alignment: .topLeading)
                .clipped()
        }
    }

    /// A picture covering the whole frame, with a dark fade at the bottom behind the caption.
    private func filledImage(_ image: CGImage, in size: CGSize) -> some View {
        let captionHeight = max(type.icon, type.info * 1.25)
        let fade: CGFloat = 20
        let scrimHeight = type.padding + captionHeight + fade
        return ZStack(alignment: .bottom) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
            // Fully dense from the top of the caption down, so white text reads over any picture.
            LinearGradient(stops: [
                .init(color: Self.scrim.opacity(0), location: 0),
                .init(color: Self.scrim, location: fade / scrimHeight),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: scrimHeight)
            caption(onImage: true).padding(type.padding)
        }
        .overlay(alignment: .topTrailing) {
            if hasCornerMarks { cornerMarks(onImage: true).padding(type.padding) }
        }
    }

    // MARK: Body

    @ViewBuilder
    private func bodyContent(in region: CGSize) -> some View {
        if showsUnavailableText {
            VStack(alignment: .leading, spacing: 2) {
                memoTitleLine
                Text("Text unavailable")
                    .font(.system(size: type.tiers[3]))
                    .lineHeight(.exact(points: lineHeight(of: type.tiers[3])))
                    .foregroundStyle(secondaryTextStyle())
            }
        } else {
            switch content.body {
            case .text(let text, let size): textBody(text, size: size, in: region)
            case .link(let host, let rest): linkBody(host: host, rest: rest, in: region)
            case .image(let image, _): wholeImage(image)
            case .file(let name, let typeIdentifier): fileBody(name: name, typeIdentifier: typeIdentifier)
            case .placeholder(let symbol, let title): placeholderBody(symbol: symbol, title: title, in: region)
            }
        }
    }

    /// The text of a clip whose text is gone is replaced by the notice; a picture or a file, which
    /// does not rest on text, is shown as usual.
    private var showsUnavailableText: Bool {
        guard content.isTextUnavailable else { return false }
        switch content.body {
        case .text, .link, .placeholder: return true
        case .image, .file: return false
        }
    }

    private func textBody(_ text: AttributedString, size: CGFloat, in region: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            memoTitleLine
            Text(text)
                .font(.system(size: size))
                .lineHeight(.exact(points: lineHeight(of: size)))
                .lineLimit(max(1, lines(in: region.height - memoTitleHeight, size: size)))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkBody(host: String, rest: String, in region: CGSize) -> some View {
        let used = memoTitleHeight + lineHeight(of: type.linkDomain).rounded(.up) + 2
        let pathLines = lines(in: region.height - used, size: type.linkPath)
        return VStack(alignment: .leading, spacing: 2) {
            memoTitleLine
            Text(host)
                .font(.system(size: type.linkDomain, weight: .semibold))
                .lineHeight(.exact(points: lineHeight(of: type.linkDomain)))
                .lineLimit(1)
                .truncationMode(.middle)
            if !rest.isEmpty, pathLines > 0 {
                Text(rest)
                    .font(.system(size: type.linkPath))
                    .foregroundStyle(secondaryTextStyle())
                    .lineHeight(.exact(points: lineHeight(of: type.linkPath)))
                    .lineLimit(pathLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A picture that is too wide or too tall to cover the frame sits whole on the paper above the caption.
    private func wholeImage(_ image: CGImage) -> some View {
        let aspect = content.imageAspectRatio ?? CGFloat(image.width) / CGFloat(max(image.height, 1))
        return Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileBody(name: String, typeIdentifier: String?) -> some View {
        let side: CGFloat = switch density {
        case .seven: 40
        case .nine: 32
        case .eleven: 28
        }
        let icon = NSWorkspace.shared.icon(for: typeIdentifier.flatMap { UTType($0) } ?? .data)
        return HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: side, height: side)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: type.tiers[2]))
                .lineHeight(.exact(points: lineHeight(of: type.tiers[2])))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func placeholderBody(symbol: String, title: String, in region: CGSize) -> some View {
        let size = type.tiers[2]
        // A symbol is about 1.3 times its point size tall; the title gets what is left under it.
        let used = type.tiers[1] * 1.3 + 4
        return VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: type.tiers[1]))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: size))
                .lineHeight(.exact(points: lineHeight(of: size)))
                .lineLimit(max(1, lines(in: region.height - used, size: size)))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Memo title and line fitting

    private var memoTitleSize: CGFloat? {
        content.memoTitle.map { StripTypography.bodySize(for: $0, density: density) }
    }

    /// Room the memo title takes above the body, with the gap under it.
    private var memoTitleHeight: CGFloat {
        memoTitleSize.map { lineHeight(of: $0).rounded(.up) + 2 } ?? 0
    }

    @ViewBuilder
    private var memoTitleLine: some View {
        if let title = content.memoTitle, let size = memoTitleSize {
            Text(title)
                .font(.system(size: size, weight: .semibold))
                .lineHeight(.exact(points: lineHeight(of: size)))
                .lineLimit(1)
        }
    }

    /// Lines are set 1.4 times the font size apart.
    private func lineHeight(of size: CGFloat) -> CGFloat {
        size * 1.4
    }

    /// How many lines of `size` fit in `height`, none when not even one does. Text is cut at the
    /// frame's edge and never set smaller.
    private func lines(in height: CGFloat, size: CGFloat) -> Int {
        max(0, Int((height / lineHeight(of: size)).rounded(.down)))
    }

    // MARK: Caption and corner marks

    private var increasedContrast: Bool { contrast == .increased }

    /// The source app's icon on the left and the info on the right.
    private func caption(onImage: Bool) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: applicationIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: type.icon, height: type.icon)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            if let info = content.info {
                Text(info)
                    .font(.system(size: type.info))
                    .lineLimit(1)
                    .foregroundStyle(secondaryTextStyle(onImage: onImage))
            }
        }
    }

    private var hasCornerMarks: Bool { content.extraItems > 0 || !content.markers.isEmpty }

    private func cornerMarks(onImage: Bool) -> some View {
        HStack(spacing: 4) {
            if content.extraItems > 0 {
                Text("+\(content.extraItems)")
                    .font(.system(size: type.info, weight: .medium))
                    .foregroundStyle(secondaryTextStyle(onImage: onImage))
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(onImage ? Self.scrim : Color(nsColor: .quaternaryLabelColor)))
                    .accessibilityHidden(true)
            }
            ForEach(Array(content.markers.enumerated()), id: \.offset) { _, marker in
                markerGlyph(marker, onImage: onImage)
            }
        }
    }

    private func markerGlyph(_ marker: StripMarker, onImage: Bool) -> some View {
        let (symbol, name): (String, String) = switch marker {
        case .savedAsMemo: ("bookmark.fill", "Saved as Memo")
        case .partiallyIndexed: ("circle.lefthalf.filled", "Partially indexed")
        }
        return Image(systemName: symbol)
            .font(.system(size: type.info))
            .foregroundStyle(symbolStyle(onImage: onImage))
            .padding(onImage ? 4 : 0)
            .background(Circle().fill(onImage ? Self.scrim : Color.clear))
            .help(name)
            .accessibilityLabel(name)
    }

    /// Text that is not a frame's main text: the caption, a link's path, the count and the notice. On
    /// paper it is the primary color at 70 percent, which keeps text at 4.5:1 or better where the
    /// system's secondary color does not (3.95:1 on light paper); with Increase Contrast it is the
    /// primary color in full. On a picture it is white, on the dark fade.
    private func secondaryTextStyle(onImage: Bool = false) -> AnyShapeStyle {
        if onImage { return AnyShapeStyle(.white) }
        return increasedContrast ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.7))
    }

    /// Symbols need 3:1 and not 4.5:1, so they keep the system's secondary color on paper, or the
    /// primary color with Increase Contrast. White on a picture.
    private func symbolStyle(onImage: Bool) -> AnyShapeStyle {
        if onImage { return AnyShapeStyle(.white) }
        return increasedContrast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    // MARK: Selection

    /// An accent ring outside the frame: 2 pt wide, 3 pt from the edge; 3 pt wide with Increase Contrast.
    @ViewBuilder
    private func selectionRing(radius: CGFloat) -> some View {
        if isSelected {
            let width: CGFloat = increasedContrast ? 3 : 2
            let offset = Self.selectionGap + width / 2
            RoundedRectangle(cornerRadius: radius + offset, style: .continuous)
                .stroke(Color.accentColor, lineWidth: width)
                .padding(-offset)
                .allowsHitTesting(false)
        }
    }
}
