import CryptoKit
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class SchemaFixtureTests: XCTestCase {
    private let snapshotID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let itemID = ItemID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    private let captureDigest = Data(hex: "ad7b063831fbdb8a1f8e9e5898ecd744150e75db431422449299322b262cb928")!

    func testSchemaV1FixtureReopensWithKnownContentWithoutMutatingFixtureFiles() async throws {
        let fixture = try XCTUnwrap(
            Bundle(for: SchemaFixtureTests.self).url(forResource: "SchemaV1", withExtension: nil)
        )
        let sourceHashesBefore = try hashes(in: fixture)
        XCTAssertEqual(Set(sourceHashesBefore.keys), ["Content.sqlite", "Local.sqlite", "README.md"])

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-SchemaFixtureTests-\(UUID().uuidString)", isDirectory: true)
        let copiedFixture = temporaryRoot.appendingPathComponent("SchemaV1", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.copyItem(at: fixture, to: copiedFixture)

        let ref = ContentRef(
            itemID: itemID,
            facet: .history,
            version: ContentVersion(rawValue: snapshotID),
            digest: captureDigest
        )
        let controller = try PersistenceController(directory: copiedFixture)
        addTeardownBlock { try await controller.close() }
        let resolved = try await ContentRepository(controller: controller).read(ref)
        XCTAssertEqual(resolved.integrity, .complete)
        XCTAssertEqual(resolved.representations.map(\.id), [
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        ])
        XCTAssertEqual(resolved.representations.map(\.typeIdentifier), [
            "public.utf8-plain-text", "public.html", "public.data"
        ])
        XCTAssertEqual(resolved.representations.map(\.bytes), [
            Data("Schema V1 fixture — 中文\n".utf8),
            Data("<p>Schema V1 fixture</p>".utf8),
            Data([0x00, 0x01, 0x7f, 0xff])
        ].map(Optional.some))

        let state = try await ContentRepository(controller: controller).recordState(.item(itemID))
        guard case .item(let item) = state.value else {
            return XCTFail("Fixture item did not decode as LibraryItem")
        }
        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(item.sourceApp, "io.keeptide.synthetic-fixture")
        XCTAssertEqual(item.title, "Schema V1 Synthetic Fixture")
        XCTAssertEqual(item.captureID, snapshotID)
        XCTAssertTrue(item.isFavorite)
        XCTAssertTrue(item.historyEligible)
        XCTAssertEqual(item.lastCopiedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(item.copyCount, 7)

        let usage = try await LocalUsageStore(controller: controller).summaries(for: [ref])
        XCTAssertEqual(usage, [
            UsageSummary(
                itemID: itemID,
                facet: .history,
                lastUsedAt: Date(timeIntervalSince1970: 1_700_000_200),
                useCount: 1
            )
        ])
        try await controller.close()

        XCTAssertEqual(try hashes(in: fixture), sourceHashesBefore)
    }

    private func hashes(in directory: URL) throws -> [String: Data] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var result: [String: Data] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            let relativePath = String(file.path.dropFirst(directory.path.count + 1))
            result[relativePath] = Data(SHA256.hash(data: try Data(contentsOf: file)))
        }
        return result
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
