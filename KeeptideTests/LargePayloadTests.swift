import CoreData
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

@MainActor
final class LargePayloadTests: XCTestCase {
    func testImageLargerThanTwentyMiBRoundTripsAndSummaryDoesNotLoadIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let bytes = try syntheticPNG()
        XCTAssertGreaterThan(bytes.count, 20 * 1024 * 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3072)
        XCTAssertEqual(image.height, 2560)
        let capture = try ContentStoreFixtures.capture([[(UTType.png.identifier, bytes)]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        try await store.close()
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try await reopened.close() }
        let summary = try await ContentRepository(controller: reopened).recent(limit: 1)
        XCTAssertEqual(summary.map(\.itemID), [item.id])
        let hasPayload = try await reopened.perform { context in
            context.registeredObjects.contains { $0.entity.name == "CaptureRepresentation" }
        }
        XCTAssertFalse(hasPayload)
        let result = try await ContentRepository(controller: reopened).read(ContentStoreFixtures.ref(item, capture))
        XCTAssertTrue(result.isActionable)
        XCTAssertEqual(result.representations.first?.bytes, bytes)
        try await reopened.close()
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])!
        var sqliteBytes = 0
        var externalBytes = 0
        while let url = urls.nextObject() as? URL {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if url.pathExtension == "sqlite" { sqliteBytes += size }
            else if url.path.contains("_EXTERNAL_DATA") { externalBytes += size }
        }
        print("Synthetic large payload: \(bytes.count) bytes; SQLite: \(sqliteBytes); external payload: \(externalBytes)")
        XCTAssertGreaterThan(sqliteBytes + externalBytes, bytes.count)
    }

    func testExternalOwnedBodyEditEitherPreservesSnapshotOrTerminatesTheLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let id = ItemID()
        let body = Data(repeating: 65, count: 21 * 1024 * 1024)
        var memo = MemoValue(itemID: id, bodyMode: .ownedPlainText, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body))
        let item = ItemValue(id: id, memoID: memo.id)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(identity: try await store.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]))
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: try await StoreSafetyGate(controller: store).permit(.completeArchive)))
        let state = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        memo.body = Data("replacement".utf8)
        memo.version = ContentVersion()
        memo.digest = ContentDigest.sha256(memo.body!)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(identity: try await store.identity(),
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: state.fingerprint)], mutations: [.update(.memo(memo))]))
        // Core Data may reclaim an external binary file even while its SQLite
        // generation remains pinned. Both supported outcomes must be safe:
        // exact original bytes, or a terminal lease failure with no partial page.
        do {
            let page = try await reader.page(lease, after: nil)
            XCTAssertEqual(page.contents.first?.representations.first?.bytes, body)
            XCTAssertTrue(page.contents.first?.isActionable == true)
            await reader.end(lease)
        } catch {
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
            do {
                _ = try await reader.page(lease, after: nil)
                XCTFail("A failed snapshot lease remained usable")
            } catch { XCTAssertEqual(error as? StoreError, .invalidLease) }
        }
        let currentRef = ContentRef(itemID: id, facet: .memo, version: memo.version!, digest: memo.digest!)
        let current = try await ContentRepository(controller: store).read(currentRef)
        XCTAssertTrue(current.isActionable)
        XCTAssertEqual(current.representations.first?.bytes, Data("replacement".utf8))
    }

    private func syntheticPNG() throws -> Data {
        let width = 3072, height = 2560
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var state: UInt32 = 0x12543678
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                bytes[offset] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
