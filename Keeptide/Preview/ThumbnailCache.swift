import CoreGraphics
import Foundation

/// A memory cache for what the strip shows of a clip. Text, link and file details are kept by clip;
/// an image's detail carries a thumbnail cut to the frame, so it is kept by clip and frame size.
/// Stored content never changes under its reference, so an entry cannot go stale, and the system
/// may drop entries whenever memory runs short. `NSCache` is safe to use from any thread and
/// entries are never changed once stored, which is why this can be shared across threads.
final class ThumbnailCache: @unchecked Sendable {
    /// Thumbnails make up nearly all of the cost; this holds about two hundred at the default density.
    private static let costLimit = 64 * 1024 * 1024

    private let storage = NSCache<Key, Entry>()

    init() {
        storage.totalCostLimit = Self.costLimit
    }

    /// `frameSize`, in pixels, is only given for an image.
    func detail(for ref: ContentRef, frameSize: CGSize? = nil) -> ClipDetail? {
        storage.object(forKey: Key(ref, frameSize: frameSize))?.detail
    }

    func store(_ detail: ClipDetail, for ref: ContentRef, frameSize: CGSize? = nil) {
        storage.setObject(Entry(detail), forKey: Key(ref, frameSize: frameSize), cost: detail.memoryCost)
    }
}

private final class Entry {
    let detail: ClipDetail

    init(_ detail: ClipDetail) {
        self.detail = detail
    }
}

/// `NSCache` takes object keys. Two keys are equal for the same clip and the same frame in whole pixels.
private final class Key: NSObject {
    private let ref: ContentRef
    private let width: Int
    private let height: Int

    init(_ ref: ContentRef, frameSize: CGSize?) {
        self.ref = ref
        width = Int(exactly: frameSize?.width.rounded() ?? 0) ?? 0
        height = Int(exactly: frameSize?.height.rounded() ?? 0) ?? 0
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(ref)
        hasher.combine(width)
        hasher.combine(height)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Key else { return false }
        return ref == other.ref && width == other.width && height == other.height
    }
}

private extension ClipDetail {
    /// About the memory the detail holds, which is what the cache's limit counts.
    var memoryCost: Int {
        (thumbnail.map { $0.bytesPerRow * $0.height } ?? 0) + (excerpt?.utf8.count ?? 0)
    }
}
