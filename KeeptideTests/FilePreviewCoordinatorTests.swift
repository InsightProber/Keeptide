import CoreData
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class FilePreviewCoordinatorTests: XCTestCase {
    func testCancelWhileOpenIsPendingClosesLateLeaseExactlyOnceWithoutPublishing() async throws {
        let fixture = try await makeBoundFixture()
        let gate = PreviewOpenGate()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, gate: gate, platform: platform)

        coordinator.select(fixture.references[0])
        try await waitForEntry(gate)
        coordinator.cancel()
        await gate.open()
        try await waitForStop(platform)

        XCTAssertNil(coordinator.lease)
        XCTAssertNil(coordinator.reference)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testSelectionChangeWhileOpenIsPendingDropsLateLeaseAndKeepsNewSelection() async throws {
        let fixture = try await makeBoundFixture(representationCount: 2, boundIndexes: [0])
        let gate = PreviewOpenGate()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, gate: gate, platform: platform)

        coordinator.select(fixture.references[0])
        try await waitForEntry(gate)
        coordinator.select(fixture.references[1])
        await coordinator.settle()
        await gate.open()
        try await waitForStop(platform)

        XCTAssertNil(coordinator.lease)
        XCTAssertEqual(coordinator.reference?.representationID, fixture.references[1].representationID)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testExactRepresentationDeletionWhileOpenIsPendingCannotPublishLease() async throws {
        let fixture = try await makeBoundFixture()
        let gate = PreviewOpenGate()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, gate: gate, platform: platform)

        coordinator.select(fixture.references[0])
        try await waitForEntry(gate)
        try await deleteRepresentation(fixture.references[0].representationID, from: fixture.store)
        await gate.open()
        await coordinator.settle()

        XCTAssertNil(coordinator.lease)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testExactFacetMarkerWhileOpenIsPendingCannotPublishLease() async throws {
        let fixture = try await makeBoundFixture()
        let gate = PreviewOpenGate()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, gate: gate, platform: platform)

        coordinator.select(fixture.references[0])
        try await waitForEntry(gate)
        try await insertMarker(
            FacetDeletionMarkerValue(
                itemID: fixture.references[0].ref.itemID,
                facet: fixture.references[0].ref.facet,
                generationID: fixture.references[0].ref.version.rawValue
            ),
            into: fixture.store
        )
        await gate.open()
        await coordinator.settle()

        XCTAssertNil(coordinator.lease)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testConcurrentBookmarkBindingWhileOpenIsPendingDropsOldLease() async throws {
        let fixture = try await makeBoundFixture()
        let gate = PreviewOpenGate()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, gate: gate, platform: platform)
        let original = try XCTUnwrap(fixture.accesses[0])

        coordinator.select(fixture.references[0])
        try await waitForEntry(gate)
        var concurrent = original
        concurrent.bookmark = Data([0x99])
        concurrent.localPath = "/Synthetic/Concurrent.pdf"
        try await fixture.accessStore.put(concurrent, expecting: fixture.identity)
        await gate.open()
        await coordinator.settle()

        XCTAssertNil(coordinator.lease)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
        let stored = try await fixture.accessStore.read(representationID: original.id)
        XCTAssertEqual(stored, concurrent, "The late open must not replace a newer bookmark binding")
    }

    func testPublishedLeaseStaysOpenUntilViewOwnerClosesAfterCoordinatorCancel() async throws {
        let fixture = try await makeBoundFixture()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, platform: platform)

        coordinator.select(fixture.references[0])
        await coordinator.settle()
        XCTAssertNotNil(coordinator.lease)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 0)

        weak var observedLease = coordinator.lease
        var viewLease = coordinator.lease
        coordinator.cancel()

        XCTAssertNil(coordinator.lease)
        XCTAssertNotNil(observedLease)
        XCTAssertEqual(platform.stopCount, 0, "Coordinator cancellation must not close Quick Look's retained lease")

        viewLease?.close()
        viewLease = nil
        XCTAssertNil(observedLease)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testStaleBookmarkRefreshUsesCASAndPreservesDescriptorAndStoreIdentity() async throws {
        let fixture = try await makeBoundFixture()
        let refreshedBookmark = Data([0x02, 0x03])
        let platform = FakeCoordinatorPreviewPlatform(isStale: true, refreshedBookmark: refreshedBookmark)
        let coordinator = makeCoordinator(fixture, platform: platform)
        let original = try XCTUnwrap(fixture.accesses[0])

        coordinator.select(fixture.references[0])
        await coordinator.settle()

        let stored = try await fixture.accessStore.read(representationID: original.id)
        let refreshed = try XCTUnwrap(stored)
        XCTAssertEqual(refreshed.bookmark, refreshedBookmark)
        XCTAssertEqual(refreshed.bytes, original.bytes)
        XCTAssertEqual(refreshed.localPath, original.localPath)
        XCTAssertEqual(refreshed.snapshotID, original.snapshotID)
        let identity = try await fixture.store.identity()
        XCTAssertEqual(identity, fixture.identity)
        XCTAssertNotNil(coordinator.lease)
        XCTAssertEqual(platform.stopCount, 0)
        coordinator.lease?.close()
        coordinator.cancel()
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testStaleRefreshLosesCASAgainstConcurrentBindingAndClosesLease() async throws {
        let fixture = try await makeBoundFixture()
        let gate = PreviewOpenGate()
        let refreshedBookmark = Data([0x02])
        let platform = FakeCoordinatorPreviewPlatform(isStale: true, refreshedBookmark: refreshedBookmark)
        let coordinator = makeCoordinator(fixture, gate: gate, platform: platform)
        let original = try XCTUnwrap(fixture.accesses[0])

        coordinator.select(fixture.references[0])
        try await waitForEntry(gate)
        var concurrent = original
        concurrent.bookmark = Data([0x09])
        concurrent.localPath = "/Synthetic/Concurrent.pdf"
        try await fixture.accessStore.put(concurrent, expecting: fixture.identity)
        await gate.open()
        await coordinator.settle()

        XCTAssertNil(coordinator.lease)
        XCTAssertEqual(platform.stopCount, 1)
        let stored = try await fixture.accessStore.read(representationID: original.id)
        let identity = try await fixture.store.identity()
        XCTAssertEqual(stored, concurrent)
        XCTAssertEqual(identity, fixture.identity)
    }

    func testSelectionChangeCancelsPendingPickerOnceAndIgnoresLateCompletion() async throws {
        let fixture = try await makeBoundFixture(representationCount: 2, boundIndexes: [])
        let picker = FakeFilePreviewPicker()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, picker: picker, platform: platform)

        coordinator.select(fixture.references[0])
        await coordinator.settle()
        let locating = Task { await coordinator.locate() }
        try await waitUntil { picker.chooseCount == 1 }
        XCTAssertEqual(picker.reattachmentRequests, [true])

        coordinator.select(fixture.references[1])
        await coordinator.settle()
        picker.complete(with: URL(fileURLWithPath: "/Synthetic/Preview-0.pdf"))
        await locating.value

        XCTAssertEqual(picker.pendingCancellationCount, 1)
        XCTAssertEqual(coordinator.reference?.representationID, fixture.references[1].representationID)
        let firstAccess = try await fixture.accessStore.read(representationID: fixture.references[0].representationID)
        let secondAccess = try await fixture.accessStore.read(representationID: fixture.references[1].representationID)
        XCTAssertNil(firstAccess)
        XCTAssertNil(secondAccess)
        XCTAssertEqual(platform.startCount, 0, "A late picker result must not start bookmark access")
    }

    func testCancelClosesPendingPickerOnceAndIgnoresLateCompletion() async throws {
        let fixture = try await makeBoundFixture(boundIndexes: [])
        let picker = FakeFilePreviewPicker()
        let platform = FakeCoordinatorPreviewPlatform()
        let coordinator = makeCoordinator(fixture, picker: picker, platform: platform)

        coordinator.select(fixture.references[0])
        await coordinator.settle()
        let locating = Task { await coordinator.locate() }
        try await waitUntil { picker.chooseCount == 1 }

        coordinator.cancel()
        picker.complete(with: URL(fileURLWithPath: "/Synthetic/Preview-0.pdf"))
        await locating.value

        XCTAssertEqual(picker.pendingCancellationCount, 1)
        XCTAssertNil(coordinator.reference)
        let access = try await fixture.accessStore.read(representationID: fixture.references[0].representationID)
        XCTAssertNil(access)
        XCTAssertEqual(platform.startCount, 0, "Closing the preview must fence a late picker completion")
    }

    func testBookmarkResolvingToDifferentFileClosesLeaseWithoutPublishingPreview() async throws {
        let fixture = try await makeBoundFixture()
        let platform = FakeCoordinatorPreviewPlatform(
            resolvedURL: URL(fileURLWithPath: "/Synthetic/Wrong-Target.pdf")
        )
        let coordinator = makeCoordinator(fixture, platform: platform)
        let original = try XCTUnwrap(fixture.accesses[0])

        coordinator.select(fixture.references[0])
        await coordinator.settle()

        XCTAssertNil(coordinator.lease)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
        let stored = try await fixture.accessStore.read(representationID: original.id)
        XCTAssertEqual(stored, original)
        XCTAssertEqual(
            coordinator.message,
            "The file permission points to a different file. Choose the originally referenced file, or copy it again."
        )
    }

    func testMissingLegacyDescriptorNeverInvokesPickerOrBindsCandidate() async throws {
        let fixture = try await makeBoundFixture(version: 1, boundIndexes: [])
        let picker = FakeFilePreviewPicker()
        let coordinator = makeCoordinator(
            fixture,
            picker: picker,
            platform: FakeCoordinatorPreviewPlatform()
        )

        XCTAssertEqual(fixture.references[0].bindingSupport, .missingLegacyDescriptor)
        coordinator.select(fixture.references[0])
        await coordinator.settle()
        await coordinator.locate()

        XCTAssertEqual(picker.chooseCount, 0)
        XCTAssertEqual(picker.pendingCancellationCount, 0)
        let access = try await fixture.accessStore.read(representationID: fixture.references[0].representationID)
        XCTAssertNil(access)
        XCTAssertNil(coordinator.lease)
    }

    private func makeCoordinator(
        _ fixture: BoundFixture,
        gate: PreviewOpenGate? = nil,
        picker: (any FilePreviewPicking)? = nil,
        platform: FakeCoordinatorPreviewPlatform
    ) -> FilePreviewCoordinator {
        FilePreviewCoordinator(
            store: fixture.accessStore,
            identity: fixture.identity,
            picker: picker ?? FakeFilePreviewPicker()
        ) { bookmark in
            let lease = try FilePreviewAccessLease.open(bookmarkData: bookmark, platform: platform)
            await gate?.enter()
            return lease
        }
    }

    private func waitForEntry(_ gate: PreviewOpenGate) async throws {
        try await waitUntil { await gate.entries == 1 }
    }

    private func waitForStop(_ platform: FakeCoordinatorPreviewPlatform) async throws {
        try await waitUntil { platform.stopCount == 1 }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not met before timeout")
    }

    private func makeBoundFixture(
        version: Int = 2,
        representationCount: Int = 1,
        boundIndexes: Set<Int> = [0]
    ) async throws -> BoundFixture {
        let store = try makeStore()
        let model = try makeFixture(version: version, representationCount: representationCount)
        try await insert(model.capture, item: model.item, into: store)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        let references = try await accessStore.filePreviewReferences(for: model.ref, expecting: identity)
        var accesses: [LocalFileAccess?] = Array(repeating: nil, count: references.count)
        for index in boundIndexes {
            let url = URL(fileURLWithPath: "/Synthetic/Preview-\(index).pdf")
            accesses[index] = try await accessStore.bind(
                references[index],
                selectedFileURL: url,
                bookmarkData: Data([UInt8(index + 1)]),
                expecting: nil,
                identity: identity
            )
        }
        return BoundFixture(
            store: store,
            accessStore: accessStore,
            identity: identity,
            references: references,
            accesses: accesses
        )
    }

    private func makeFixture(version: Int, representationCount: Int) throws -> ModelFixture {
        let captureID = UUID()
        let representations = (0..<representationCount).map { index in
            RepresentationValue(
                snapshotID: captureID,
                itemIndex: index,
                representationIndex: 0,
                typeIdentifier: "public.file-url",
                storage: .localReference,
                byteCount: 0,
                digest: Data(repeating: UInt8(index + 1), count: 32),
                bytes: nil
            )
        }
        let manifest = CaptureManifest(
            version: version,
            itemCount: representationCount,
            entries: representations.map(ManifestEntry.init)
        )
        let capture = CaptureValue(
            id: captureID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: representations
        )
        let item = ItemValue(captureID: captureID, historyEligible: true)
        return ModelFixture(
            capture: capture,
            item: item,
            ref: ContentRef(
                itemID: item.id,
                facet: .history,
                version: ContentVersion(rawValue: captureID),
                digest: capture.digest
            )
        )
    }

    private func insert(_ capture: CaptureValue, item: ItemValue, into store: PersistenceController) async throws {
        try await store.perform { context in
            let captureObject = NSEntityDescription.insertNewObject(
                forEntityName: RecordKey.capture(capture.id).entity,
                into: context
            )
            try StoredRecords.write(.capture(capture), to: captureObject, in: context)
            let itemObject = NSEntityDescription.insertNewObject(
                forEntityName: RecordKey.item(item.id).entity,
                into: context
            )
            try StoredRecords.write(.item(item), to: itemObject, in: context)
            try StoredRecords.link(item, in: context)
            try context.save()
            context.reset()
        }
    }

    private func deleteRepresentation(_ id: UUID, from store: PersistenceController) async throws {
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            let row = try XCTUnwrap(context.fetch(request).first)
            context.delete(row)
            try context.save()
            context.reset()
        }
    }

    private func insertMarker(
        _ marker: FacetDeletionMarkerValue,
        into store: PersistenceController
    ) async throws {
        try await store.perform { context in
            let object = NSEntityDescription.insertNewObject(
                forEntityName: RecordKey.facetMarker(marker.id).entity,
                into: context
            )
            try StoredRecords.write(.facetMarker(marker), to: object, in: context)
            try context.save()
            context.reset()
        }
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-FilePreviewCoordinatorTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock {
            try await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        return store
    }
}

private struct ModelFixture {
    let capture: CaptureValue
    let item: ItemValue
    let ref: ContentRef
}

private struct BoundFixture {
    let store: PersistenceController
    let accessStore: FileAccessStore
    let identity: StoreIdentity
    let references: [FilePreviewReference]
    let accesses: [LocalFileAccess?]
}

private actor PreviewOpenGate {
    private(set) var entries = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entries += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class FakeFilePreviewPicker: FilePreviewPicking {
    private(set) var chooseCount = 0
    private(set) var pendingCancellationCount = 0
    private(set) var reattachmentRequests: [Bool] = []
    private var completion: CheckedContinuation<URL?, Never>?

    func choose(isReattachment: Bool) async -> URL? {
        chooseCount += 1
        reattachmentRequests.append(isReattachment)
        return await withCheckedContinuation { completion = $0 }
    }

    func cancel() {
        guard completion != nil else { return }
        pendingCancellationCount += 1
        // Leave it pending so the test can deliver a late completion and exercise the generation fence.
    }

    func complete(with url: URL?) {
        let pending = completion
        completion = nil
        pending?.resume(returning: url)
    }
}

private final class FakeCoordinatorPreviewPlatform: FilePreviewAccessPlatform, @unchecked Sendable {
    private let lock = NSLock()
    private let resolution: ResolvedFilePreviewBookmark
    private let refreshedBookmark: Data
    private var starts = 0
    private var stops = 0

    init(
        resolvedURL: URL = URL(fileURLWithPath: "/Synthetic/Preview-0.pdf"),
        isStale: Bool = false,
        refreshedBookmark: Data = Data([0x02])
    ) {
        resolution = ResolvedFilePreviewBookmark(
            url: resolvedURL,
            isStale: isStale
        )
        self.refreshedBookmark = refreshedBookmark
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func resolveBookmark(_: Data) throws -> ResolvedFilePreviewBookmark { resolution }

    func startAccessing(_: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_: URL) {
        lock.withLock { stops += 1 }
    }

    func makeReadOnlyBookmark(for _: URL) throws -> Data { refreshedBookmark }
}
