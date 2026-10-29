import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small mark after a card's time.
enum StripMarker: Equatable {
    case savedAsMemo, partiallyIndexed
}

/// One piece of the line under a card's kind, in the colour band.
enum StripHeaderItem: Equatable {
    case time(String)
    case marker(StripMarker)
    /// How many more items than the shown one the clip holds.
    case extraItems(Int)
}

/// What one card of the strip shows, decided apart from the drawing so that it can be tested.
struct StripFrameContent: Equatable {
    enum Body: Equatable {
        /// Text at the style its length gives. A search's hits are in bold.
        case text(AttributedString, style: StripTextStyle)
        /// A link by its title: a saved link's own title, the title of the page it was copied from, or else its
        /// decoded path. A search's hits are in bold.
        case link(title: AttributedString)
        case image(CGImage, fills: Bool)
        case file(name: String, typeIdentifier: String?)
        /// The kind's symbol and the clip's title. It stands in until the details arrive (a text search
        /// result shows its snippet at once instead) and for a clip whose details hold nothing to draw.
        case placeholder(symbol: String, title: String)
    }

    /// What the colour band names the clip.
    var kind: ContentKind
    /// How long ago the clip was copied, as the colour band says it.
    var time: String
    /// The app the clip came from. Its icon gives the colour band its colour.
    var sourceApp: String?
    /// What VoiceOver names the clip by, after the band and the footer: the title a link's card shows, and the clip's
    /// own title for everything else.
    var accessibilityTitle: String
    /// A saved memo's own title, shown above its body when the body does not already begin with it, and above the
    /// notice that stands in for a body whose text is gone.
    var memoTitle: String?
    var body: Body
    /// The line in the card's footer: a text's length, a picture's size, a link's host, or what a file clip holds.
    var info: String?
    /// How many more items than the shown one the clip holds.
    var extraItems: Int
    var markers: [StripMarker]
    var isTextUnavailable: Bool
    /// Width over height of a picture, from its header. ImageIO rounds the thumbnail's size, which
    /// for a hairline of a picture makes a very different shape, so a picture shown whole takes its
    /// shape from here and not from the thumbnail.
    var imageAspectRatio: CGFloat?

    /// The colour band's second line, left to right: the time, the marks, and how many more items there are.
    var headerLine: [StripHeaderItem] {
        [.time(time)] + markers.map(StripHeaderItem.marker) + (extraItems > 0 ? [.extraItems(extraItems)] : [])
    }

    /// `detail` is nil until the details have arrived, and when they could not be read. A text search
    /// result already has its snippet, so it shows it without them and only its caption waits. `now` is the
    /// moment the time is told from.
    static func make(row: QuickAccessRow, detail: ClipDetail?, cardSize: CardSize,
                     now: Date = Date()) -> StripFrameContent {
        var content = StripFrameContent(
            kind: row.kind, time: QuickAccessRowContent.time(of: row.date, relativeTo: now), sourceApp: row.sourceApp,
            accessibilityTitle: row.displayTitle,
            body: .placeholder(symbol: row.kind.symbolName, title: row.displayTitle),
            extraItems: 0, markers: [], isTextUnavailable: row.isTextUnavailable
        )
        if row.savedAsMemo { content.markers.append(.savedAsMemo) }
        if row.isPartiallyIndexed { content.markers.append(.partiallyIndexed) }
        if let detail {
            content.show(detail, of: row, cardSize: cardSize)
        } else {
            content.showSnippet(of: row, cardSize: cardSize)
        }
        // A memo whose text is gone keeps its own title, above the notice that stands in for the text.
        if row.isTextUnavailable, row.savedAsMemo, !row.title.isEmpty { content.memoTitle = row.title }
        return content
    }

    /// Fills in what the details tell: the footer, how many more items there are, and the clip itself.
    private mutating func show(_ detail: ClipDetail, of row: QuickAccessRow, cardSize: CardSize) {
        extraItems = max(0, detail.itemCount - 1)
        info = Self.info(for: row.kind, detail: detail)
        switch row.kind {
        case .text:
            if !showSnippet(of: row, cardSize: cardSize), let excerpt = detail.excerpt, !excerpt.isEmpty {
                setText(AttributedString(excerpt), plain: excerpt, for: row, cardSize: cardSize)
            }
        case .url:
            guard let address = detail.excerpt, !address.isEmpty else { break }
            if let (host, rest) = Self.split(link: address) {
                let pageTitle = detail.linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = Self.memoTitle(of: row, over: address)
                    ?? pageTitle.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (rest.isEmpty ? host : rest)
                body = .link(title: Self.highlighted(title, like: row.snippet))
                accessibilityTitle = title
            } else {
                setText(AttributedString(address), plain: address, for: row, cardSize: cardSize)
            }
        case .image:
            if let thumbnail = detail.thumbnail {
                body = .image(thumbnail, fills: detail.fillsFrame)
                if let size = detail.pixelSize, size.width > 0, size.height > 0 {
                    imageAspectRatio = size.width / size.height
                }
            }
        case .file:
            if let name = detail.fileNames.first {
                let pathExtension = (name as NSString).pathExtension
                let type = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
                body = .file(name: name, typeIdentifier: type?.identifier)
            } else {
                body = .file(name: row.displayTitle, typeIdentifier: nil)
            }
        case .other:
            break
        }
    }

    /// The text of the footer: a picture's size, a text's length, a link's host (or its length when it has no
    /// host), what a file clip holds, or how many items several are. Several items that are not files read as items
    /// whatever they are.
    private static func info(for kind: ContentKind, detail: ClipDetail) -> String? {
        if kind == .file {
            // A file whose name could not be read is still a file, so the names are made up to the items.
            let unreadable = Array(repeating: "", count: max(0, detail.itemCount - detail.fileNames.count))
            return ClipInfoFormatter.files(detail.fileNames + unreadable)
        }
        if detail.itemCount > 1 { return ClipInfoFormatter.items(detail.itemCount) }
        switch kind {
        case .image: return detail.pixelSize.map(ClipInfoFormatter.pixels)
        case .url:
            if let host = detail.excerpt.flatMap(split(link:))?.host { return host }
            return detail.characterCount.map { ClipInfoFormatter.characters($0) }
        case .text: return detail.characterCount.map { ClipInfoFormatter.characters($0) }
        case .file, .other: return nil
        }
    }

    /// Shows the snippet a text search result brings along, with its hits in bold. Only a text card
    /// does that; a link marks the hits in its title instead, and the other kinds look as they do for a
    /// recent clip. Returns whether there was one.
    @discardableResult
    private mutating func showSnippet(of row: QuickAccessRow, cardSize: CardSize) -> Bool {
        guard row.kind == .text, let snippet = row.snippet, !snippet.text.isEmpty else { return false }
        setText(QuickAccessRowContent.highlighted(snippet), plain: snippet.text, for: row, cardSize: cardSize)
        return true
    }

    /// Sets a text body at the style its length gives, with the memo title above it when it has one.
    private mutating func setText(_ text: AttributedString, plain: String, for row: QuickAccessRow,
                                  cardSize: CardSize) {
        memoTitle = Self.memoTitle(of: row, over: plain)
        body = .text(text, style: StripTypography.bodyStyle(for: plain, cardSize: cardSize))
    }

    /// A memo's title earns a line of its own only when the body does not begin with it.
    private static func memoTitle(of row: QuickAccessRow, over body: String) -> String? {
        row.savedAsMemo && !row.title.isEmpty && !body.hasPrefix(row.title) ? row.title : nil
    }

    /// `text` with the words a search found set in bold: the ones its snippet marks, wherever they appear in `text`,
    /// found the way the search finds them.
    private static func highlighted(_ text: String, like snippet: SearchSnippet?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let snippet else { return attributed }
        let source = snippet.text as NSString
        let hits = Set(snippet.highlights.compactMap { range -> String? in
            guard range.lowerBound >= 0, range.upperBound <= source.length, !range.isEmpty else { return nil }
            return source.substring(with: NSRange(location: range.lowerBound, length: range.count))
        })
        for hit in hits.sorted() {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text.range(of: hit, options: SearchService.snippetOptions, range: start..<text.endIndex) {
                // An empty match would never move on.
                guard !found.isEmpty else { break }
                if let lower = AttributedString.Index(found.lowerBound, within: attributed),
                   let upper = AttributedString.Index(found.upperBound, within: attributed), lower < upper {
                    attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                start = found.upperBound
            }
        }
        return attributed
    }

    /// The host, and everything after it: the port, then the path, query and fragment with their percent
    /// escapes decoded, so that `/wiki/%E4%B8%AD` reads `/wiki/中`. When an escape does not decode, they stay
    /// as written. A path that is only "/" says nothing and is left out. Nil when the text has no host to
    /// split off. Only the card shows the decoded text; the character count is of the link as stored.
    private static func split(link text: String) -> (host: String, rest: String)? {
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        var written = components.percentEncodedPath
        if let query = components.percentEncodedQuery { written += "?" + query }
        if let fragment = components.percentEncodedFragment { written += "#" + fragment }
        let decoded = written.removingPercentEncoding ?? written
        let port = components.port.map { ":\($0)" } ?? ""
        return (host, port + (decoded == "/" ? "" : decoded))
    }
}

extension ContentKind {
    /// The word a card's colour band shows, and VoiceOver says first.
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

/// One card of the strip: a band in the colour of the source app's icon, naming the kind of clip and how long ago
/// it was copied, with the app's icon at its right; the clip itself, as large as the card allows; and a footer with
/// its length, size, host or type. It is drawn at the size `metrics` gives. A selected card's ring is drawn outside
/// that size, 3 pt from its edge and 3 pt wide (4 pt with Increase Contrast), and so is the card's shadow, so
/// whatever hosts the card must not clip them.
struct StripFrameView: View {
    let content: StripFrameContent
    let applicationIcon: NSImage
    let metrics: StripMetrics
    /// The band's colour, worked out from the source app's icon when the app's first card is made. A clip without a
    /// source app has none, and its band is neutral.
    let headerTint: HeaderTint?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let selectionGap: CGFloat = 3
    /// The system draws an app's icon, and a document's, with a clear margin around it: of every 64 points the
    /// icon itself fills 52 across, and a document's page 57 down. The icons are drawn that much larger, so that
    /// what shows is the size the card asks for.
    private static let appIconFill: CGFloat = 52.0 / 64.0
    private static let documentIconFill: CGFloat = 57.0 / 64.0

    private var isDark: Bool { colorScheme == .dark }
    private var increasedContrast: Bool { contrast == .increased }
    /// A medium card's measures are scaled by this on the other card sizes, as its text is.
    private var scale: CGFloat { StripTypography.scale(for: metrics.cardSize) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous) }

    private var tint: HeaderTint { headerTint ?? .neutral(dark: isDark) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: metrics.headerHeight)
            middle
                .frame(width: metrics.contentSize.width, height: metrics.contentSize.height)
                .clipped()
            footer
                .frame(height: metrics.footerHeight)
        }
        .frame(width: metrics.frameSize.width, height: metrics.frameSize.height)
        // The paper's hairline lies under the band, the picture and the text, as in the design.
        .background {
            shape.fill(Palette.paper(isDark))
            shape.strokeBorder(Palette.hairline(isDark), lineWidth: 0.5)
        }
        .clipShape(shape)
        .overlay {
            if let width = Self.paperStroke(reduceTransparency: reduceTransparency) {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: width)
            }
        }
        .background {
            shape.fill(Palette.paper(isDark))
                .shadow(color: Palette.shadow(isDark), radius: isDark ? 10 : 8, x: 0, y: isDark ? 8 : 6)
        }
        .overlay { selectionRing }
    }

    /// The width of the line drawn along a card's edge, if it has one. With Reduce Transparency the band is
    /// solid and can be close to the paper's colour, so each card draws a firm line of its own to show where it
    /// ends; otherwise the hairline under its content and its shadow do that.
    nonisolated static func paperStroke(reduceTransparency: Bool) -> CGFloat? {
        reduceTransparency ? 1 : nil
    }

    // MARK: Colour band

    private var header: some View {
        let tint = self.tint
        let secondary = tint.secondaryText(increasedContrast: increasedContrast).color
        return ZStack {
            tint.background.color
            VStack(alignment: .leading, spacing: 1) {
                Text(content.kind.accessibilityName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint.text.color)
                    .frame(height: 19)
                HStack(spacing: 4) {
                    ForEach(Array(content.headerLine.enumerated()), id: \.offset) { _, item in
                        headerItem(item, color: secondary)
                    }
                }
                .frame(height: 16)
            }
            .lineLimit(1)
            .padding(.leading, 14)
            // Clear of the icon, which stands 10 pt in from the right.
            .padding(.trailing, 10 + metrics.iconSize + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            appIcon
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func headerItem(_ item: StripHeaderItem, color: Color) -> some View {
        switch item {
        case .time(let time):
            Text(time)
                .font(.system(size: 12))
                .foregroundStyle(color)
        case .marker(let marker):
            let (symbol, name): (String, String) = switch marker {
            case .savedAsMemo: ("bookmark.fill", "Saved as Memo")
            case .partiallyIndexed: ("circle.lefthalf.filled", "Partially indexed")
            }
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .help(name)
                .accessibilityLabel(name)
        case .extraItems(let count):
            Text("+\(count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
    }

    /// The source app's own icon, its visible square `iconSize` a side, with a slight shadow.
    private var appIcon: some View {
        let drawn = metrics.iconSize / Self.appIconFill
        return Image(nsImage: applicationIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: drawn, height: drawn)
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
            .frame(width: metrics.iconSize, height: metrics.iconSize)
            .accessibilityHidden(true)
    }

    // MARK: The clip

    @ViewBuilder
    private var middle: some View {
        if showsUnavailableText {
            unavailableBody
        } else {
            switch content.body {
            case .text(let text, let style): textBody(text, style: style)
            case .link(let title): linkBody(title)
            case .image(let image, let fills):
                if fills { filledImage(image) } else { wholeImage(image) }
            case .file(let name, let typeIdentifier): fileBody(name: name, typeIdentifier: typeIdentifier)
            case .placeholder(let symbol, let title): placeholderBody(symbol: symbol, title: title)
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

    /// Room for text in the middle, inside its padding.
    private var textPadding: CGFloat { StripTypography.padding(for: metrics.cardSize) }

    /// The text from the top left, as many lines as fill the middle, with the memo title in bold on the first.
    private func textBody(_ text: AttributedString, style: StripTextStyle) -> some View {
        let lines = StripTypography.bodyLines(style, metrics: metrics, hasMemoTitle: content.memoTitle != nil)
        return VStack(alignment: .leading, spacing: 0) {
            if let title = content.memoTitle {
                Text(title)
                    .font(.system(size: style.size, weight: .semibold))
                    .lineHeight(.exact(points: style.lineHeight))
                    .lineLimit(1)
            }
            Text(marked(text))
                .font(.system(size: style.size))
                .lineHeight(.exact(points: style.lineHeight))
                .lineLimit(lines)
        }
        .foregroundStyle(Palette.text(isDark))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(textPadding)
    }

    /// A light tile with a globe, and the link's title under it, centred.
    private func linkBody(_ title: AttributedString) -> some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        let (top, gap, bottom, tile) = (22 * scale, 14 * scale, 14 * scale, 48 * scale)
        let room = metrics.contentSize.height - top - tile - gap - bottom
        return VStack(spacing: gap) {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(Palette.globeTile)
                .frame(width: tile, height: tile)
                .overlay {
                    Image(systemName: "globe")
                        .font(.system(size: 21 * scale))
                        .foregroundStyle(Palette.globe)
                }
                .accessibilityHidden(true)
            Text(marked(title))
                .font(.system(size: style.size, weight: .semibold))
                .lineHeight(.exact(points: style.lineHeight))
                .multilineTextAlignment(.center)
                .lineLimit(min(3, StripTypography.lines(in: room, style: style)))
                .foregroundStyle(Palette.text(isDark))
        }
        .padding(.top, top)
        .padding(.horizontal, 16 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A picture covering the middle, cut evenly at its edges. A picture is shown this way when its shape is within a
    /// factor of two of the middle's.
    private func filledImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: metrics.contentSize.width, height: metrics.contentSize.height)
            .clipped()
    }

    /// A picture whose shape is more than twice as wide or as tall as the middle's, shown whole on the paper:
    /// covering the middle would cut most of it away.
    private func wholeImage(_ image: CGImage) -> some View {
        let aspect = content.imageAspectRatio ?? CGFloat(image.width) / CGFloat(max(image.height, 1))
        return Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .padding(textPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The icon of the file's type and its name under it, centred.
    private func fileBody(name: String, typeIdentifier: String?) -> some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        let (top, gap, bottom, iconHeight) = (20 * scale, 12 * scale, 12 * scale, 60 * scale)
        let room = metrics.contentSize.height - top - iconHeight - gap - bottom
        let icon = NSWorkspace.shared.icon(for: typeIdentifier.flatMap { UTType($0) } ?? .data)
        return VStack(spacing: gap) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconHeight / Self.documentIconFill, height: iconHeight / Self.documentIconFill)
                .frame(height: iconHeight)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: style.size, weight: .semibold))
                .lineHeight(.exact(points: style.lineHeight))
                .multilineTextAlignment(.center)
                .lineLimit(min(2, StripTypography.lines(in: room, style: style)))
                .truncationMode(.middle)
                .foregroundStyle(Palette.text(isDark))
        }
        .padding(.top, top)
        .padding(.horizontal, 16 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The kind's symbol and the clip's title, laid out as a file is, while there is nothing else to show.
    private func placeholderBody(symbol: String, title: String) -> some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        let (top, gap, bottom, iconHeight) = (20 * scale, 12 * scale, 12 * scale, 60 * scale)
        let room = metrics.contentSize.height - top - iconHeight - gap - bottom
        return VStack(spacing: gap) {
            Image(systemName: symbol)
                .font(.system(size: iconHeight * 0.6, weight: .light))
                .foregroundStyle(footerText)
                .frame(height: iconHeight)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: style.size, weight: .semibold))
                .lineHeight(.exact(points: style.lineHeight))
                .multilineTextAlignment(.center)
                .lineLimit(min(2, StripTypography.lines(in: room, style: style)))
                .foregroundStyle(Palette.text(isDark))
        }
        .padding(.top, top)
        .padding(.horizontal, 16 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The memo title, if any, and a notice in place of the text that is gone.
    private var unavailableBody: some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        return VStack(alignment: .leading, spacing: 0) {
            if let title = content.memoTitle {
                Text(title)
                    .font(.system(size: style.size, weight: .semibold))
                    .lineHeight(.exact(points: style.lineHeight))
                    .lineLimit(1)
                    .foregroundStyle(Palette.text(isDark))
            }
            Text("Text unavailable")
                .font(.system(size: style.size))
                .lineHeight(.exact(points: style.lineHeight))
                .foregroundStyle(footerText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(textPadding)
    }

    /// A search's hits in bold, on the highlighter's yellow.
    private func marked(_ text: AttributedString) -> AttributedString {
        var marked = text
        for run in text.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            marked[run.range].backgroundColor = Palette.hit(isDark)
        }
        return marked
    }

    // MARK: Footer

    private var footerText: Color { increasedContrast ? Palette.text(isDark) : Palette.footer(isDark) }

    /// The length, size, host or type of the clip, centred under a hairline.
    private var footer: some View {
        Text(content.info ?? "")
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(footerText)
            .padding(.horizontal, textPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Palette.separator(isDark))
                    .frame(height: 0.5)
            }
    }

    // MARK: Selection

    /// A ring in the system's accent colour outside the card: 3 pt wide, 3 pt from its edge; 4 pt wide with
    /// Increase Contrast.
    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            let width: CGFloat = increasedContrast ? 4 : 3
            let offset = Self.selectionGap + width / 2
            RoundedRectangle(cornerRadius: metrics.cornerRadius + offset, style: .continuous)
                .stroke(Color(nsColor: .controlAccentColor), lineWidth: width)
                .padding(-offset)
                .allowsHitTesting(false)
        }
    }
}

/// The card's own colours, the same in every app: the design sets them for dark and light.
private enum Palette {
    static func paper(_ dark: Bool) -> Color { dark ? rgb(0x2C2C2E) : rgb(0xFFFFFF) }
    static func text(_ dark: Bool) -> Color { dark ? rgb(0xF2F2F7) : rgb(0x1D1D1F) }
    static func footer(_ dark: Bool) -> Color { dark ? rgb(0x98989D) : rgb(0x6E6E73) }
    static func hairline(_ dark: Bool) -> Color { dark ? .white.opacity(0.08) : .black.opacity(0.08) }
    static func separator(_ dark: Bool) -> Color { dark ? .white.opacity(0.07) : .black.opacity(0.07) }
    static func shadow(_ dark: Bool) -> Color {
        dark ? .black.opacity(0.35) : Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 40 / 255, opacity: 0.12)
    }
    static func hit(_ dark: Bool) -> Color {
        dark ? Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: 0.38)
            : Color(.sRGB, red: 1, green: 204 / 255, blue: 0, opacity: 0.45)
    }
    static let globeTile = rgb(0xF2F2F7)
    static let globe = rgb(0x3A3A3C)

    private static func rgb(_ hex: UInt32) -> Color { HeaderTint.RGB(hex: hex).color }
}

// MARK: Row text and source apps

extension QuickAccessRow {
    var displayTitle: String { title.isEmpty ? "Clipboard Item" : title }
}

extension ContentKind {
    var symbolName: String {
        switch self {
        case .text: "doc.text"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .other: "square.dashed"
        }
    }
}

/// Text quick access makes from a row: where it came from and how long ago, and a search snippet with its hits
/// in bold.
@MainActor
enum QuickAccessRowContent {
    /// "<App> · <time>", or the time alone when the source app is not known.
    static func detail(for row: QuickAccessRow, applicationName: String?) -> String {
        [applicationName, time(of: row.date)].compactMap { $0 }.joined(separator: " · ")
    }

    /// How long before `now` the clip was copied, as a card says it: "Just now" under a minute (and for a clip
    /// from a clock that ran ahead), then "2 min. ago", "Yesterday" and so on. Spoken, the units are whole words:
    /// "2 minutes ago".
    nonisolated static func time(of date: Date, relativeTo now: Date = Date(), spoken: Bool = false,
                                 locale: Locale = .current) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        return Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named,
                                                unitsStyle: spoken ? .wide : .abbreviated, locale: locale,
                                                capitalizationContext: .beginningOfSentence).format(now)
    }

    /// Pure string work, so it is not tied to the main actor.
    nonisolated static func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.text)
        let length = snippet.text.utf16.count
        for range in snippet.highlights where range.lowerBound >= 0 && range.upperBound <= length {
            let lower = String.Index(utf16Offset: range.lowerBound, in: snippet.text)
            let upper = String.Index(utf16Offset: range.upperBound, in: snippet.text)
            guard let start = AttributedString.Index(lower, within: attributed),
                  let end = AttributedString.Index(upper, within: attributed), start < end else { continue }
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}

/// Display names and icons for source apps, looked up once per bundle identifier.
@MainActor
final class ApplicationNames {
    private var names: [String: String?] = [:]
    private var icons: [String: NSImage] = [:]
    private lazy var genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    func name(for bundleIdentifier: String) -> String? {
        if let cached = names[bundleIdentifier] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { url in
            let display = FileManager.default.displayName(atPath: url.path)
            return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        names[bundleIdentifier] = name
        return name
    }

    /// The app's icon, or the system's generic app icon for a clip without a source app or one whose app
    /// cannot be found.
    func icon(for bundleIdentifier: String?) -> NSImage {
        guard let bundleIdentifier else { return genericIcon }
        if let cached = icons[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? genericIcon
        icons[bundleIdentifier] = icon
        return icon
    }
}
