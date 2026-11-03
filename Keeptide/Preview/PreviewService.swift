import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a strip frame shows of a clip beyond its title.
struct ClipDetail: Equatable, Sendable {
    /// The start of a text, or of a link's URL.
    var excerpt: String?
    /// The length of the whole text or URL, counted in characters as a reader sees them.
    var characterCount: Int?
    /// The picture's size as shown, taken from its header.
    var pixelSize: CGSize?
    var thumbnail: CGImage?
    /// Whether the thumbnail covers the card's picture area, cut at its edges, as it does when its shape is within a
    /// factor of two of the area's; a picture more than twice as wide or as tall for its size is shown whole instead.
    var fillsFrame = true
    var fileNames: [String] = []
    var itemCount = 1
    /// The title of the page a link was copied from, when the clip carries one.
    var linkTitle: String?
}

/// Reads a clip's stored content and boils it down to what a strip frame shows: an excerpt and the
/// exact character count, an image's size and thumbnail, or the names of the files it refers to.
///
/// It is neither main-actor isolated nor an actor on purpose. Its async methods are non-isolated, so
/// they run on the global executor: reading, decoding and counting never happen on the main thread.
/// The reads still queue: each takes the whole clip through the store's one writer context, in the same
/// line as a copy's read, so a caller keeps only a few of them going at once.
final class PreviewService: Sendable {
    static let originalImagePixelLimit = 64_000_000
    static let fullPreviewByteLimit = 262_144
    private static let excerptLength = 300
    /// A card shows a link by its host and its page title or the start of its path, so far less than this. The cut
    /// keeps what the cache holds small even for a huge URL, such as a data URL; the count is of all of it.
    private static let linkExcerptLength = 2_048

    private let read: @Sendable (ContentRef) async throws -> ResolvedContent
    private let fileReferences: (@Sendable (ContentRef) async throws -> [FilePreviewReference])?
    private let cache: ThumbnailCache

    init(read: @escaping @Sendable (ContentRef) async throws -> ResolvedContent,
         fileReferences: (@Sendable (ContentRef) async throws -> [FilePreviewReference])? = nil,
         cache: ThumbnailCache = ThumbnailCache()) {
        self.read = read
        self.fileReferences = fileReferences
        self.cache = cache
    }

    /// Loads a full preview from the current content reference. Unlike card details,
    /// full previews are never cached: deletion, replacement, relocation, and account
    /// changes must be observed on every request.
    func preview(
        for ref: ContentRef,
        kind: ContentKind,
        maximumImagePixels: Int
    ) async throws -> PreviewContent {
        if kind == .file, let fileReferences {
            let references = try await fileReferences(ref)
            try Task.checkCancellation()
            return .files(references)
        }

        let content = try await read(ref)
        try Task.checkCancellation()
        guard content.integrity == .complete else { throw PasteRefusal.contentUnavailable }
        if kind == .text || kind == .other,
           let markdown = Self.markdownSource(in: content.representations) {
            let document = MarkdownRenderer.parse(markdown.text)
            try Task.checkCancellation()
            return .markdown(document, isTruncated: markdown.isTruncated)
        }

        switch kind {
        case .image:
            guard let loaded = try Self.image(
                in: content.representations,
                maximumPixels: maximumImagePixels
            ) else { return .info(kind: kind, sourceApp: nil) }
            return .image(loaded.image, pixelSize: loaded.pixelSize)
        case .url:
            guard let address = ClipboardTextDecoder.linkText(content.representations) else {
                return .info(kind: kind, sourceApp: nil)
            }
            return .url(title: ClipboardTextDecoder.linkTitle(content.representations), address: address)
        case .text:
            guard let text = ClipboardTextDecoder.preview(
                content.representations,
                maximumBytes: Self.fullPreviewByteLimit
            ) else { return .info(kind: kind, sourceApp: nil) }
            return .text(text.text, isTruncated: text.isTruncated)
        case .file:
            // Without a LocalState reader a file remains informative but cannot be previewed.
            return .info(kind: kind, sourceApp: nil)
        case .other:
            return .info(kind: kind, sourceApp: nil)
        }
    }

    /// `frameSize` is the area a picture fills in a card, in pixels: the card's middle, between its colour band and
    /// its footer, at the screen's scale. A cancelled call throws `CancellationError` and caches nothing, so asking
    /// again starts from the beginning.
    func detail(for ref: ContentRef, kind: ContentKind, frameSize: CGSize) async throws -> ClipDetail {
        // Only an image's thumbnail depends on the frame.
        let frame = kind == .image ? frameSize : nil
        if let cached = cache.detail(for: ref, frameSize: frame) { return cached }
        let representations = try await completeRepresentations(of: ref)

        var detail: ClipDetail
        switch kind {
        case .text, .url: detail = try Self.textDetail(representations, isLink: kind == .url)
        case .image: detail = try Self.imageDetail(representations, frameSize: frameSize)
        case .file: detail = ClipDetail(fileNames: Self.fileNames(in: representations))
        case .other: detail = ClipDetail()
        }
        detail.itemCount = Set(representations.map(\.itemIndex)).count
        try Task.checkCancellation()
        cache.store(detail, for: ref, frameSize: frame)
        return detail
    }

    /// The clip's first image with its long edge at most `maximumPixels`, and the size of the whole
    /// picture. Nil when the clip holds no image that can be decoded.
    func image(for ref: ContentRef, maximumPixels: Int) async throws -> (image: CGImage, pixelSize: CGSize)? {
        let representations = try await completeRepresentations(of: ref)
        return try Self.image(in: representations, maximumPixels: maximumPixels)
    }

    /// Decodes the selected image at its source dimensions only after an explicit
    /// user action. Header dimensions are checked before ImageIO allocates pixels.
    func originalImage(for ref: ContentRef) async throws -> (image: CGImage, pixelSize: CGSize)? {
        let representations = try await completeRepresentations(of: ref)
        guard let source = Self.imageSource(in: representations), let size = Self.pixelSize(of: source) else {
            return nil
        }
        try OriginalImagePolicy.validate(pixelSize: size, limit: Self.originalImagePixelLimit)
        try Task.checkCancellation()
        let longEdge = Int(max(size.width, size.height))
        guard let image = Self.thumbnail(of: source, maximumPixels: longEdge) else {
            throw PreviewLoadError.couldNotDecodeImage
        }
        try Task.checkCancellation()
        return (image, size)
    }

    /// A clip that is recovering, damaged or waiting for its file to be located has nothing to show.
    private func completeRepresentations(of ref: ContentRef) async throws -> [RepresentationValue] {
        let content = try await read(ref)
        try Task.checkCancellation()
        guard content.integrity == .complete else { throw PasteRefusal.contentUnavailable }
        return content.representations
    }

    private static func textDetail(_ representations: [RepresentationValue], isLink: Bool) throws -> ClipDetail {
        let text = isLink ? ClipboardTextDecoder.linkText(representations) : ClipboardTextDecoder.fullText(representations)
        try Task.checkCancellation()
        guard let text else { return ClipDetail() }
        let characterCount = text.count
        try Task.checkCancellation()
        let excerpt = isLink
            ? String(text.prefix(linkExcerptLength))
            : String(text.drop(while: \.isWhitespace).prefix(excerptLength))
        var detail = ClipDetail(excerpt: excerpt, characterCount: characterCount)
        if isLink {
            try Task.checkCancellation()
            detail.linkTitle = ClipboardTextDecoder.linkTitle(representations).map { String($0.prefix(excerptLength)) }
        }
        return detail
    }

    private static func imageDetail(_ representations: [RepresentationValue], frameSize: CGSize) throws -> ClipDetail {
        guard let source = imageSource(in: representations), let size = pixelSize(of: source) else {
            return ClipDetail()
        }
        var detail = ClipDetail(pixelSize: size)
        try Task.checkCancellation()
        guard frameSize.width > 0, frameSize.height > 0 else { return detail }

        // An image shaped within a factor of two of the picture area fills it, losing a little at the edges.
        // One that is much wider or taller is shown whole, because filling would crop most of it away.
        let imageAspect = size.width / size.height
        let frameAspect = frameSize.width / frameSize.height
        let fills = max(imageAspect / frameAspect, frameAspect / imageAspect) < 2
        detail.fillsFrame = fills
        detail.thumbnail = thumbnail(of: source, maximumPixels: thumbnailPixels(of: size, in: frameSize, fills: fills))
        return detail
    }

    private static func image(
        in representations: [RepresentationValue],
        maximumPixels: Int
    ) throws -> (image: CGImage, pixelSize: CGSize)? {
        guard let source = imageSource(in: representations), let size = pixelSize(of: source) else {
            return nil
        }
        try Task.checkCancellation()
        let decodePixels = FittedImagePolicy.maximumPixels(sourceSize: size, requested: maximumPixels)
        guard let image = thumbnail(of: source, maximumPixels: decodePixels) else {
            return nil
        }
        try Task.checkCancellation()
        return (image, size)
    }

    private static func markdownSource(in representations: [RepresentationValue]) -> ClipTextPreview? {
        for representation in representations where ContentKind.isMarkdown(representation.typeIdentifier) {
            guard let bytes = representation.bytes else { continue }
            let count = min(bytes.count, Self.fullPreviewByteLimit)
            for trim in 0...min(3, max(0, count - 1)) {
                let candidateCount = count - trim
                guard candidateCount > 0 else { continue }
                if let text = String(data: Data(bytes.prefix(candidateCount)), encoding: .utf8) {
                    return ClipTextPreview(text: text, isTruncated: candidateCount < bytes.count)
                }
            }
        }
        return nil
    }

    /// The long edge, in pixels, at which the image just covers the frame (`fills`) or just fits
    /// inside it, never more than the image has.
    private static func thumbnailPixels(of size: CGSize, in frameSize: CGSize, fills: Bool) -> Int {
        let widthScale = frameSize.width / size.width
        let heightScale = frameSize.height / size.height
        let scale = fills ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let longEdge = max(size.width, size.height)
        let pixels = min(longEdge, longEdge * scale)
        // Covering rounds up and fitting rounds down, so rounding never leaves a gap or an overshoot.
        return max(1, Int(pixels.rounded(fills ? .up : .down)))
    }

    /// The first representation whose type is an image and that has bytes to read.
    private static func imageSource(in representations: [RepresentationValue]) -> CGImageSource? {
        for representation in representations {
            guard let bytes = representation.bytes,
                  UTType(representation.typeIdentifier)?.conforms(to: .image) == true else { continue }
            return CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        return nil
    }

    /// The picture's size as shown, read from its header without decoding any pixels.
    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 turn the picture a quarter, and the thumbnail is turned with it.
        let isQuarterTurned = (properties[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
        return isQuarterTurned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Decoded here, off the main thread, so drawing it later costs nothing.
    private static func thumbnail(of source: CGImageSource, maximumPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The names of the files a clip refers to, in order. A file whose name cannot be told is left
    /// out, so there can be fewer names than files. Only names leave this function: the full paths
    /// they come from are private and are never kept or logged.
    private static func fileNames(in representations: [RepresentationValue]) -> [String] {
        if let listed = listedFileNames(in: representations) { return listed }
        return representations.compactMap { representation in
            guard representation.typeIdentifier.lowercased() == "public.file-url",
                  let bytes = representation.bytes,
                  let string = String(data: bytes, encoding: .utf8) else { return nil }
            return fileName(ofURL: string)
        }
    }

    /// Finder names its files by number in the URLs it writes, but it also lists their full paths in
    /// the legacy `NSFilenamesPboardType` property list, which needs no file system access.
    private static func listedFileNames(in representations: [RepresentationValue]) -> [String]? {
        for representation in representations
        where SystemFileReferenceClassifier.filenamesListIdentifiers.contains(representation.typeIdentifier.lowercased()) {
            guard let bytes = representation.bytes,
                  let list = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil),
                  let paths = list as? [String] else { continue }
            let names = paths.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty }
            if !names.isEmpty { return names }
        }
        return nil
    }

    /// A file-reference URL such as `file:///.file/id=6571367.2` names a file by number; its name is
    /// on the path the reference resolves to, and a reference that no longer resolves gives none.
    /// Recent Foundation resolves a reference inside `URL.path` and gives an empty path when it
    /// cannot, so a reference is recognised by its text rather than by its path.
    private static func fileName(ofURL string: String) -> String? {
        guard let url = URL(string: string) else { return nil }
        let isReference = string.hasPrefix("file:///.file/id=")
        let name = isReference ? (url as NSURL).filePathURL?.lastPathComponent : url.lastPathComponent
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

enum PreviewLoadError: Error, Equatable {
    case originalImageTooLarge
    case invalidImageDimensions
    case couldNotDecodeImage
}

enum OriginalImagePolicy {
    static func validate(pixelSize: CGSize, limit: Int) throws {
        guard limit > 0,
              pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0,
              let width = Int(exactly: pixelSize.width.rounded(.up)),
              let height = Int(exactly: pixelSize.height.rounded(.up)) else {
            throw PreviewLoadError.invalidImageDimensions
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { throw PreviewLoadError.originalImageTooLarge }
        guard pixels <= limit else { throw PreviewLoadError.originalImageTooLarge }
    }
}

enum FittedImagePolicy {
    /// A corrupt or adversarial header can carry an integer dimension that loses
    /// precision when ImageIO bridges it through CGFloat. Never convert such a
    /// value back to Int directly; the caller's already-bounded request remains
    /// a safe thumbnail limit.
    static func maximumPixels(sourceSize: CGSize, requested: Int) -> Int {
        let requested = max(requested, 1)
        let longEdge = max(sourceSize.width, sourceSize.height)
        guard longEdge.isFinite,
              longEdge > 0,
              let sourcePixels = Int(exactly: longEdge.rounded(.up)) else {
            return requested
        }
        return min(requested, sourcePixels)
    }
}
