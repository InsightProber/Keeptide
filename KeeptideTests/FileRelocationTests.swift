import CoreData
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class FileRelocationTests: XCTestCase {
    func testMissingOpaqueLocalStateListsAndBindsExactReferenceWithoutChangingCloudDescriptor() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        try await insert(fixture.capture, item: fixture.item, into: store)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()

        let references = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        let reference = try XCTUnwrap(references.first)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(reference.bindingSupport, .supportedFileURL)
        XCTAssertNil(reference.localAccess)

        let selected = URL(fileURLWithPath: "/Synthetic/Relocated Report.pdf")
        let bound = try await accessStore.bind(
            reference,
            selectedFileURL: selected,
            bookmarkData: Data([1, 2, 3]),
            expecting: nil,
            identity: identity
        )
        XCTAssertEqual(bound.bytes, Data(selected.absoluteString.utf8))
        XCTAssertEqual(bound.localPath, selected.path)
        XCTAssertEqual(bound.bookmark, Data([1, 2, 3]))
        let stored = try await accessStore.read(representationID: reference.representationID)
        XCTAssertEqual(stored, bound)
        let resolved = try await ContentRepository(controller: store).read(fixture.ref)
        XCTAssertEqual(resolved.representations.first?.bytes, Data(selected.absoluteString.utf8))

        let persisted = try await capture(fixture.capture.id, in: store)
        XCTAssertEqual(persisted.representations.first?.byteCount, 0)
        XCTAssertEqual(persisted.representations.first?.digest, fixture.representation.digest)
        XCTAssertNil(persisted.representations.first?.bytes)
        XCTAssertEqual(persisted.digest, fixture.capture.digest)
    }

    func testRebindRejectsDifferentFileWithoutChangingExistingAuthorization() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        let original = LocalFileAccess(
            id: fixture.representation.id,
            snapshotID: fixture.capture.id,
            bytes: Data("file:///Synthetic/Original.pdf".utf8),
            bookmark: Data([1]),
            localPath: "/Synthetic/Original.pdf"
        )
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        try await accessStore.put(original, expecting: identity)
        try await insert(fixture.capture, item: fixture.item, into: store)
        let references = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        let reference = try XCTUnwrap(references.first)

        do {
            _ = try await accessStore.bind(
                reference,
                selectedFileURL: URL(fileURLWithPath: "/Synthetic/Different.pdf"),
                bookmarkData: Data([2]),
                expecting: original,
                identity: identity
            )
            XCTFail("A bookmark for a different file was attached to the original copy descriptor")
        } catch {
            XCTAssertEqual(error as? FilePreviewReferenceError, .differentFileReference)
        }
        do {
            _ = try await accessStore.refreshBookmark(
                for: reference,
                bookmarkData: Data([3]),
                resolvedFileURL: URL(fileURLWithPath: "/Synthetic/Different.pdf"),
                expecting: original,
                identity: identity
            )
            XCTFail("A refreshed bookmark for a different file replaced the original authorization")
        } catch {
            XCTAssertEqual(error as? FilePreviewReferenceError, .differentFileReference)
        }
        let unchanged = try await accessStore.read(representationID: original.id)
        XCTAssertEqual(unchanged, original)
    }

    func testSameFileReauthorizationAndBookmarkRefreshPreserveDescriptorBytes() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        let originalURL = URL(fileURLWithPath: "/Synthetic/Original.pdf")
        let original = LocalFileAccess(
            id: fixture.representation.id,
            snapshotID: fixture.capture.id,
            bytes: Data(originalURL.absoluteString.utf8),
            bookmark: Data([1]),
            localPath: originalURL.path
        )
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        try await accessStore.put(original, expecting: identity)
        try await insert(fixture.capture, item: fixture.item, into: store)
        let references = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        let reference = try XCTUnwrap(references.first)

        let rebound = try await accessStore.bind(
            reference,
            selectedFileURL: URL(fileURLWithPath: "/Synthetic/Folder/../Original.pdf"),
            bookmarkData: Data([2]),
            expecting: original,
            identity: identity
        )
        XCTAssertEqual(rebound.bytes, original.bytes)
        XCTAssertEqual(rebound.localPath, "/Synthetic/Original.pdf")

        let refreshed = try await accessStore.refreshBookmark(
            for: reference,
            bookmarkData: Data([3]),
            resolvedFileURL: originalURL,
            expecting: rebound,
            identity: identity
        )
        XCTAssertEqual(refreshed.bytes, original.bytes)
        XCTAssertEqual(refreshed.localPath, rebound.localPath)
        XCTAssertEqual(refreshed.bookmark, Data([3]))
    }

    func testStaleBindingCASFailsWithoutOverwritingConcurrentState() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        let original = LocalFileAccess(
            id: fixture.representation.id,
            snapshotID: fixture.capture.id,
            bytes: Data("file:///Synthetic/Original.txt".utf8),
            bookmark: Data([1]),
            localPath: "/Synthetic/Original.txt"
        )
        try await accessStore.put(original, expecting: identity)
        try await insert(fixture.capture, item: fixture.item, into: store)
        let references = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        let reference = try XCTUnwrap(references.first)
        var concurrent = original
        concurrent.bookmark = Data([9])
        concurrent.localPath = "/Synthetic/Concurrent.txt"
        try await accessStore.put(concurrent, expecting: identity)

        do {
            _ = try await accessStore.bind(
                reference,
                selectedFileURL: URL(fileURLWithPath: "/Synthetic/Stale.txt"),
                bookmarkData: Data([2]),
                expecting: original,
                identity: identity
            )
            XCTFail("A stale local binding CAS overwrote newer state")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let stored = try await accessStore.read(representationID: original.id)
        XCTAssertEqual(stored, concurrent)
    }

    func testFinderAuxiliaryListRemainsVisibleButCannotBeBound() async throws {
        let store = try makeStore()
        let fixture = try makeFinderFixture()
        try await insert(fixture.capture, item: fixture.item, into: store)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()

        let references = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        XCTAssertEqual(references.count, 2)
        let fileURL = try XCTUnwrap(references.first { $0.typeIdentifier == "public.file-url" })
        let auxiliary = try XCTUnwrap(references.first { $0.typeIdentifier == "NSFilenamesPboardType" })
        XCTAssertEqual(fileURL.bindingSupport, .supportedFileURL)
        XCTAssertEqual(auxiliary.bindingSupport, .unsupportedCompound)

        do {
            _ = try await accessStore.bind(
                auxiliary,
                selectedFileURL: URL(fileURLWithPath: "/Synthetic/Picked.txt"),
                bookmarkData: Data([1]),
                expecting: nil,
                identity: identity
            )
            XCTFail("An auxiliary Finder list was guessed from one selected file")
        } catch {
            XCTAssertEqual(error as? FilePreviewReferenceError, .unsupportedRepresentationLayout)
        }
        let auxiliaryAccess = try await accessStore.read(representationID: auxiliary.representationID)
        XCTAssertNil(auxiliaryAccess)

        let selected = URL(fileURLWithPath: "/Synthetic/Picked.txt")
        _ = try await accessStore.bind(
            fileURL,
            selectedFileURL: selected,
            bookmarkData: Data([2]),
            expecting: nil,
            identity: identity
        )
        let siblingAccess = try await accessStore.read(representationID: auxiliary.representationID)
        XCTAssertNil(siblingAccess)
        let persisted = try await capture(fixture.capture.id, in: store)
        XCTAssertEqual(persisted.representations, fixture.capture.representations)
    }

    func testInheritedMemoListsCaptureFilesButOwnedMemoDoesNot() async throws {
        let inheritedStore = try makeStore()
        let inherited = try makeFixture(version: 2)
        let inheritedMemo = MemoValue(itemID: inherited.item.id, bodyMode: .inheritedCapture)
        var inheritedItem = inherited.item
        inheritedItem.memoID = inheritedMemo.id
        try await insert(inherited.capture, item: inheritedItem, memo: inheritedMemo, into: inheritedStore)
        let inheritedRef = ContentRef(
            itemID: inheritedItem.id,
            facet: .memo,
            version: ContentVersion(rawValue: inherited.capture.id),
            digest: inherited.capture.digest
        )
        let inheritedIdentity = try await inheritedStore.identity()
        let inheritedReferences = try await FileAccessStore(controller: inheritedStore)
            .filePreviewReferences(for: inheritedRef, expecting: inheritedIdentity)
        XCTAssertEqual(inheritedReferences.count, 1)

        let ownedStore = try makeStore()
        let owned = try makeFixture(version: 2)
        let body = Data("owned memo".utf8)
        let ownedMemo = MemoValue(
            itemID: owned.item.id,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        var ownedItem = owned.item
        ownedItem.memoID = ownedMemo.id
        try await insert(owned.capture, item: ownedItem, memo: ownedMemo, into: ownedStore)
        let ownedRef = ContentRef(
            itemID: ownedItem.id,
            facet: .memo,
            version: try XCTUnwrap(ownedMemo.version),
            digest: try XCTUnwrap(ownedMemo.digest)
        )
        let ownedIdentity = try await ownedStore.identity()
        let ownedReferences = try await FileAccessStore(controller: ownedStore)
            .filePreviewReferences(for: ownedRef, expecting: ownedIdentity)
        XCTAssertTrue(ownedReferences.isEmpty)
    }

    func testMarkerHiddenStaleRefAndWrongIdentityAreRejected() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        try await insert(fixture.capture, item: fixture.item, into: store)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()

        var stale = fixture.ref
        stale.digest = Data(repeating: 8, count: stale.digest.count)
        await assertStoreError(.staleReference) {
            _ = try await accessStore.filePreviewReferences(for: stale, expecting: identity)
        }
        await assertStoreError(.preconditionFailed) {
            _ = try await accessStore.filePreviewReferences(
                for: fixture.ref,
                expecting: StoreIdentity(storeID: UUID(), generation: UUID())
            )
        }

        try await insertMarker(
            FacetDeletionMarkerValue(
                itemID: fixture.item.id,
                facet: .history,
                generationID: fixture.capture.id
            ),
            into: store
        )
        await assertStoreError(.notFound) {
            _ = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        }
    }

    func testMissingLegacyDescriptorCannotBeReconstructedFromUserSelection() async throws {
        let store = try makeStore()
        let selected = URL(fileURLWithPath: "/Synthetic/Legacy.txt")
        let bytes = Data(selected.absoluteString.utf8)
        let fixture = try makeFixture(
            version: 1,
            cloudByteCount: Int64(bytes.count),
            cloudDigest: ContentDigest.sha256(bytes)
        )
        try await insert(fixture.capture, item: fixture.item, into: store)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        let references = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
        let reference = try XCTUnwrap(references.first)
        XCTAssertEqual(reference.bindingSupport, .missingLegacyDescriptor)

        do {
            _ = try await accessStore.bind(
                reference,
                selectedFileURL: selected,
                bookmarkData: Data([1]),
                expecting: nil,
                identity: identity
            )
            XCTFail("A missing legacy descriptor was reconstructed from a candidate path")
        } catch {
            XCTAssertEqual(error as? FilePreviewReferenceError, .unsupportedLegacyRelocation)
        }
        let stored = try await accessStore.read(representationID: reference.representationID)
        XCTAssertNil(stored)
    }

    func testFileReferenceIdentityMatchesOnlyTheOriginalStandardizedFileURL() {
        let descriptor = Data("file:///Synthetic/Original.txt".utf8)

        XCTAssertTrue(FileReferenceIdentity.matches(
            descriptorBytes: descriptor,
            candidateURL: URL(fileURLWithPath: "/Synthetic/Folder/../Original.txt")
        ))
        XCTAssertFalse(FileReferenceIdentity.matches(
            descriptorBytes: descriptor,
            candidateURL: URL(fileURLWithPath: "/Synthetic/Different.txt")
        ))
        XCTAssertFalse(FileReferenceIdentity.matches(
            descriptorBytes: Data("https://example.com/not-local".utf8),
            candidateURL: URL(fileURLWithPath: "/Synthetic/Original.txt")
        ))
    }

    func testRecoveringCaptureCannotProduceFileReferences() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        try await insert(fixture.capture, item: fixture.item, into: store)
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "id == %@", fixture.representation.id as NSUUID)
            let row = try XCTUnwrap(context.fetch(request).first)
            context.delete(row)
            try context.save()
            context.reset()
        }

        let identity = try await store.identity()
        do {
            _ = try await FileAccessStore(controller: store).filePreviewReferences(
                for: fixture.ref,
                expecting: identity
            )
            XCTFail("A recovering capture produced actionable file references")
        } catch {
            XCTAssertEqual(error as? FilePreviewReferenceError, .contentUnavailable(.recovering))
        }
    }

    func testCorruptLocalStateCannotProduceFileReferences() async throws {
        let store = try makeStore()
        let fixture = try makeFixture(version: 2)
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        let access = LocalFileAccess(
            id: fixture.representation.id,
            snapshotID: fixture.capture.id,
            bytes: Data("file:///Synthetic/Corrupt.txt".utf8),
            bookmark: Data([1]),
            localPath: "/Synthetic/Corrupt.txt"
        )
        try await accessStore.put(access, expecting: identity)
        try await insert(fixture.capture, item: fixture.item, into: store)
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "id == %@", access.id as NSUUID)
            let row = try XCTUnwrap(context.fetch(request).first)
            row.setValue(Data([0xff]), forKey: "bytes")
            try context.save()
            context.reset()
        }

        do {
            _ = try await accessStore.filePreviewReferences(for: fixture.ref, expecting: identity)
            XCTFail("Corrupt local state produced actionable file references")
        } catch {
            XCTAssertEqual(error as? FilePreviewReferenceError, .contentUnavailable(.corrupt))
        }
    }

    private typealias Fixture = (
        capture: CaptureValue,
        item: ItemValue,
        representation: RepresentationValue,
        ref: ContentRef
    )

    private func makeFixture(
        version: Int,
        cloudByteCount: Int64 = 0,
        cloudDigest: Data = Data(repeating: 7, count: 32)
    ) throws -> Fixture {
        let captureID = UUID()
        let representation = RepresentationValue(
            snapshotID: captureID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: cloudByteCount,
            digest: cloudDigest,
            bytes: nil
        )
        return try fixture(version: version, representations: [representation])
    }

    private func makeFinderFixture() throws -> Fixture {
        let captureID = UUID()
        let fileURL = RepresentationValue(
            snapshotID: captureID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: 0,
            digest: Data(repeating: 1, count: 32),
            bytes: nil
        )
        let names = RepresentationValue(
            snapshotID: captureID,
            itemIndex: 0,
            representationIndex: 1,
            typeIdentifier: "NSFilenamesPboardType",
            storage: .localReference,
            byteCount: 0,
            digest: Data(repeating: 2, count: 32),
            bytes: nil
        )
        return try fixture(version: 2, representations: [fileURL, names])
    }

    private func fixture(version: Int, representations: [RepresentationValue]) throws -> Fixture {
        let captureID = try XCTUnwrap(representations.first?.snapshotID)
        let manifest = CaptureManifest(
            version: version,
            itemCount: 1,
            entries: representations.map(ManifestEntry.init)
        )
        let capture = CaptureValue(
            id: captureID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: representations
        )
        let item = ItemValue(captureID: captureID, historyEligible: true)
        return (
            capture,
            item,
            representations[0],
            ContentRef(
                itemID: item.id,
                facet: .history,
                version: ContentVersion(rawValue: captureID),
                digest: capture.digest
            )
        )
    }

    private func insert(
        _ capture: CaptureValue,
        item: ItemValue,
        memo: MemoValue? = nil,
        into store: PersistenceController
    ) async throws {
        try await store.perform { context in
            let captureObject = NSEntityDescription.insertNewObject(
                forEntityName: RecordKey.capture(capture.id).entity,
                into: context
            )
            try StoredRecords.write(.capture(capture), to: captureObject, in: context)
            if let memo {
                let memoObject = NSEntityDescription.insertNewObject(
                    forEntityName: RecordKey.memo(memo.id).entity,
                    into: context
                )
                try StoredRecords.write(.memo(memo), to: memoObject, in: context)
            }
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

    private func capture(_ id: UUID, in store: PersistenceController) async throws -> CaptureValue {
        try await store.perform { context in
            try StoredRecords.validatedCapture(id, in: context)
        }
    }

    private func assertStoreError(
        _ expected: StoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? StoreError, expected)
        }
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-FileRelocationTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock {
            try await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        return store
    }
}
