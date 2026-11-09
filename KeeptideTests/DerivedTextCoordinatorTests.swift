import CoreGraphics
import XCTest
@testable import Keeptide

/// Derived text made for items and kept beside them: one job per item and operation, saved once when it ends, against
/// a real temporary store and a recognizer the test drives.
@MainActor
final class DerivedTextCoordinatorTests: XCTestCase {
    private let info = GenerationInfo(engine: "On this Mac", model: "test")

    func testRecognizedTextIsSavedBesideItsItemWhenTheJobFinishes() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        let job = try XCTUnwrap(coordinator.extractText(from: source, keepingLineBreaks: false))

        XCTAssertEqual(job.lane, .onDevice)
        XCTAssertEqual(job.priority, .user)
        XCTAssertTrue(coordinator.job(for: source, operation: .extractText) === job)
        XCTAssertNil(coordinator.job(for: source, operation: .translate))
        let engine = try await started(recognizer, 0)
        engine.send(.started(info), .delta("Quarterly plan"), .finished(.completed))
        await waitUntil("the result is saved") { coordinator.outcome(for: source, operation: .extractText) != nil }
        guard case .saved(let saved)? = coordinator.outcome(for: source, operation: .extractText) else {
            return XCTFail("\(String(describing: coordinator.outcome(for: source, operation: .extractText)))")
        }
        XCTAssertEqual(saved.text, "Quarterly plan")
        XCTAssertEqual(saved.operation, .extractText)
        XCTAssertFalse(saved.keepsLineBreaks)
        XCTAssertEqual(recognizer.layouts, [false])
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read, saved)
        XCTAssertNil(coordinator.job(for: source, operation: .extractText), "The job leaves when it ends")
    }

    func testAnImageWithoutTextIsRememberedAndNothingIsSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Blank", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .finished(.completed))

        await waitUntil("the job ended") { coordinator.outcome(for: source, operation: .extractText) != nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .noText)
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testAFailureIsRememberedAndNothingIsSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Damaged", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")

        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info))
        engine.end(throwing: failure)

        await waitUntil("the job ended") { coordinator.outcome(for: source, operation: .extractText) != nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .failed(failure))
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testStoppingAJobLeavesTheEarlierResult() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first result is saved") {
            coordinator.outcome(for: source, operation: .extractText) != nil
        }

        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        second.send(.started(info))
        coordinator.stop(source, operation: .extractText)

        await waitUntil("the second job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        await waitUntil("its ending is taken in") { coordinator.outcome(for: source, operation: .extractText) == nil }
        XCTAssertTrue(second.wasCancelled)
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Total 12.80")
        XCTAssertEqual(read?.keepsLineBreaks, true)
    }

    func testANewerRequestReplacesTheOneUnderWay() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Poster", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractText(from: source, keepingLineBreaks: true)
        let first = try await started(recognizer, 0)
        first.send(.started(info))
        coordinator.extractText(from: source, keepingLineBreaks: false)

        let second = try await started(recognizer, 1)
        await waitUntil("the first job is stopped") { first.wasCancelled }
        second.send(.started(info), .delta("Newer"), .finished(.completed))
        await waitUntil("the newer result is saved") {
            if case .saved? = coordinator.outcome(for: source, operation: .extractText) { return true }
            return false
        }
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Newer")
        XCTAssertEqual(read?.keepsLineBreaks, false)
    }

    func testAResultForAnotherStoreGenerationIsNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Generation", into: controller)
        let current = try await controller.identity()
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(
            controller, store, recognizer, identity: StoreIdentity(storeID: current.storeID, generation: UUID()))

        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Late"), .finished(.completed))

        await waitUntil("the job ended") { coordinator.outcome(for: source, operation: .extractText) != nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .failed(.contentUnavailable))
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testTextTheLibraryCouldNotKeepIsSaidToBeNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Unwritable", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)

        try await controller.close()
        engine.send(.started(info), .delta("Kept nowhere"), .finished(.completed))

        await waitUntil("the job ended") { coordinator.outcome(for: source, operation: .extractText) != nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .notSaved)
    }

    func testNothingIsSavedOrStartedOnceTheLibraryCloses() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Closing", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info), .delta("Half"))

        await coordinator.stopAndDrain()

        await waitUntil("the job is stopped") { engine.wasCancelled }
        await waitUntil("the job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertNil(coordinator.extractText(from: source, keepingLineBreaks: true))
        XCTAssertEqual(recognizer.layouts.count, 1, "No new recognition starts")
        XCTAssertNil(coordinator.outcome(for: source, operation: .extractText))
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testTheRecognizerReadsTheItemsImage() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Photo", into: controller)
        let recognizer = ScriptedRecognizer()
        let reads = ReadLog()
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let coordinator = try await makeCoordinator(controller, store, recognizer) { ref in
            reads.record(ref)
            return image
        }

        coordinator.extractText(from: source, keepingLineBreaks: true)
        _ = try await started(recognizer, 0)
        let read = try await recognizer.image(0)()

        XCTAssertEqual(reads.refs, [source])
        XCTAssertEqual(read.width, 4)
    }

    func testTheEnginesTierDecidesTheLane() async throws {
        XCTAssertEqual(EngineTier.onThisMac.lane, .onDevice)
        XCTAssertEqual(EngineTier.appleIntelligence.lane, .onDevice)
        XCTAssertEqual(EngineTier.cloud.lane, .cloud)
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Cloud", into: controller)
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(tier: .cloud))

        let job = coordinator.extractText(from: source, keepingLineBreaks: true)

        XCTAssertEqual(job?.lane, .cloud)
    }

    // MARK: Helpers

    private func makeStore() async throws -> (PersistenceController, DerivedTextStore) {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, DerivedTextStore(controller: controller))
    }

    private func makeCoordinator(
        _ controller: PersistenceController, _ store: DerivedTextStore, _ recognizer: ScriptedRecognizer,
        identity: StoreIdentity? = nil,
        image: @escaping @Sendable (ContentRef) async throws -> CGImage = { _ in
            throw PreviewLoadError.couldNotDecodeImage
        }
    ) async throws -> DerivedTextCoordinator {
        let current = try await controller.identity()
        let coordinator = DerivedTextCoordinator(store: store, identity: identity ?? current, recognizer: recognizer,
                                                 image: image)
        addTeardownBlock { await coordinator.stopAndDrain() }
        return coordinator
    }

    /// A synthetic text clip copied a moment ago. The store keeps results for any current item, so a text clip stands
    /// in for an image here.
    private func insertClip(_ text: String, into controller: PersistenceController) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ItemValue(title: text, captureID: capture.id, historyEligible: true, lastCopiedAt: Date(),
                             copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// The recognizer's `index`th source, once its job has started reading it.
    private func started(_ recognizer: ScriptedRecognizer, _ index: Int) async throws -> ControlledSource {
        await waitUntil("source \(index) is read") { (recognizer.source(index)?.startCount ?? 0) > 0 }
        return try XCTUnwrap(recognizer.source(index))
    }
}

/// A recognizer whose sources a test drives by hand. It records what it was asked for.
private final class ScriptedRecognizer: TextRecognitionEngine, @unchecked Sendable {
    let tier: EngineTier
    private let lock = NSLock()
    private var requests: [(source: ControlledSource, image: @Sendable () async throws -> CGImage, keeps: Bool)] = []

    init(tier: EngineTier = .onThisMac) {
        self.tier = tier
    }

    func recognizeText(in image: @escaping @Sendable () async throws -> CGImage,
                       keepingLineBreaks: Bool) -> any GenerationSource {
        let source = ControlledSource()
        lock.withLock { requests.append((source, image, keepingLineBreaks)) }
        return source
    }

    var layouts: [Bool] { lock.withLock { requests.map(\.keeps) } }

    func source(_ index: Int) -> ControlledSource? {
        lock.withLock { index < requests.count ? requests[index].source : nil }
    }

    func image(_ index: Int) -> @Sendable () async throws -> CGImage {
        lock.withLock { requests[index].image }
    }
}

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [ContentRef] = []

    var refs: [ContentRef] { lock.withLock { read } }

    func record(_ ref: ContentRef) {
        lock.withLock { read.append(ref) }
    }
}
