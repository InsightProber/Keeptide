import CoreGraphics
import Foundation
import os

/// A memory cache for what the strip shows of a clip, in two parts.
///
/// Text, link and file details are small, so they are kept by clip in a dictionary. Unlike an
/// `NSCache`, it never drops an entry on its own, and that is what lets a large text be read and
/// counted once. Content never changes under its reference, so these entries stay right, except for
/// a file's name: it is the name the file had when its reference was first resolved, and the file
/// can be renamed afterwards. Each entry is tiny, so only a very long session could make them add up;
/// the dictionary is emptied when it reaches a few thousand, and a request after that reads the clip again.
///
/// An image's detail carries a thumbnail cut to the frame, which is not small, so it is kept by clip
/// and frame size in an `NSCache`, which the system empties whenever memory runs short. A request for
/// a thumbnail that was dropped decodes the image again.
///
/// This can be shared across threads: the dictionary sits behind a lock, `NSCache` is safe to use from
/// any thread, and an entry is never changed once stored.
final class ThumbnailCache: @unchecked Sendable {
    /// Thumbnails make up nearly all of the cost; this holds about two hundred at the default density.
    private static let costLimit = 64 * 1024 * 1024
    /// How many text details are kept before the dictionary is emptied.
    private static let textLimit = 2_000

    private let imageCache: NSCache<AnyObject, AnyObject>
    private let texts = OSAllocatedUnfairLock(initialState: [ContentRef: ClipDetail]())

    /// `imageCache` is where thumbnails are kept; a test passes its own to empty it the way the system does.
    init(imageCache: NSCache<AnyObject, AnyObject> = NSCache()) {
        self.imageCache = imageCache
        imageCache.totalCostLimit = Self.costLimit
    }

    /// `frameSize`, in pixels, is only given for an image.
    func detail(for ref: ContentRef, frameSize: CGSize? = nil) -> ClipDetail? {
        guard let frameSize else { return texts.withLock { $0[ref] } }
        return (imageCache.object(forKey: Key(ref, frameSize: frameSize)) as? Entry)?.detail
    }

    func store(_ detail: ClipDetail, for ref: ContentRef, frameSize: CGSize? = nil) {
        guard let frameSize else {
            texts.withLock { details in
                if details[ref] == nil, details.count >= Self.textLimit { details.removeAll() }
                details[ref] = detail
            }
            return
        }
        imageCache.setObject(Entry(detail), forKey: Key(ref, frameSize: frameSize), cost: detail.thumbnailCost)
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

    init(_ ref: ContentRef, frameSize: CGSize) {
        self.ref = ref
        width = Int(exactly: frameSize.width.rounded()) ?? 0
        height = Int(exactly: frameSize.height.rounded()) ?? 0
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
    /// About the memory of the thumbnail the detail carries, which is what the image cache's limit counts.
    var thumbnailCost: Int {
        thumbnail.map { $0.bytesPerRow * $0.height } ?? 0
    }
}
