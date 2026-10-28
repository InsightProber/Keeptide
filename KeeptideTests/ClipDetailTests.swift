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

    func testLinkCountsTheFullURL() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = makeService(harness)
        let url = "https://developer.apple.com/documentation/appkit/nspanel"
        let ref = try await insert([[("public.url", Data(url.utf8)), ("public.utf8-plain-text", Data(url.utf8))]],
                                   into: harness)

        let detail = try await service.detail(for: ref, kind: .url, frameSize: stripFrame)

        XCTAssertEqual(detail.characterCount, 56)
        XCTAssertEqual(detail.excerpt, url)
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
        XCTAssertLessThanOrEqual(thumbnail.width, 1200)
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

    private func makeService(_ harness: SearchHarness, probe: ReadProbe? = nil) -> PreviewService {
        let repository = ContentRepository(controller: harness.controller)
        return PreviewService(read: { ref in
            await probe?.enter()
            return try await repository.read(ref)
        })
    }

    private func insert(_ items: [[(String, Data)]], into harness: SearchHarness) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture(items)
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        return ContentStoreFixtures.ref(item, capture)
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
