import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a strip frame shows of a clip beyond its title.
struct ClipDetail: Equatable, Sendable {
    /// The start of a text, or a link's whole URL.
    var excerpt: String?
    /// The length of the whole text or URL, counted in characters as a reader sees them.
    var characterCount: Int?
    /// The picture's size as shown, taken from its header.
    var pixelSize: CGSize?
    var thumbnail: CGImage?
    /// Whether the thumbnail covers the whole frame, or is shown whole inside it.
    var fillsFrame = true
    var fileNames: [String] = []
    var itemCount = 1
}

/// Reads a clip's stored content and boils it down to what a strip frame shows: an excerpt and the
/// exact character count, an image's size and thumbnail, or the names of the files it refers to.
///
/// It is neither main-actor isolated nor an actor on purpose. Its async methods are non-isolated, so
/// they run on the global executor: reading, decoding and counting never happen on the main thread,
/// and the frames on screen load side by side instead of queuing behind one another.
final class PreviewService: Sendable {
    private static let excerptLength = 300

    private let read: @Sendable (ContentRef) async throws -> ResolvedContent
    private let cache: ThumbnailCache

    init(read: @escaping @Sendable (ContentRef) async throws -> ResolvedContent,
         cache: ThumbnailCache = ThumbnailCache()) {
        self.read = read
        self.cache = cache
    }

    /// `frameSize` is the frame in pixels, which is its size in points times two. A cancelled call
    /// throws `CancellationError` and caches nothing, so asking again starts from the beginning.
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
        guard let source = Self.imageSource(in: representations), let size = Self.pixelSize(of: source) else {
            return nil
        }
        try Task.checkCancellation()
        let longEdge = Int(max(size.width, size.height))
        guard let image = Self.thumbnail(of: source, maximumPixels: min(max(maximumPixels, 1), longEdge)) else {
            return nil
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
        let text = ClipboardTextDecoder.fullText(representations)
        try Task.checkCancellation()
        guard let text else { return ClipDetail() }
        let characterCount = text.count
        try Task.checkCancellation()
        let excerpt = isLink ? text : String(text.drop(while: \.isWhitespace).prefix(excerptLength))
        return ClipDetail(excerpt: excerpt, characterCount: characterCount)
    }

    private static func imageDetail(_ representations: [RepresentationValue], frameSize: CGSize) throws -> ClipDetail {
        guard let source = imageSource(in: representations), let size = pixelSize(of: source) else {
            return ClipDetail()
        }
        var detail = ClipDetail(pixelSize: size)
        try Task.checkCancellation()
        guard frameSize.width > 0, frameSize.height > 0 else { return detail }

        // An image shaped within a factor of two of the frame fills it, losing a little at the edges.
        // One that is much wider or taller is shown whole, because filling would crop most of it away.
        let imageAspect = size.width / size.height
        let frameAspect = frameSize.width / frameSize.height
        let fills = max(imageAspect / frameAspect, frameAspect / imageAspect) < 2
        detail.fillsFrame = fills
        detail.thumbnail = thumbnail(of: source, maximumPixels: thumbnailPixels(of: size, in: frameSize, fills: fills))
        return detail
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

    /// The last path component of each file URL in the clip, one for each file. A payload that is
    /// not a URL gives no name, so there can be fewer names than files.
    private static func fileNames(in representations: [RepresentationValue]) -> [String] {
        representations.compactMap { representation in
            guard representation.typeIdentifier.lowercased() == "public.file-url",
                  let bytes = representation.bytes,
                  let string = String(data: bytes, encoding: .utf8),
                  let url = URL(string: string) else { return nil }
            return url.lastPathComponent
        }
    }
}
