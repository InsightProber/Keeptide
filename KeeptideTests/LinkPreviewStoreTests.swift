import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

final class LinkPreviewStoreTests: XCTestCase {
    private var directory: URL!
    private let clock = LinkTestClock()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-link-previews-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPageKeptIsReadBackWithItsTitleAndAPictureNoLargerThanAsked() async throws {
        let store = makeStore()
        let page = LinkPageMetadata(title: "Synthetic Page", image: try LinkTestImages.png(width: 2_400, height: 1_260),
                                icon: try LinkTestImages.png(width: 256, height: 256))
        let kept = await store.keep(page, for: "https://example.com/", imagePixels: 640)
        XCTAssertEqual(kept.outcome, .loaded)
        XCTAssertEqual(kept.title, "Synthetic Page")
        try assertPicture(kept.image, longerSide: 640, aspect: 2_400.0 / 1_260)
        try assertPicture(kept.icon, longerSide: 64, aspect: 1)

        // It is there for a store opened later.
        let read = await makeStore().kept(for: "https://example.com/", imagePixels: 480)
        XCTAssertEqual(read?.outcome, .loaded)
        XCTAssertEqual(read?.title, "Synthetic Page")
        try assertPicture(read?.image, longerSide: 480, aspect: 2_400.0 / 1_260)
        let other = await makeStore().kept(for: "https://example.com/other", imagePixels: 480)
        XCTAssertNil(other)
    }

    func testThePictureIsKeptNoLargerThan1200PixelsAndAPhotoAsJPEG() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Photo", image: try LinkTestImages.png(width: 3_000, height: 1_500)),
                         for: "https://example.com/photo", imagePixels: 480)
        let read = await store.kept(for: "https://example.com/photo", imagePixels: 4_000)
        try assertPicture(read?.image, longerSide: 1_200, aspect: 2)
        let pictures = try files().filter { $0.pathExtension == "image" }
        XCTAssertEqual(pictures.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(pictures[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testAPictureWithTransparencyKeepsIt() async throws {
        let store = makeStore()
        let logo = try LinkTestImages.png(width: 300, height: 200, opaque: false)
        await store.keep(LinkPageMetadata(title: "Logo", image: logo),
                         for: "https://example.com/logo", imagePixels: 480)
        let picture = try XCTUnwrap(files().first { $0.pathExtension == "image" })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(picture as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
    }

    func testAPageWithNothingToShowIsKeptAsEmpty() async throws {
        let store = makeStore()
        for (index, page) in [LinkPageMetadata(title: nil), LinkPageMetadata(title: "  \n ")].enumerated() {
            let kept = await store.keep(page, for: "https://example.com/\(index)", imagePixels: 480)
            XCTAssertEqual(kept.outcome, .empty)
            XCTAssertNil(kept.title)
        }
        // An icon alone is nothing to show, and isn't kept.
        let iconOnly = await store.keep(LinkPageMetadata(icon: try LinkTestImages.png(width: 64, height: 64)),
                                        for: "https://example.com/icon", imagePixels: 480)
        XCTAssertEqual(iconOnly.outcome, .empty)
        XCTAssertNil(iconOnly.icon)
        XCTAssertFalse(try files().contains { $0.pathExtension == "icon" })
        // A title alone is something to show.
        let titled = await store.keep(LinkPageMetadata(title: " Only a Title "), for: "https://example.com/t",
                                      imagePixels: 480)
        XCTAssertEqual(titled.outcome, .loaded)
        XCTAssertEqual(titled.title, "Only a Title")
        XCTAssertNil(titled.image)
    }

    func testAPictureThatCantBeReadOrIsTooLargeIsLeftOut() async throws {
        let store = makeStore(largestPictureBytes: 2_000)
        let unreadable = await store.keep(LinkPageMetadata(title: "A", image: Data("not a picture".utf8)),
                                          for: "https://example.com/a", imagePixels: 480)
        XCTAssertEqual(unreadable.title, "A")
        XCTAssertNil(unreadable.image)
        let large = try LinkTestImages.png(width: 900, height: 900, noise: true)
        XCTAssertGreaterThan(large.count, 2_000)
        let tooLarge = await store.keep(LinkPageMetadata(title: "B", image: large), for: "https://example.com/b",
                                        imagePixels: 480)
        XCTAssertNil(tooLarge.image)
        XCTAssertEqual(tooLarge.outcome, .loaded)
    }

    func testAPictureClaimingMorePixelsThanTheMostIsLeftOut() async throws {
        let store = LinkPreviewStore(directory: directory, mostPixels: 10_000, now: { [clock] in clock.now })
        let vast = try LinkTestImages.png(width: 200, height: 200)
        let kept = await store.keep(LinkPageMetadata(title: "Vast", image: vast),
                                    for: "https://example.com/vast", imagePixels: 480)
        XCTAssertNil(kept.image)
        XCTAssertEqual(kept.title, "Vast")
    }

    func testUseIsWrittenAtMostOnceADay() async throws {
        let store = makeStore()
        let key = "https://example.com/used"
        await store.keep(LinkPageMetadata(title: "Used"), for: key, imagePixels: 480)
        let record = directory.appendingPathComponent(LinkPreviewStore.fileName(for: key) + ".json")
        let written = try Data(contentsOf: record)
        clock.advance(by: 12 * 3_600)
        _ = await store.kept(for: key, imagePixels: 480)
        await store.touch(key)
        XCTAssertEqual(try Data(contentsOf: record), written, "Not again within the day")
        clock.advance(by: 13 * 3_600)
        _ = await store.kept(for: key, imagePixels: 480)
        let read = try Data(contentsOf: record)
        XCTAssertNotEqual(read, written)
        // A preview shown from memory counts as used too.
        clock.advance(by: 2 * 86_400)
        await store.touch(key)
        XCTAssertNotEqual(try Data(contentsOf: record), read)
    }

    func testTrimRemovesRecordsThatCantBeReadAndFilesOfNoRecord() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Kept"), for: "https://example.com/kept", imagePixels: 480)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let broken = directory.appendingPathComponent(LinkPreviewStore.fileName(for: "https://example.com/b") + ".json")
        try Data("{ not json".utf8).write(to: broken)
        let stray = directory.appendingPathComponent(LinkPreviewStore.fileName(for: "https://example.com/s") + ".image")
        try LinkTestImages.png(width: 10, height: 10).write(to: stray)
        await store.trim()
        XCTAssertEqual(try files().map(\.lastPathComponent),
                       [LinkPreviewStore.fileName(for: "https://example.com/kept") + ".json"])
    }

    func testNoFileNameHoldsTheAddress() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Synthetic", image: try LinkTestImages.png(width: 120, height: 60)),
                         for: "https://example.com/private-path", imagePixels: 480)
        for file in try files() {
            XCTAssertFalse(file.lastPathComponent.contains("example"), file.lastPathComponent)
            XCTAssertFalse(file.lastPathComponent.contains("private"), file.lastPathComponent)
        }
        XCTAssertFalse(try files().isEmpty)
    }

    func testRefreshAndRetryTimes() async throws {
        let store = makeStore()
        let loaded = await store.keep(LinkPageMetadata(title: "T"), for: "https://example.com/l", imagePixels: 480)
        XCTAssertEqual(loaded.retryAfter, clock.now.addingTimeInterval(30 * 86_400))
        let empty = await store.keep(LinkPageMetadata(), for: "https://example.com/e", imagePixels: 480)
        XCTAssertEqual(empty.retryAfter, clock.now.addingTimeInterval(86_400))
        let soon = clock.now.addingTimeInterval(600)
        let failed = await store.keepFailure(for: "https://example.com/f", retryAfter: soon)
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.retryAfter, soon)
        let readFailure = await store.kept(for: "https://example.com/f", imagePixels: 480)
        XCTAssertEqual(readFailure?.outcome, .failed)
        XCTAssertEqual(readFailure?.retryAfter, soon)
    }

    func testAFailureKeepsWhatWasLoadedBefore() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Before", image: try LinkTestImages.png(width: 200, height: 100)),
                         for: "https://example.com/", imagePixels: 480)
        clock.advance(by: 31 * 86_400)
        let later = clock.now.addingTimeInterval(600)
        let kept = await store.keepFailure(for: "https://example.com/", retryAfter: later)
        XCTAssertEqual(kept.outcome, .loaded)
        XCTAssertEqual(kept.title, "Before")
        XCTAssertNotNil(kept.image)
        XCTAssertEqual(kept.retryAfter, later)
        let read = await makeStore().kept(for: "https://example.com/", imagePixels: 480)
        XCTAssertEqual(read?.title, "Before")
        XCTAssertEqual(read?.retryAfter, later)
    }

    func testAPreviewWhosePageFailsToLoadAgainStillCountsAsUsed() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Shown"), for: "https://example.com/", imagePixels: 480)
        clock.advance(by: 31 * 86_400)
        _ = await store.keepFailure(for: "https://example.com/", retryAfter: clock.now.addingTimeInterval(600))
        clock.advance(by: 20 * 86_400)
        await store.trim()
        let kept = await store.kept(for: "https://example.com/", imagePixels: 480)
        XCTAssertEqual(kept?.title, "Shown")
    }

    func testEntriesUnusedFor30DaysAreRemoved() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Old"), for: "https://example.com/old", imagePixels: 480)
        clock.advance(by: 20 * 86_400)
        await store.keep(LinkPageMetadata(title: "Used"), for: "https://example.com/used", imagePixels: 480)
        await store.keep(LinkPageMetadata(title: "Seen"), for: "https://example.com/seen", imagePixels: 480)
        clock.advance(by: 9 * 86_400)
        // Seeing a preview counts as using it.
        _ = await store.kept(for: "https://example.com/seen", imagePixels: 480)
        clock.advance(by: 25 * 86_400)
        await store.trim()
        let old = await store.kept(for: "https://example.com/old", imagePixels: 480)
        let used = await store.kept(for: "https://example.com/used", imagePixels: 480)
        let seen = await store.kept(for: "https://example.com/seen", imagePixels: 480)
        XCTAssertNil(old)
        XCTAssertNil(used)
        XCTAssertEqual(seen?.title, "Seen")
        XCTAssertEqual(try files().filter { $0.pathExtension == "json" }.count, 1)
    }

    func testBeyondTheSizeLimitTheLeastRecentlyUsedGoFirst() async throws {
        let picture = try LinkTestImages.png(width: 400, height: 400, noise: true)
        let probe = makeStore()
        await probe.keep(LinkPageMetadata(title: "Entry-0", image: picture), for: "https://example.com/probe",
                         imagePixels: 480)
        let entrySize = try files().reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        await probe.removeAll()

        let store = makeStore(byteLimit: entrySize * 3 + entrySize / 2)
        for name in ["a", "b", "c"] {
            await store.keep(LinkPageMetadata(title: "Entry-\(name)", image: picture),
                             for: "https://example.com/\(name)",
                             imagePixels: 480)
            clock.advance(by: 3_600)
        }
        clock.advance(by: 2 * 86_400)
        _ = await store.kept(for: "https://example.com/a", imagePixels: 480)
        clock.advance(by: 3_600)
        await store.keep(LinkPageMetadata(title: "Entry-d", image: picture), for: "https://example.com/d",
                         imagePixels: 480)
        await store.trim()
        var remaining: [String] = []
        for name in ["a", "b", "c", "d"] {
            if await store.kept(for: "https://example.com/\(name)", imagePixels: 480) != nil { remaining.append(name) }
        }
        XCTAssertEqual(remaining, ["a", "c", "d"])
    }

    func testRemovingAllLeavesNothing() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "T", image: try LinkTestImages.png(width: 100, height: 100)),
                         for: "https://example.com/", imagePixels: 480)
        await store.removeAll()
        let read = await store.kept(for: "https://example.com/", imagePixels: 480)
        XCTAssertNil(read)
        XCTAssertEqual(try files(), [])
    }

    func testKeepingForAnEarlierGenerationAfterRemovingAllKeepsNothing() async throws {
        let store = makeStore()
        await store.removeAll(before: 2)
        await store.keep(LinkPageMetadata(title: "Late"), for: "https://example.com/late",
                         imagePixels: 480, generation: 1)
        _ = await store.keepFailure(for: "https://example.com/late2", retryAfter: clock.now, generation: 1)
        XCTAssertEqual(try files(), [])
        await store.keep(LinkPageMetadata(title: "Now"), for: "https://example.com/now",
                         imagePixels: 480, generation: 2)
        let now = await store.kept(for: "https://example.com/now", imagePixels: 480)
        XCTAssertEqual(now?.title, "Now")
        // A caller that gives no generation is never too late.
        await store.keep(LinkPageMetadata(title: "Any"), for: "https://example.com/any", imagePixels: 480)
        let any = await store.kept(for: "https://example.com/any", imagePixels: 480)
        XCTAssertEqual(any?.title, "Any")
    }

    func testABrokenRecordReadsAsNothingAndGoes() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "T", image: try LinkTestImages.png(width: 100, height: 100)),
                         for: "https://example.com/", imagePixels: 480)
        let record = directory.appendingPathComponent(LinkPreviewStore.fileName(for: "https://example.com/") + ".json")
        try Data("{ not json".utf8).write(to: record)
        let read = await store.kept(for: "https://example.com/", imagePixels: 480)
        XCTAssertNil(read)
        XCTAssertEqual(try files(), [])
    }

    // MARK: Helpers

    private func makeStore(byteLimit: Int = 64 * 1024 * 1024,
                           largestPictureBytes: Int = 8 * 1024 * 1024) -> LinkPreviewStore {
        LinkPreviewStore(directory: directory, byteLimit: byteLimit, largestPictureBytes: largestPictureBytes,
                         now: { [clock] in clock.now })
    }

    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func assertPicture(_ image: CGImage?, longerSide: Int, aspect: Double,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, file: file, line: line)
        XCTAssertEqual(max(image.width, image.height), longerSide, file: file, line: line)
        XCTAssertEqual(Double(image.width) / Double(image.height), aspect, accuracy: 0.02, file: file, line: line)
    }
}

/// A clock a test moves by hand.
final class LinkTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Synthetic pictures, drawn here, for link previews.
enum LinkTestImages {
    static func png(width: Int, height: Int, opaque: Bool = true, noise: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: opaque ? 1 : 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise {
            // Pixels that don't compress, so the picture is as large as its size makes it.
            var generator = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    context.setFillColor(CGColor(srgbRed: .random(in: 0...1, using: &generator),
                                                 green: .random(in: 0...1, using: &generator),
                                                 blue: .random(in: 0...1, using: &generator), alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
