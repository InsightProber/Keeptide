import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

/// A strip frame in pixels, the way the strip asks for details: points times two.
private let stripFrame = CGSize(width: 328, height: 218)

final class ClipDetailTests: XCTestCase {
    func testTextDetailCountsGraphemesAndExcerpts() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)

        let chinese = "统一用 UTC 存储时间，显示时再转换为本地时区。"
        let chineseDetail = try await textDetail(chinese, in: harness, using: service)
        XCTAssertEqual(chineseDetail.characterCount, 25)
        XCTAssertEqual(chineseDetail.excerpt, chinese)

        // A family emoji is one character made of several scalars.
        let family = try await textDetail("a👩‍👩‍👧b", in: harness, using: service)
        XCTAssertEqual(family.characterCount, 3)

        let long = try await textDetail(String(repeating: "x", count: 1000), in: harness, using: service)
        XCTAssertEqual(long.excerpt?.count, 300)
        XCTAssertEqual(long.characterCount, 1000)

        // The excerpt starts at the first visible character; the count still includes the whitespace.
        let padded = try await textDetail("\n  \t " + String(repeating: "y", count: 400), in: harness, using: service)
        XCTAssertEqual(padded.excerpt, String(repeating: "y", count: 300))
        XCTAssertEqual(padded.characterCount, 405)
    }

    func testLargeTextIsReadAndCountedOnce() async throws {
        let harness = try SearchHarness.make(in: self)
        let probe = ReadProbe()
        let service = makeService(harness, probe: probe)
        // Four bytes and two characters per repetition, so a count of bytes would not pass.
        let repetitions = 5 * 1024 * 1024 / 4
        let text = String(repeating: "€a", count: repetitions)
        XCTAssertEqual(text.utf8.count, 5 * 1024 * 1024)
        let ref = try await insert([[("public.utf8-plain-text", Data(text.utf8))]], into: harness)

        let first = try await service.detail(for: ref, kind: .text, frameSize: stripFrame)
        let second = try await service.detail(for: ref, kind: .text, frameSize: stripFrame)

        XCTAssertEqual(first.characterCount, 2 * repetitions)
        XCTAssertEqual(second, first)
        let reads = await probe.reads
        XCTAssertEqual(reads, 1)
    }

    func testTextIsNotReadAgainWhenTheSystemEmptiesItsCache() async throws {
        let harness = try SearchHarness.make(in: self)
        let probe = ReadProbe()
        let imageCache = NSCache<AnyObject, AnyObject>()
        let service = makeService(harness, probe: probe, cache: ThumbnailCache(imageCache: imageCache))
        let textRef = try await insert([[("public.utf8-plain-text", Data("Synthetic text".utf8))]], into: harness)
        let imageRef = try await insert([[("public.png", try png(width: 40, height: 30))]], into: harness)
        let text = try await service.detail(for: textRef, kind: .text, frameSize: stripFrame)
        _ = try await service.detail(for: imageRef, kind: .image, frameSize: stripFrame)
        let readsBefore = await probe.reads
        XCTAssertEqual(readsBefore, 2)

        // The system may empty an NSCache whenever memory runs short; here it happens all at once.
        imageCache.removeAllObjects()
        let textAgain = try await service.detail(for: textRef, kind: .text, frameSize: stripFrame)
        _ = try await service.detail(for: imageRef, kind: .image, frameSize: stripFrame)

        // Only the image is read again: its thumbnail was in the cache that was emptied, the text was not.
        XCTAssertEqual(textAgain, text)
        let readsAfter = await probe.reads
        XCTAssertEqual(readsAfter, 3)
    }

    func testLinkCountsTheFullURL() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let url = "https://developer.apple.com/documentation/appkit/nspanel"
        // The plain text stored before the URL is a title, which is not the link.
        let ref = try await insert(
            [[("public.utf8-plain-text", Data("Apple Developer".utf8)), ("public.url", Data(url.utf8))]], into: harness)

        let detail = try await service.detail(for: ref, kind: .url, frameSize: stripFrame)

        XCTAssertEqual(detail.characterCount, 56)
        XCTAssertEqual(detail.excerpt, url)

        // A newline after the URL is not part of it.
        let paddedRef = try await insert([[("public.url", Data(" \(url)\r\n".utf8))]], into: harness)
        let padded = try await service.detail(for: paddedRef, kind: .url, frameSize: stripFrame)
        XCTAssertEqual(padded.characterCount, 56)
        XCTAssertEqual(padded.excerpt, url)

        // The excerpt only keeps the start of a very long URL, such as a data URL; the count is of all of it.
        let long = "https://example.com/" + String(repeating: "a", count: 5_000)
        let longRef = try await insert([[("public.url", Data(long.utf8))]], into: harness)
        let longDetail = try await service.detail(for: longRef, kind: .url, frameSize: stripFrame)
        XCTAssertEqual(longDetail.characterCount, 5_020)
        XCTAssertEqual(longDetail.excerpt, String(long.prefix(2_048)))
        // None of these carries a page title.
        XCTAssertNil(detail.linkTitle)
        XCTAssertNil(longDetail.linkTitle)
    }

    func testLinkCarriesThePageTitleItWasCopiedWith() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let url = "https://git-scm.com/docs/git-rebase"
        let ref = try await insert(
            [[("public.url", Data(url.utf8)), ("public.url-name", Data(" Git - git-rebase Documentation\n".utf8))]],
            into: harness)

        let detail = try await service.detail(for: ref, kind: .url, frameSize: stripFrame)

        // The title is read as the link's text is, without the whitespace around it; the link is unchanged.
        XCTAssertEqual(detail.linkTitle, "Git - git-rebase Documentation")
        XCTAssertEqual(detail.excerpt, url)
        XCTAssertEqual(detail.characterCount, 35)

        // A title of only blanks is no title.
        let blankRef = try await insert([[("public.url", Data(url.utf8)), ("public.url-name", Data(" \n".utf8))]],
                                        into: harness)
        let blank = try await service.detail(for: blankRef, kind: .url, frameSize: stripFrame)
        XCTAssertNil(blank.linkTitle)

        // A text clip's detail never has one, whatever it holds.
        let textRef = try await insert(
            [[("public.utf8-plain-text", Data("Plain".utf8)), ("public.url-name", Data("Not a link".utf8))]], into: harness)
        let text = try await service.detail(for: textRef, kind: .text, frameSize: stripFrame)
        XCTAssertNil(text.linkTitle)
    }

    func testImageSizeComesFromTheHeaderAndThumbnailsCoverTheFrame() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let ref = try await insert([[("public.png", try png(width: 1200, height: 800))]], into: harness)

        let detail = try await service.detail(for: ref, kind: .image, frameSize: stripFrame)

        XCTAssertEqual(detail.pixelSize, CGSize(width: 1200, height: 800))
        XCTAssertTrue(detail.fillsFrame)
        let thumbnail = try XCTUnwrap(detail.thumbnail)
        XCTAssertGreaterThanOrEqual(thumbnail.width, 328)
        XCTAssertGreaterThanOrEqual(thumbnail.height, 218)
        // Just covering the frame, not decoded at the picture's own size: 328 × 219, give or take ImageIO's rounding.
        XCTAssertLessThanOrEqual(thumbnail.width, 329)
    }

    func testExtremeImagesFitInsteadOfFilling() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let wideRef = try await insert([[("public.png", try png(width: 4000, height: 10))]], into: harness)
        let tallRef = try await insert([[("public.png", try png(width: 10, height: 4000))]], into: harness)

        let wide = try await service.detail(for: wideRef, kind: .image, frameSize: stripFrame)
        let tall = try await service.detail(for: tallRef, kind: .image, frameSize: stripFrame)

        XCTAssertFalse(wide.fillsFrame)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wide.thumbnail).width, 328)
        XCTAssertFalse(tall.fillsFrame)
        XCTAssertLessThanOrEqual(try XCTUnwrap(tall.thumbnail).height, 218)
    }

    func testFileReferencesGiveNamesAndItemCountWithoutSize() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let capture = try ContentStoreFixtures.localReferenceCapture()
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insertLocalReference(item, capture, into: harness.controller)

        let detail = try await service.detail(for: ContentStoreFixtures.ref(item, capture), kind: .file,
                                              frameSize: stripFrame)

        XCTAssertEqual(detail.fileNames, ["report.txt"])
        XCTAssertEqual(detail.itemCount, 1)
        // A file clip holds a local reference, so there is no text and no image to measure.
        XCTAssertNil(detail.characterCount)
        XCTAssertNil(detail.pixelSize)
    }

    func testFinderFileReferencesTakeNamesFromTheFilenamesList() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        // Finder names its files by number in the URLs it writes, and lists their paths in the legacy filenames type.
        let list = try PropertyListSerialization.data(
            fromPropertyList: ["/Synthetic/Quarterly Report.pdf", "/Synthetic/notes.txt"], format: .xml, options: 0)
        let ref = try await insertLocalReferences([
            [("public.file-url", Data("file:///.file/id=6571367.1".utf8)), ("NSFilenamesPboardType", list)],
            [("public.file-url", Data("file:///.file/id=6571367.2".utf8))],
        ], into: harness)

        let detail = try await service.detail(for: ref, kind: .file, frameSize: stripFrame)

        XCTAssertEqual(detail.fileNames, ["Quarterly Report.pdf", "notes.txt"])
        XCTAssertEqual(detail.itemCount, 2)
    }

    func testFileReferenceURLResolvesToItsName() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideDetail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Synthetic Name.txt")
        try Data("synthetic".utf8).write(to: file)
        let reference = try fileReferenceString(for: file)
        let ref = try await insertLocalReferences([[("public.file-url", Data(reference.utf8))]], into: harness)

        let detail = try await service.detail(for: ref, kind: .file, frameSize: stripFrame)

        XCTAssertEqual(detail.fileNames, ["Synthetic Name.txt"])

        // Once the file is gone the reference names nothing, and that is no name at all.
        try FileManager.default.removeItem(at: file)
        let goneRef = try await insertLocalReferences([[("public.file-url", Data(reference.utf8))]], into: harness)
        let gone = try await service.detail(for: goneRef, kind: .file, frameSize: stripFrame)
        XCTAssertEqual(gone.fileNames, [])
        XCTAssertEqual(gone.itemCount, 1)
    }

    func testCancelledDetailDoesNotPopulateTheCache() async throws {
        let harness = try SearchHarness.make(in: self)
        let ref = try await insert([[("public.utf8-plain-text", Data("Synthetic".utf8))]], into: harness)
        // The read ignores cancellation, so only the service itself can notice it once the read returns.
        let content = try await ContentRepository(controller: harness.controller).read(ref)
        let probe = ReadProbe(holding: true)
        let service = PreviewService(read: { _ in
            await probe.enter()
            return content
        })

        let cancelled = Task { try await service.detail(for: ref, kind: .text, frameSize: stripFrame) }
        try await SearchTestSupport.waitUntil { await probe.reads == 1 }
        cancelled.cancel()
        await probe.release()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled call returned a detail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let detail = try await service.detail(for: ref, kind: .text, frameSize: stripFrame)

        XCTAssertEqual(detail.characterCount, 9)
        let reads = await probe.reads
        XCTAssertEqual(reads, 2)
    }

    func testRefusesContentThatIsNotComplete() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let capture = try ContentStoreFixtures.localReferenceCapture()
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insertLocalReference(item, capture, into: harness.controller)
        // Without its local file access the reference has to be relocated before it can be used.
        try await FileAccessStore(controller: harness.controller).remove(
            representationID: try XCTUnwrap(capture.representations.first).id,
            permit: StoreSafetyGate(controller: harness.controller).permit(.maintenance))
        let ref = ContentStoreFixtures.ref(item, capture)
        let content = try await ContentRepository(controller: harness.controller).read(ref)
        XCTAssertEqual(content.integrity, .requiresRelocation)

        do {
            _ = try await service.detail(for: ref, kind: .file, frameSize: stripFrame)
            XCTFail("Content that is not complete produced a detail")
        } catch {
            XCTAssertEqual(error as? PasteRefusal, .contentUnavailable)
        }
    }

    private func makeService(_ harness: SearchHarness, probe: ReadProbe? = nil,
                             cache: ThumbnailCache = ThumbnailCache()) -> PreviewService {
        let repository = ContentRepository(controller: harness.controller)
        return PreviewService(read: { ref in
            await probe?.enter()
            return try await repository.read(ref)
        }, cache: cache)
    }

    private func insert(_ items: [[(String, Data)]], into harness: SearchHarness) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture(items)
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// A clip of file references stored the way capture stores them: every representation a local
    /// reference, with its bytes kept in the file access state.
    private func insertLocalReferences(_ items: [[(String, Data)]], into harness: SearchHarness) async throws -> ContentRef {
        let captureID = UUID()
        var representations: [RepresentationValue] = []
        var access: [LocalFileAccess] = []
        for (itemIndex, item) in items.enumerated() {
            for (representationIndex, entry) in item.enumerated() {
                let representation = RepresentationValue(
                    snapshotID: captureID, itemIndex: itemIndex, representationIndex: representationIndex,
                    typeIdentifier: entry.0, storage: .localReference, byteCount: 0,
                    digest: LocalReferencePrivacy.makeRelocationToken(), bytes: nil)
                representations.append(representation)
                access.append(LocalFileAccess(id: representation.id, snapshotID: captureID, bytes: entry.1))
            }
        }
        let manifest = CaptureManifest(version: LocalReferencePrivacy.manifestVersion, itemCount: items.count,
                                       entries: representations.map(ManifestEntry.init))
        let capture = CaptureValue(id: captureID, manifest: manifest,
                                   digest: ContentDigest.sha256(try manifest.canonicalData()),
                                   representations: representations)
        let item = ContentStoreFixtures.item(capture)
        try await FileAccessStore(controller: harness.controller)
            .putPrepared(access, expecting: harness.controller.identity())
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// The file-reference form of a file's URL, `file:///.file/id=…`. From Swift on recent systems
    /// `(url as NSURL).fileReferenceURL()` returns an ordinary path URL, which would never exercise
    /// resolving a reference, so this asks Core Foundation. The assertion keeps the test from passing
    /// without a real reference.
    private func fileReferenceString(for file: URL) throws -> String {
        let url = try XCTUnwrap(CFURLCreateWithFileSystemPath(nil, file.path as CFString, .cfurlposixPathStyle, false))
        let reference = try XCTUnwrap(CFURLCreateFileReferenceURL(nil, url, nil)?.takeRetainedValue())
        let string = CFURLGetString(reference) as String
        XCTAssertTrue(string.hasPrefix("file:///.file/id="), "The file did not get a file-reference URL")
        return string
    }

    private func textDetail(_ text: String, in harness: SearchHarness, using service: PreviewService) async throws -> ClipDetail {
        let ref = try await insert([[("public.utf8-plain-text", Data(text.utf8))]], into: harness)
        return try await service.detail(for: ref, kind: .text, frameSize: stripFrame)
    }

    /// A synthetic PNG of the given size, drawn with Core Graphics.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// Counts the reads a service makes, and can hold them until the test lets them go.
private actor ReadProbe {
    private(set) var reads = 0
    private var isHolding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(holding: Bool = false) {
        isHolding = holding
    }

    func enter() async {
        reads += 1
        guard isHolding else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func release() {
        isHolding = false
        held.forEach { $0.resume() }
        held.removeAll()
    }
}
