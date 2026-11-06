import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small mark after a card's time.
enum StripMarker: Equatable {
    case savedAsMemo, partiallyIndexed
    /// A favorite memo.
    case favorite
}

/// One piece of the line under a card's kind, in its header.
enum StripHeaderItem: Equatable {
    case time(String)
    /// How often a frequent clip was used, in place of its time.
    case uses(String)
    case marker(StripMarker)
    /// A memo's collection: its colour's name and its name.
    case collection(name: String, color: String)
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

    /// What the header names the clip.
    var kind: ContentKind
    /// Whether the card is a clip's or a memo's.
    var facet: ContentFacet = .history
    /// A memo's collection, when the card should name it.
    var collection: CollectionSummary? = nil
    /// Whether a memo is a favorite.
    var isFavorite = false

    /// The header's first line: the kind of a clip, or "Snippet" for a memo.
    var bandName: String { facet == .memo ? "Snippet" : kind.accessibilityName }
    /// How long ago the clip was copied, as the header says it.
    var time: String
    /// A frequent clip's "Used N times", shown in the header in place of its time; nil otherwise.
    var uses: String?
    /// The app the clip came from. Its icon shows in the header, and gives the card its accent when it is in no
    /// collection.
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

    /// The header's second line, left to right: the time, or how often a frequent clip was used, then a memo's
    /// collection, then the marks, and how many more items there are.
    var headerLine: [StripHeaderItem] {
        [uses.map(StripHeaderItem.uses) ?? .time(time)]
            + (collection.map { [.collection(name: $0.name, color: $0.color)] } ?? [])
            + markers.map(StripHeaderItem.marker)
            + (extraItems > 0 ? [.extraItems(extraItems)] : [])
    }

    /// `detail` is nil until the details have arrived, and when they could not be read. A text search
    /// result already has its snippet, so it shows it without them and only its caption waits. `now` is the
    /// moment the time is told from. `collections` holds the collections a memo's card may name; a list of one
    /// collection leaves it out, since every card there is in it.
    static func make(row: QuickAccessRow, detail: ClipDetail?, cardSize: CardSize,
                     now: Date = Date(), collections: [CollectionID: CollectionSummary] = [:]) -> StripFrameContent {
        let isMemo = row.facet == .memo
        var content = StripFrameContent(
            kind: row.kind, facet: row.facet,
            collection: isMemo ? row.collectionID.flatMap { collections[$0] } : nil,
            isFavorite: isMemo && row.isFavorite,
            time: QuickAccessRowContent.time(of: row.date, relativeTo: now),
            uses: row.frequentUses.map { ClipInfoFormatter.uses($0) }, sourceApp: row.sourceApp,
            accessibilityTitle: row.displayTitle,
            body: .placeholder(symbol: row.kind.symbolName, title: row.displayTitle),
            extraItems: 0, markers: [], isTextUnavailable: row.isTextUnavailable
        )
        if row.savedAsMemo { content.markers.append(.savedAsMemo) }
        if row.isPartiallyIndexed { content.markers.append(.partiallyIndexed) }
        if content.isFavorite { content.markers.append(.favorite) }
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

    /// Sets a text body at the card size's style, with the memo title above it when it has one.
    private mutating func setText(_ text: AttributedString, plain: String, for row: QuickAccessRow,
                                  cardSize: CardSize) {
        memoTitle = Self.memoTitle(of: row, over: plain)
        body = .text(text, style: StripTypography.bodyStyle(cardSize: cardSize))
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

/// The one colour a card takes, which washes in from its top and lights the band behind it while it is selected: the
/// colour of the collection a snippet is in, or else the colour its app's icon gives it. A card in no collection whose
/// app's icon has no colour to speak of, or that has no app, takes none.
enum CardAccent: Equatable, Sendable {
    /// A collection's colour, by the name it is stored under.
    case collection(String)
    /// The colour the card's app gives it, taken from the app's icon.
    case app(HeaderTint.RGB)

    /// `row`'s accent: the colour of its collection when `collectionColors` holds it, otherwise `tint`, the colour its
    /// app's icon gives, unless that is grey; nil for neither.
    init?(row: QuickAccessRow, collectionColors: [CollectionID: String], tint: HeaderTint?) {
        if let id = row.collectionID, let color = collectionColors[id] {
            self = .collection(color)
        } else if let tint, !tint.isNeutral {
            self = .app(tint.background)
        } else {
            return nil
        }
    }

    /// The colour as SwiftUI draws it. A collection's is the system's, which follows the appearance.
    var color: Color {
        switch self {
        case .collection(let name): Color.collection(name)
        case .app(let rgb): rgb.color
        }
    }

    /// The colour in sRGB as `appearance` shows it.
    @MainActor
    func rgb(in appearance: NSAppearance) -> HeaderTint.RGB {
        switch self {
        case .app(let rgb):
            return rgb
        case .collection(let name):
            var rgb = HeaderTint.RGB(red: 0, green: 0, blue: 0)
            appearance.performAsCurrentDrawingAppearance {
                if let srgb = NSColor.collection(name).usingColorSpace(.sRGB) {
                    rgb = HeaderTint.RGB(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                                         blue: Double(srgb.blueComponent))
                }
            }
            return rgb
        }
    }
}

extension ContentKind {
    /// The word a card's header shows, and VoiceOver says first.
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

/// One card of the strip: a header naming the kind of clip and how long ago it was copied, with the source app's icon
/// at its right, and the card's accent washing in from its top behind it; the clip itself, as large as the card
/// allows; and a footer with its length, size, host or type. It is drawn at the size `metrics` gives. In light mode
/// its shadow extends outside that size, so whatever hosts the card must not clip it.
struct StripFrameView: View {
    let content: StripFrameContent
    let applicationIcon: NSImage
    let metrics: StripMetrics
    /// The card's colour, which washes in from its top; nil for a neutral header.
    let accent: CardAccent?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The system draws an app's icon, and a document's, with a clear margin around it: of every 64 points the
    /// icon itself fills 52 across, and a document's page 57 down. The icons are drawn that much larger, so that
    /// what shows is the size the card asks for.
    private static let appIconFill: CGFloat = 52.0 / 64.0
    private static let documentIconFill: CGFloat = 57.0 / 64.0

    private var isDark: Bool { colorScheme == .dark }
    private var increasedContrast: Bool { contrast == .increased }
    /// A medium card's measures are scaled by this on the other card sizes.
    private var scale: CGFloat { StripTypography.scale(for: metrics.cardSize) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: metrics.headerHeight)
                // With Increase Contrast, where the wash is weaker, a line sets the header off from the clip.
                .overlay(alignment: .bottom) {
                    if increasedContrast {
                        Rectangle()
                            .fill(Palette.edge(isDark, increasedContrast: true))
                            .frame(height: 1)
                    }
                }
            middle
                .frame(width: metrics.contentSize.width, height: metrics.contentSize.height)
                .clipped()
            footer
                .frame(height: metrics.footerHeight)
        }
        .frame(width: metrics.frameSize.width, height: metrics.frameSize.height)
        // The hairline inside the card's edge, and the wash, lie under the picture and the text, as in the design.
        .background {
            shape.fill(Palette.paper(isDark))
            shape.strokeBorder(Palette.edge(isDark, increasedContrast: increasedContrast), lineWidth: 1)
            wash
        }
        .clipShape(shape)
        // A light card stands on the light tray by a soft shadow; a dark one by its lighter colour alone.
        .background {
            if !isDark {
                shape.fill(Palette.paper(isDark))
                    .shadow(color: Palette.shadow, radius: 9, x: 0, y: 6)
            }
        }
    }

    // MARK: Wash

    /// The accent washing in from the card's top behind its header and fading out below it, 70 pt tall on a medium
    /// card and as much taller or shorter as the card is. None without an accent: the header stays neutral.
    @ViewBuilder
    private var wash: some View {
        if let accent {
            let opacity = Self.washOpacity(dark: isDark, increasedContrast: increasedContrast)
            LinearGradient(stops: [.init(color: accent.color.opacity(opacity.top), location: 0),
                                   .init(color: accent.color.opacity(opacity.middle), location: 0.58),
                                   .init(color: accent.color.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.washHeight(metrics))
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }

    /// The wash's strength at the card's top, and 58 percent of the way down it: 30 and 13 percent in dark mode, 22
    /// and 9 in light mode, and a third less with Increase Contrast. It fades to nothing at its bottom.
    nonisolated static func washOpacity(dark: Bool, increasedContrast: Bool) -> (top: Double, middle: Double) {
        let (top, middle) = dark ? (0.30, 0.13) : (0.22, 0.09)
        return increasedContrast ? (top * 2 / 3, middle * 2 / 3) : (top, middle)
    }

    /// How far down the card the wash reaches: 70 pt on a medium card, scaled by the card's height.
    nonisolated static func washHeight(_ metrics: StripMetrics) -> CGFloat {
        (70 * metrics.frameSize.height / StripLayout.cardDimensions(for: .medium).frame.height).rounded()
    }

    // MARK: Header

    /// The kind on the first line, and under it the time and the rest of the header's line, at the left; the app's
    /// icon at the right, level with the kind.
    private var header: some View {
        let insets = headerInsets
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.bandName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(isDark))
                    .frame(height: 16)
                HStack(spacing: 4) {
                    ForEach(Array(content.headerLine.enumerated()), id: \.offset) { _, item in
                        headerItem(item, color: metaText)
                    }
                }
                .frame(height: 14)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            appIcon
        }
        .padding(.top, insets.top)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The header's room: 11 pt above, 13 at the left and 11 at the right on a medium card. The room above scales with
    /// the header's height, the room beside with the card's width.
    private var headerInsets: (top: CGFloat, leading: CGFloat, trailing: CGFloat) {
        ((11 * metrics.headerHeight / 46).rounded(), (13 * scale).rounded(), (11 * scale).rounded())
    }

    private var metaText: Color { increasedContrast ? Palette.text(isDark) : Palette.meta(isDark) }

    @ViewBuilder
    private func headerItem(_ item: StripHeaderItem, color: Color) -> some View {
        switch item {
        // How often a frequent clip was used is drawn as the time it stands in for.
        case .time(let text), .uses(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
        case .marker(let marker):
            let (symbol, name): (String, String) = switch marker {
            case .savedAsMemo: ("bookmark.fill", "Saved as Snippet")
            case .partiallyIndexed: ("circle.lefthalf.filled", "Partially indexed")
            case .favorite: ("star.fill", "Favorite")
            }
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .help(name)
                .accessibilityLabel(name)
        case .collection(let name, let colorName):
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.collection(colorName))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .truncationMode(.middle)
            }
            .help(name)
        case .extraItems(let count):
            Text("+\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
    }

    /// The source app's own icon, its visible square `iconSize` a side, with its corners rounded as the design rounds
    /// the tile it stands in: 7.5 pt on a medium card's 28 pt icon.
    private var appIcon: some View {
        let drawn = metrics.iconSize / Self.appIconFill
        return Image(nsImage: applicationIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: drawn, height: drawn)
            .frame(width: metrics.iconSize, height: metrics.iconSize)
            .clipShape(RoundedRectangle(cornerRadius: 7.5 * metrics.iconSize / 28, style: .continuous))
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

    /// Room beside the text in the middle.
    private var textPadding: CGFloat { StripTypography.padding(for: metrics.cardSize) }
    /// Room above the text in the middle, under the header, and below it, over the footer.
    private var verticalPadding: (top: CGFloat, bottom: CGFloat) {
        StripTypography.verticalPadding(for: metrics.cardSize)
    }

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
        .padding(.top, verticalPadding.top)
        .padding(.bottom, verticalPadding.bottom)
        .padding(.horizontal, textPadding)
    }

    /// How many lines of `style` fit in the middle below a symbol or a tile `height` tall and the `gap` under it.
    private func lines(under height: CGFloat, gap: CGFloat, style: StripTextStyle) -> Int {
        let room = metrics.contentSize.height - verticalPadding.top - verticalPadding.bottom - height - gap
        return StripTypography.lines(in: room, style: style)
    }

    /// A light tile with a globe, and the link's title under it, centred in the middle.
    private func linkBody(_ title: AttributedString) -> some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        let (gap, tile) = (10 * scale, 38 * scale)
        return VStack(spacing: gap) {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Palette.globeTile(isDark))
                .frame(width: tile, height: tile)
                .overlay {
                    Image(systemName: "globe")
                        .font(.system(size: 17 * scale))
                        .foregroundStyle(Palette.globe)
                }
                .accessibilityHidden(true)
            Text(marked(title))
                .font(.system(size: style.size, weight: .semibold))
                .lineHeight(.exact(points: style.lineHeight))
                .multilineTextAlignment(.center)
                .lineLimit(min(3, lines(under: tile, gap: gap, style: style)))
                .foregroundStyle(Palette.text(isDark))
        }
        .padding(.top, verticalPadding.top)
        .padding(.bottom, verticalPadding.bottom)
        .padding(.horizontal, textPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The icon of the file's type and its name under it, centred in the middle.
    private func fileBody(name: String, typeIdentifier: String?) -> some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        let (gap, iconHeight) = (10 * scale, 52 * scale)
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
                .lineLimit(min(2, lines(under: iconHeight, gap: gap, style: style)))
                .truncationMode(.middle)
                .foregroundStyle(Palette.text(isDark))
        }
        .padding(.top, verticalPadding.top)
        .padding(.bottom, verticalPadding.bottom)
        .padding(.horizontal, textPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The kind's symbol and the clip's title, laid out as a file is, while there is nothing else to show.
    private func placeholderBody(symbol: String, title: String) -> some View {
        let style = StripTypography.titleStyle(cardSize: metrics.cardSize)
        let (gap, iconHeight) = (10 * scale, 52 * scale)
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
                .lineLimit(min(2, lines(under: iconHeight, gap: gap, style: style)))
                .foregroundStyle(Palette.text(isDark))
        }
        .padding(.top, verticalPadding.top)
        .padding(.bottom, verticalPadding.bottom)
        .padding(.horizontal, textPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The memo title, if any, and a notice in place of the text that is gone.
    private var unavailableBody: some View {
        let style = StripTypography.bodyStyle(cardSize: metrics.cardSize)
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
        .padding(.top, verticalPadding.top)
        .padding(.bottom, verticalPadding.bottom)
        .padding(.horizontal, textPadding)
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
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(footerText)
            .padding(.horizontal, textPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Palette.separator(isDark))
                    .frame(height: 1)
            }
    }
}

/// The card's own colours, the same in every app: the design sets them for dark and light.
private enum Palette {
    static func paper(_ dark: Bool) -> Color { dark ? rgb(0x1D1E22) : rgb(0xFFFFFF) }
    static func text(_ dark: Bool) -> Color { dark ? rgb(0xF2F2F7) : rgb(0x1D1D1F) }
    /// The time and the rest of the header's second line.
    static func meta(_ dark: Bool) -> Color { dark ? rgb(0xA3A3AA) : rgb(0x6E6E73) }
    static func footer(_ dark: Bool) -> Color { dark ? rgb(0x9C9CA3) : rgb(0x6E6E73) }
    /// The 1 pt line inside the card's edge: white at 6 percent in dark mode and black at 5 in light mode, or with
    /// Increase Contrast white at 20 and black at 18, as the band's own edge is then.
    static func edge(_ dark: Bool, increasedContrast: Bool) -> Color {
        dark ? .white.opacity(increasedContrast ? 0.2 : 0.06) : .black.opacity(increasedContrast ? 0.18 : 0.05)
    }
    static func separator(_ dark: Bool) -> Color { dark ? .white.opacity(0.06) : .black.opacity(0.06) }
    /// A light card's shadow: 6 pt down and 18 pt soft, a faint blue-grey.
    static let shadow = Color(.sRGB, red: 20 / 255, green: 24 / 255, blue: 40 / 255, opacity: 0.07)
    static func hit(_ dark: Bool) -> Color {
        dark ? Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: 0.38)
            : Color(.sRGB, red: 1, green: 204 / 255, blue: 0, opacity: 0.45)
    }
    static func globeTile(_ dark: Bool) -> Color { dark ? rgb(0xF2F2F7) : rgb(0xF1F1F3) }
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
