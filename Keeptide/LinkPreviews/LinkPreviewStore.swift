import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a page gives to show its link by, as its website sent it.
struct LinkPageMetadata: Equatable, Sendable {
    /// The page's title.
    var title: String? = nil
    /// The page's picture, in any format ImageIO reads.
    var image: Data? = nil
    /// The site's icon, in any format ImageIO reads.
    var icon: Data? = nil
}

/// What is kept of a link's page: its title, picture and icon, and when to load it again.
struct KeptLinkPreview: Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// The page gave a title, a picture, or both, and maybe its site's icon.
        case loaded
        /// The page gave nothing to show: no title and no picture. An icon alone is nothing to show.
        case empty
        /// Loading the page failed, and nothing was loaded before.
        case failed
    }

    var outcome: Outcome
    var title: String?
    /// The picture, no larger than was asked for on its longer side.
    var image: CGImage?
    var icon: CGImage?
    /// When the page was loaded, or loading it failed.
    var date: Date
    /// When to load the page again: a month after it was loaded, a day after it gave nothing, or when a failure says.
    var retryAfter: Date
}

/// Keeps the previews of links on disk, in a folder of its own, where they can be removed at any time and loaded
/// again: they are derived from the pages, not the library's content. Each is kept under a hash of its link's address,
/// so no file name holds an address: a record, the picture made no larger than 1,200 pixels on its longer side (a JPEG,
/// or a PNG where it has transparency), and the icon no larger than 64 pixels. Pictures are decoded and scaled here,
/// off the main thread. A preview unused for 30 days goes, and so do the least recently used ones while all of them
/// take more than the byte limit.
actor LinkPreviewStore {
    /// The longest side, in pixels, of a picture as it is kept.
    static let largestPicture = 1_200
    /// The longest side, in pixels, of an icon as it is kept.
    static let largestIcon = 64

    private struct Record: Codable {
        var version: Int
        var outcome: KeptLinkPreview.Outcome
        var title: String?
        var date: Date
        var retryAfter: Date
        var lastUsed: Date
    }

    private let directory: URL
    private let byteLimit: Int
    private let unusedLimit: TimeInterval
    private let largestPictureBytes: Int
    /// A picture with more pixels than this isn't read: a small file can claim to be a vast picture.
    private let mostPixels: Int
    private let now: @Sendable () -> Date
    /// Previews kept for a generation before this one are dropped: they were under way when everything was removed.
    private var firstGeneration = 0

    /// `byteLimit` is what all the previews may take; `largestPictureBytes` is the largest picture or icon read, as a
    /// website sent it, and `mostPixels` the most pixels it may have.
    init(directory: URL, byteLimit: Int = 64 * 1024 * 1024, unusedLimit: TimeInterval = 30 * 86_400,
         largestPictureBytes: Int = 8 * 1024 * 1024, mostPixels: Int = 60_000_000,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.unusedLimit = unusedLimit
        self.largestPictureBytes = largestPictureBytes
        self.mostPixels = mostPixels
        self.now = now
    }

    /// The name, without an extension, of the files a preview is kept in: the SHA-256 of its key, in hexadecimal.
    nonisolated static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The preview kept for `key`, with its picture no larger than `imagePixels` on its longer side, or nil. Reading it
    /// counts as using it. A record that can't be read goes, with its pictures.
    func kept(for key: String, imagePixels: Int) -> KeptLinkPreview? {
        let name = Self.fileName(for: key)
        guard let data = try? Data(contentsOf: file(name, "json")) else { return nil }
        guard var record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1 else {
            remove(name)
            return nil
        }
        // Used is written at most once a day, so that showing a card doesn't write each time.
        if now().timeIntervalSince(record.lastUsed) > 86_400 {
            record.lastUsed = now()
            write(record, name)
        }
        return preview(of: record, name: name, imagePixels: imagePixels)
    }

    /// Counts the preview kept for `key` as used now, as a card that shows it from memory does; at most once a day.
    func touch(_ key: String) {
        let name = Self.fileName(for: key)
        guard let data = try? Data(contentsOf: file(name, "json")),
              var record = try? JSONDecoder().decode(Record.self, from: data),
              now().timeIntervalSince(record.lastUsed) > 86_400 else { return }
        record.lastUsed = now()
        write(record, name)
    }

    /// Keeps what was loaded for `key` and returns it as `kept(for:imagePixels:)` would. A title of white space alone
    /// is none; a picture that can't be read, or is too large, is left out. With neither, the page gave nothing to
    /// show, and its icon isn't kept. Nothing is read or written for a `generation` before the last
    /// `removeAll(before:)`; a caller that gives none is never too late.
    @discardableResult
    func keep(_ metadata: LinkPageMetadata, for key: String, imagePixels: Int,
              generation: Int? = nil) -> KeptLinkPreview {
        let date = now()
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let generation, generation < firstGeneration {
            return KeptLinkPreview(outcome: .empty, title: title, date: date, retryAfter: date)
        }
        let name = Self.fileName(for: key)
        let picture = metadata.image.flatMap { scaled($0, to: Self.largestPicture) }
        let loaded = title != nil || picture != nil
        let icon = loaded ? metadata.icon.flatMap { scaled($0, to: Self.largestIcon) } : nil
        let record = Record(version: 1, outcome: loaded ? .loaded : .empty, title: title, date: date,
                            retryAfter: date.addingTimeInterval(loaded ? 30 * 86_400 : 86_400), lastUsed: date)
        remove(name)
        if let picture { try? write(picture, to: file(name, "image")) }
        if let icon { try? write(icon, to: file(name, "icon")) }
        write(record, name)
        return preview(of: record, name: name, imagePixels: imagePixels)
    }

    /// Keeps that loading `key`'s page failed, to be tried again after `retryAfter`, and returns it as
    /// `kept(for:imagePixels:)` would. What was loaded before stays, to be shown meanwhile, and counts as used. Nothing
    /// is written for a generation before the last `removeAll(before:)`.
    @discardableResult
    func keepFailure(for key: String, retryAfter: Date, imagePixels: Int = 480,
                     generation: Int? = nil) -> KeptLinkPreview {
        let name = Self.fileName(for: key)
        let date = now()
        var record = (try? Data(contentsOf: file(name, "json")))
            .flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
            ?? Record(version: 1, outcome: .failed, title: nil, date: date, retryAfter: retryAfter, lastUsed: date)
        if record.outcome != .loaded {
            record.outcome = .failed
            record.title = nil
            record.date = date
        }
        record.retryAfter = retryAfter
        // It was asked for, so it is in use: a preview whose page keeps failing to load is still shown.
        record.lastUsed = date
        if let generation, generation < firstGeneration {
            return KeptLinkPreview(outcome: record.outcome, title: nil, date: date, retryAfter: retryAfter)
        }
        write(record, name)
        return preview(of: record, name: name, imagePixels: imagePixels)
    }

    /// Removes every preview. Previews kept afterwards for a generation before `generation` aren't written. One centre
    /// numbers the generations of a store.
    func removeAll(before generation: Int = 0) {
        firstGeneration = max(firstGeneration, generation)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes the previews unused for longer than the limit, then the least recently used ones while all of them take
    /// more than the byte limit, and files that belong to no record.
    func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        var sizes: [String: Int] = [:]
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            sizes[name, default: 0] += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var entries: [(name: String, lastUsed: Date, size: Int)] = []
        for (name, size) in sizes {
            guard let data = try? Data(contentsOf: file(name, "json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  now().timeIntervalSince(record.lastUsed) <= unusedLimit
            else {
                remove(name)
                continue
            }
            entries.append((name, record.lastUsed, size))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > byteLimit {
            remove(entry.name)
            total -= entry.size
        }
    }

    // MARK: Files

    private func file(_ name: String, _ pathExtension: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
    }

    private func write(_ record: Record, _ name: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(record) else { return }
        try? write(data, to: file(name, "json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func remove(_ name: String) {
        for pathExtension in ["json", "image", "icon"] {
            try? FileManager.default.removeItem(at: file(name, pathExtension))
        }
    }

    private func preview(of record: Record, name: String, imagePixels: Int) -> KeptLinkPreview {
        let fileManager = FileManager.default
        let picture = file(name, "image")
        let icon = file(name, "icon")
        return KeptLinkPreview(
            outcome: record.outcome, title: record.title,
            image: fileManager.fileExists(atPath: picture.path)
                ? Self.image(at: picture, imagePixels: imagePixels) : nil,
            icon: fileManager.fileExists(atPath: icon.path) ? Self.image(at: icon, imagePixels: Self.largestIcon) : nil,
            date: record.date, retryAfter: record.retryAfter)
    }

    // MARK: Pictures

    /// `data` decoded and made no larger than `largest` pixels on its longer side, then encoded: as a PNG where it has
    /// transparency, otherwise a JPEG. Nil when it is larger than the byte limit, can't be read, or claims too many
    /// pixels.
    private func scaled(_ data: Data, to largest: Int) -> Data? {
        guard data.count <= largestPictureBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= mostPixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: largest,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = opaque ? UTType.jpeg : UTType.png
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   opaque ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    /// The picture in the file at `url`, no larger than `imagePixels` on its longer side.
    private static func image(at url: URL, imagePixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(of: source, imagePixels: imagePixels)
    }

    private static func thumbnail(of source: CGImageSource, imagePixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imagePixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
