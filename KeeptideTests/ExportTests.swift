import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class ExportTests: XCTestCase {
    func testEmptyAllVisibleRunsRealSnapshotDiskAndIndependentVerifier() async throws {
        let fixture = try makeStoreAndDestination()

        let result = try await ExportService(controller: fixture.controller).export(
            ExportRequest(scope: .allVisible, destinationParent: fixture.destinationParent)
        )
        let verification = try await ArchiveVerifier().verify(at: result.destination)
        let archive = try readArchive(at: result.destination)

        XCTAssertEqual(verification.entryCount, 0)
        XCTAssertEqual(archive.manifest.expectedEntryCount, 0)
        XCTAssertTrue(archive.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent("README.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent("payloads").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent("readable").path))
        let activeLeases = try await activeLeaseCount(fixture.controller)
        XCTAssertEqual(activeLeases, 0)
    }

    func testAllVisiblePreservesPortableBytesPrivacyAndUniqueRepresentationsAcrossPages() async throws {
        let fixture = try makeStoreAndDestination()
        let library = try await insertMixedLibrary(into: fixture.controller)

        let result = try await ExportService(controller: fixture.controller).export(
            ExportRequest(scope: .allVisible, destinationParent: fixture.destinationParent, pageSize: 1)
        )
        let verification = try await ArchiveVerifier().verify(at: result.destination)
        let archive = try readArchive(at: result.destination)

        XCTAssertEqual(verification.entryCount, 4)
        XCTAssertEqual(archive.entries.map(\.ordinal), [1, 2, 3, 4])
        XCTAssertEqual(Set(archive.entries.map { "\($0.itemID)|\($0.facet.rawValue)" }).count, 4)
        XCTAssertEqual(archive.manifest.expectedRepresentationCount, 5)
        XCTAssertEqual(verification.representationCount, 5)
        XCTAssertEqual(verification.portablePayloadCount, 4)

        let sharedEntries = archive.entries.filter { $0.itemID == library.sharedItem.id.rawValue }
        XCTAssertEqual(sharedEntries.count, 2)
        XCTAssertEqual(sharedEntries[0].representations.first?.payloadPath,
                       sharedEntries[1].representations.first?.payloadPath)

        let markdown = try XCTUnwrap(archive.entries.first {
            $0.itemID == library.markdownItem.id.rawValue && $0.facet == .memo
        })
        XCTAssertEqual(markdown.contentKind, .markdown)
        let markdownReadable = try XCTUnwrap(markdown.representations.first?.readable)
        XCTAssertEqual(try Data(contentsOf: result.destination.appendingPathComponent(markdownReadable.path)),
                       library.markdownBody)

        let mixed = try XCTUnwrap(archive.entries.first { $0.itemID == library.mixedItem.id.rawValue })
        XCTAssertEqual(mixed.availability, .requiresFileRelocation)
        XCTAssertEqual(mixed.representations.filter { $0.storage == .portable }.count, 2)
        XCTAssertEqual(mixed.representations.filter { $0.storage == .localReference }.count, 1)
        for representation in mixed.representations where representation.storage == .portable {
            let path = try XCTUnwrap(representation.payloadPath)
            XCTAssertEqual(try Data(contentsOf: result.destination.appendingPathComponent(path)),
                           library.portableBytes[representation.id])
        }
        let local = try XCTUnwrap(mixed.representations.first { $0.storage == .localReference })
        XCTAssertNil(local.payloadPath)
        XCTAssertNil(local.readable)
        XCTAssertEqual(local.byteCount, 0)
        XCTAssertNotNil(local.relocationTokenHex)
        XCTAssertFalse(try archiveContains(result.destination, bytes: library.privateFileAccessBytes))
        let activeLeases = try await activeLeaseCount(fixture.controller)
        XCTAssertEqual(activeLeases, 0)
    }

    func testSelectedUsesExactOrderAndStaleSelectionPublishesNothing() async throws {
        let fixture = try makeStoreAndDestination()
        let library = try await insertMixedLibrary(into: fixture.controller)
        let selected = [library.mixedRef, library.markdownRef, library.mixedRef]

        let result = try await ExportService(controller: fixture.controller).export(
            ExportRequest(scope: .selected(selected), destinationParent: fixture.destinationParent)
        )
        let archive = try readArchive(at: result.destination)
        XCTAssertEqual(archive.entries.map(\.itemID), [
            library.mixedRef.itemID.rawValue, library.markdownRef.itemID.rawValue,
        ])
        XCTAssertEqual(archive.entries.map(\.facet), [.clipboardHistory, .memo])
        XCTAssertEqual(archive.manifest.scope.kind, .selected)
        XCTAssertEqual(archive.manifest.scope.requestedRefCount, 2)

        let staleParent = fixture.root.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleParent, withIntermediateDirectories: false)
        var stale = library.markdownRef
        stale.version = ContentVersion()
        await XCTAssertThrowsErrorAsyncExport {
            _ = try await ExportService(controller: fixture.controller).export(
                ExportRequest(scope: .selected([stale]), destinationParent: staleParent)
            )
        } verify: { XCTAssertEqual($0 as? ExportError, .changedSelection) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staleParent.path), [])
        let activeLeases = try await activeLeaseCount(fixture.controller)
        XCTAssertEqual(activeLeases, 0)
    }

    func testCancellationAndIdentityChangeLeaveNoPublishedOrStagedArchiveAndReleaseLease() async throws {
        try await assertInterruptedExport(identityChange: false)
        try await assertInterruptedExport(identityChange: true)
    }

    func testVerifierWindowGenerationChangeAndLeaseExpiryCannotPublish() async throws {
        try await assertVerifierFence(expireLease: false)
        try await assertVerifierFence(expireLease: true)
    }
    func testSafeNamesIgnoreUserTitlesAndUseOnlyStableIdentifiers() {
        let ref = ContentRef(itemID: ItemID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
                             facet: .memo, version: ContentVersion(), digest: Data(repeating: 1, count: 32))
        let path = SafeExportName.readablePath(ordinal: 7, ref: ref, kind: .markdown)

        XCTAssertEqual(path, "readable/000007-11111111-1111-1111-1111-111111111111-memo.md")
        XCTAssertEqual(SafeExportName.payloadPath(for: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                                                  typeIdentifier: "invalid/../\u{0}"),
                       "payloads/22222222-2222-2222-2222-222222222222.bin")
    }

    func testOwnedMarkdownPreservesBodyBytesIncludingShellPathAndTrailingNewline() throws {
        let itemID = ItemID()
        let body = Data("# Prompt\ncp /Users/alice/input /tmp/output\n".utf8)
        let memo = MemoValue(itemID: itemID, bodyMode: .ownedMarkdown, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body))
        let item = ItemValue(id: itemID, memoID: memo.id)
        let ref = ContentRef(itemID: itemID, facet: .memo, version: try XCTUnwrap(memo.version),
                             digest: try XCTUnwrap(memo.digest))
        let content = ResolvedContent(ref: ref, integrity: .complete,
            representations: [RepresentationValue(id: memo.id, snapshotID: memo.id, itemIndex: 0,
                representationIndex: 0, typeIdentifier: "public.utf8-plain-text", storage: .portable,
                byteCount: Int64(body.count), digest: ContentDigest.sha256(body), bytes: body)])

        let result = ReadableExportEncoder().encode(content: content, records: [.item(item), .memo(memo)])

        XCTAssertEqual(result?.kind, .markdown)
        XCTAssertEqual(result?.data, body)
    }

    func testCapturePrefersExplicitMarkdownWithoutChangingSourceBytes() throws {
        let itemID = ItemID(), captureID = UUID()
        let plain = Data("plain".utf8), markdown = Data("**markdown**\n".utf8)
        let representations = [
            RepresentationValue(snapshotID: captureID, itemIndex: 0, representationIndex: 0,
                typeIdentifier: "public.utf8-plain-text", storage: .portable,
                byteCount: Int64(plain.count), digest: ContentDigest.sha256(plain), bytes: plain),
            RepresentationValue(snapshotID: captureID, itemIndex: 0, representationIndex: 1,
                typeIdentifier: "net.daringfireball.markdown", storage: .portable,
                byteCount: Int64(markdown.count), digest: ContentDigest.sha256(markdown), bytes: markdown),
        ]
        let manifest = CaptureManifest(itemCount: 1, entries: representations.map(ManifestEntry.init))
        let capture = CaptureValue(id: captureID, manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()), representations: representations)
        let item = ItemValue(id: itemID, captureID: captureID, historyEligible: true)
        let ref = ContentRef(itemID: itemID, facet: .history, version: ContentVersion(rawValue: captureID),
                             digest: capture.digest)
        let content = ResolvedContent(ref: ref, integrity: .complete, representations: representations)

        let result = ReadableExportEncoder().encode(content: content, records: [.item(item), .capture(capture)])

        XCTAssertEqual(result?.kind, .markdown)
        XCTAssertEqual(result?.data, markdown)
    }

    func testExclusivePublishNeverOverwritesExistingDestination() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destinationName = "Keeptide Export fixed"
        let destination = parent.appendingPathComponent(destinationName, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let marker = destination.appendingPathComponent("marker")
        try Data("preserve".utf8).write(to: marker)
        let writer = try StagedArchiveWriter(destinationParent: parent, destinationName: destinationName,
                                             stagingID: UUID())
        defer { writer.cleanup() }

        XCTAssertThrowsError(try writer.publish()) { error in
            XCTAssertEqual(error as? StagedArchiveWriterError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
    }

    func testDestinationParentSymlinkIsRejectedWithoutCreatingStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try StagedArchiveWriter(destinationParent: link,
            destinationName: "Keeptide Export blocked", stagingID: UUID())) { error in
            XCTAssertEqual(error as? StagedArchiveWriterError, .unsafeDestination)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: actual.path), [])
    }

    func testPayloadDirectorySymlinkCannotRedirectWritesOutsideStage() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = try StagedArchiveWriter(destinationParent: parent, destinationName: "Keeptide Export safe",
                                             stagingID: UUID())
        defer { writer.cleanup() }
        try FileManager.default.createSymbolicLink(
            at: writer.stagingURL.appendingPathComponent("payloads", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try writer.write(Data("private".utf8), relativePath: "payloads/value.bin"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testStagePathReplacementCannotPublishOrDeleteReplacementDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let writer = try StagedArchiveWriter(destinationParent: parent, destinationName: "Keeptide Export safe",
                                             stagingID: UUID())
        _ = try writer.write(Data("sensitive".utf8), relativePath: "payloads/private.bin")
        let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: writer.stagingURL, to: displaced)
        try FileManager.default.createDirectory(at: writer.stagingURL, withIntermediateDirectories: false)
        let marker = writer.stagingURL.appendingPathComponent("belongs-to-someone-else")
        try Data("preserve".utf8).write(to: marker)

        XCTAssertThrowsError(try writer.publish()) { error in
            XCTAssertEqual(error as? StagedArchiveWriterError, .unsafeDestination)
        }
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("payloads/private.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Keeptide Export safe").path))
    }

    func testParentRenameStillScrubsOwnedSensitiveFilesWithoutTouchingReplacementParent() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = container.appendingPathComponent("parent", isDirectory: true)
        let movedParent = container.appendingPathComponent("moved-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let writer = try StagedArchiveWriter(destinationParent: parent, destinationName: "Keeptide Export safe",
                                             stagingID: UUID())
        _ = try writer.write(Data("sensitive".utf8), relativePath: "payloads/private.bin")
        let stageName = writer.stagingURL.lastPathComponent
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let marker = parent.appendingPathComponent("replacement-marker")
        try Data("preserve".utf8).write(to: marker)

        writer.cleanup()

        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
        let movedStage = movedParent.appendingPathComponent(stageName, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedStage.appendingPathComponent("payloads/private.bin").path))
    }
}

private extension ExportTests {
    struct DiskFixture {
        let root: URL
        let destinationParent: URL
        let controller: PersistenceController

    }

    struct MixedLibrary {
        let sharedItem: ItemValue
        let markdownItem: ItemValue
        let mixedItem: ItemValue
        let markdownBody: Data
        let markdownRef: ContentRef
        let mixedRef: ContentRef
        let portableBytes: [UUID: Data]
        let privateFileAccessBytes: Data
    }

    struct DecodedArchive {
        let manifest: ArchiveManifest
        let entries: [ArchiveEntry]
    }

    func makeStoreAndDestination() throws -> DiskFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportTests-\(UUID().uuidString)", isDirectory: true)
        let store = root.appendingPathComponent("store", isDirectory: true)
        let destination = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let controller = try PersistenceController(directory: store)
        addTeardownBlock {
            try await controller.close()
            try FileManager.default.removeItem(at: root)
        }
        return DiskFixture(root: root, destinationParent: destination, controller: controller)
    }

    func insertMixedLibrary(into controller: PersistenceController) async throws -> MixedLibrary {
        let sharedCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("shared history and memo".utf8))],
        ])
        var sharedItem = ContentStoreFixtures.item(sharedCapture)
        let inheritedMemo = MemoValue(itemID: sharedItem.id, bodyMode: .inheritedCapture)
        sharedItem.memoID = inheritedMemo.id

        let markdownBody = Data("# Saved prompt\ncp /Users/alice/input /tmp/output\n".utf8)
        let markdownMemo = MemoValue(itemID: ItemID(), bodyMode: .ownedMarkdown, body: markdownBody,
                                     version: ContentVersion(), digest: ContentDigest.sha256(markdownBody))
        let markdownItem = ItemValue(id: markdownMemo.itemID, title: "Markdown",
                                     memoID: markdownMemo.id, historyEligible: false)

        let mixedCaptureID = UUID()
        let textBytes = Data("portable text".utf8)
        let imageBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
        let text = RepresentationValue(snapshotID: mixedCaptureID, itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text", storage: .portable,
            byteCount: Int64(textBytes.count), digest: ContentDigest.sha256(textBytes), bytes: textBytes)
        let image = RepresentationValue(snapshotID: mixedCaptureID, itemIndex: 0, representationIndex: 1,
            typeIdentifier: "public.png", storage: .portable,
            byteCount: Int64(imageBytes.count), digest: ContentDigest.sha256(imageBytes), bytes: imageBytes)
        let local = RepresentationValue(snapshotID: mixedCaptureID, itemIndex: 0, representationIndex: 2,
            typeIdentifier: "public.file-url", storage: .localReference, byteCount: 0,
            digest: LocalReferencePrivacy.makeRelocationToken(), bytes: nil)
        let mixedManifest = CaptureManifest(version: LocalReferencePrivacy.opaqueLocalReferenceManifestVersion,
            itemCount: 1, entries: [text, image, local].map(ManifestEntry.init))
        let mixedCapture = CaptureValue(id: mixedCaptureID, manifest: mixedManifest,
            digest: ContentDigest.sha256(try mixedManifest.canonicalData()), representations: [text, image, local])
        let mixedItem = ContentStoreFixtures.item(mixedCapture)

        let identity = try await controller.identity()
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(identity: identity,
            mutations: [
                .insert(.capture(sharedCapture)), .insert(.memo(inheritedMemo)), .insert(.item(sharedItem)),
                .insert(.memo(markdownMemo)), .insert(.item(markdownItem)),
                .insert(.capture(mixedCapture)), .insert(.item(mixedItem)),
            ]))
        let privateBytes = Data("bookmark:file:///Users/alice/Secret/private.txt".utf8)
        try await FileAccessStore(controller: controller).put(
            LocalFileAccess(id: local.id, snapshotID: mixedCaptureID, bytes: privateBytes), expecting: identity)

        return MixedLibrary(sharedItem: sharedItem, markdownItem: markdownItem, mixedItem: mixedItem,
            markdownBody: markdownBody,
            markdownRef: ContentRef(itemID: markdownItem.id, facet: .memo,
                                    version: try XCTUnwrap(markdownMemo.version),
                                    digest: try XCTUnwrap(markdownMemo.digest)),
            mixedRef: ContentStoreFixtures.ref(mixedItem, mixedCapture),
            portableBytes: [text.id: textBytes, image.id: imageBytes],
            privateFileAccessBytes: privateBytes)
    }

    func readArchive(at root: URL) throws -> DecodedArchive {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ArchiveManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let data = try Data(contentsOf: root.appendingPathComponent("entries.ndjson"))
        let entries = try data.split(separator: 0x0a).map { try decoder.decode(ArchiveEntry.self, from: Data($0)) }
        return DecodedArchive(manifest: manifest, entries: entries)
    }

    func archiveContains(_ root: URL, bytes needle: Data) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
               try Data(contentsOf: url).range(of: needle) != nil { return true }
        }
        return false
    }

    func activeLeaseCount(_ controller: PersistenceController) async throws -> Int {
        try await controller.perform { _ in controller.runtime.leases.count }
    }

    func assertInterruptedExport(identityChange: Bool) async throws {
        let fixture = try makeStoreAndDestination()
        _ = try await insertMixedLibrary(into: fixture.controller)
        let identity = try await fixture.controller.identity()
        let barrier = ExportProgressBarrier()
        let task = Task {
            try await ExportService(controller: fixture.controller, expecting: identity).export(
                ExportRequest(scope: .allVisible, destinationParent: fixture.destinationParent, pageSize: 1)
            ) { progress in
                if progress == .writing(completedEntries: 1) { barrier.arriveAndWait() }
            }
        }
        await Task.detached { barrier.waitUntilReached() }.value
        if identityChange {
            try await StoreSafetyGate(controller: fixture.controller).transition(to: .quarantined, expecting: identity)
        } else {
            task.cancel()
        }
        barrier.release()
        do {
            _ = try await task.value
            XCTFail("Interrupted export unexpectedly published")
        } catch {
            XCTAssertEqual(error as? ExportError, identityChange ? .snapshotExpired : .cancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationParent.path), [])
        let activeLeases = try await activeLeaseCount(fixture.controller)
        XCTAssertEqual(activeLeases, 0)
    }

    func assertVerifierFence(expireLease: Bool) async throws {
        let fixture = try makeStoreAndDestination()
        _ = try await insertMixedLibrary(into: fixture.controller)
        let identity = try await fixture.controller.identity()
        let controller = fixture.controller
        let service = ExportService(
            reader: ContentSnapshotReader(controller: controller),
            permitProvider: { try await StoreSafetyGate(controller: controller).permit(.completeArchive) },
            verify: { root in
                let verification = try await ArchiveVerifier().verify(at: root)
                if expireLease {
                    try await Task.sleep(for: .milliseconds(150))
                } else {
                    try await StoreSafetyGate(controller: controller).transition(to: .quarantined,
                                                                                 expecting: identity)
                }
                return verification
            },
            expecting: identity
        )
        do {
            _ = try await service.export(ExportRequest(scope: .allVisible,
                destinationParent: fixture.destinationParent, pageSize: 1,
                leaseLifetime: expireLease ? 0.05 : 3600))
            XCTFail("A stale verifier window unexpectedly published")
        } catch {
            XCTAssertEqual(error as? ExportError, .snapshotExpired)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destinationParent.path), [])
        let activeLeases = try await activeLeaseCount(fixture.controller)
        XCTAssertEqual(activeLeases, 0)
    }
}

private final class ExportProgressBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var reached = false
    private var released = false

    func arriveAndWait() {
        condition.lock()
        reached = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilReached() {
        condition.lock()
        while !reached { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@MainActor
private func XCTAssertThrowsErrorAsyncExport(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) }
    catch { verify(error) }
}
