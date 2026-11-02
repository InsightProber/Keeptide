import CryptoKit
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class StoreOpenFailureTests: XCTestCase {
    private let snapshotID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let itemID = ItemID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    private let captureDigest = Data(hexadecimal: "ad7b063831fbdb8a1f8e9e5898ecd744150e75db431422449299322b262cb928")!

    func testSecondStoreOpenFailureDoesNotBecomeAnEmptyLibraryAndRestoredV1StoresReopenExactly() async throws {
        let source = try XCTUnwrap(
            Bundle(for: StoreOpenFailureTests.self).url(forResource: "SchemaV1", withExtension: nil)
        )
        let sourceHashes = try regularFileHashes(in: source)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-StoreOpenFailureTests-\(UUID().uuidString)", isDirectory: true)
        let controlDirectory = root.appendingPathComponent("control", isDirectory: true)
        let failureDirectory = root.appendingPathComponent("failure", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: source, to: controlDirectory)
        try FileManager.default.copyItem(at: source, to: failureDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let control = try PersistenceController(directory: controlDirectory)
        addTeardownBlock { try? await control.close() }
        let expected = try await snapshot(from: control)
        try await control.close()

        let localStore = failureDirectory.appendingPathComponent("Local.sqlite", isDirectory: false)
        let savedLocalStore = failureDirectory.appendingPathComponent("Local.saved.sqlite", isDirectory: false)
        let savedLocalHash = try fileHash(localStore)
        try FileManager.default.moveItem(at: localStore, to: savedLocalStore)
        try FileManager.default.createDirectory(at: localStore, withIntermediateDirectories: false)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.removeItem(at: localStore)
                try? FileManager.default.moveItem(at: savedLocalStore, to: localStore)
            }
        }

        for attempt in 1...2 {
            XCTAssertThrowsError(try PersistenceController(directory: failureDirectory),
                "Attempt \(attempt): a LocalState open failure must not return a controller backed by a new empty store") { error in
                XCTAssertNotEqual(error as? StoreError, .storeInUse,
                                  "A failed open must release its directory lock before a retry")
            }
        }
        XCTAssertTrue(try localStore.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertEqual(try fileHash(savedLocalStore), savedLocalHash,
                       "The unavailable LocalState store must remain byte-for-byte recoverable")

        try FileManager.default.removeItem(at: localStore)
        try FileManager.default.moveItem(at: savedLocalStore, to: localStore)
        restored = true

        let reopened = try PersistenceController(directory: failureDirectory)
        addTeardownBlock { try? await reopened.close() }
        let actual = try await snapshot(from: reopened)
        try await reopened.close()

        XCTAssertEqual(actual, expected,
                       "Restoring the original second store must recover identity, content, relationships and local usage")
        XCTAssertEqual(actual.representations.map(\.bytes), [
            Data("Schema V1 fixture — 中文\n".utf8),
            Data("<p>Schema V1 fixture</p>".utf8),
            Data([0x00, 0x01, 0x7f, 0xff]),
        ].map(Optional.some))
        XCTAssertEqual(try regularFileHashes(in: source), sourceHashes,
                       "The frozen fixture itself must never be migrated or modified")
    }
}

private extension StoreOpenFailureTests {
    struct StoreSnapshot: Equatable {
        let identity: StoreIdentity
        let item: ItemValue
        let representations: [RepresentationValue]
        let usage: [UsageSummary]
    }

    func snapshot(from controller: PersistenceController) async throws -> StoreSnapshot {
        let ref = ContentRef(itemID: itemID, facet: .history,
                             version: ContentVersion(rawValue: snapshotID), digest: captureDigest)
        let resolved = try await ContentRepository(controller: controller).read(ref)
        guard case .item(let item) = try await ContentRepository(controller: controller)
            .recordState(.item(itemID)).value else {
            throw StoreError.corruptStore
        }
        return StoreSnapshot(identity: try await controller.identity(), item: item,
                             representations: resolved.representations,
                             usage: try await LocalUsageStore(controller: controller).summaries(for: [ref]))
    }

    func regularFileHashes(in directory: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { throw CocoaError(.fileReadUnknown) }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.path.dropFirst(directory.path.count + 1))] = try fileHash(url)
        }
        return result
    }

    func fileHash(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }
}

private extension Data {
    init?(hexadecimal value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
