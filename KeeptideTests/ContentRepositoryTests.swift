import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class ContentRepositoryTests: XCTestCase {
    func testCreatesPortableAndLocalSQLiteStoresOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close(); try FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Content.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Local.sqlite").path))
    }

    func testMultipleItemsAndFormatsSurviveCloseAndReopenByteForByte() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close(); try FileManager.default.removeItem(at: directory) }
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("hello 中文\u{0}".utf8)),
             ("public.rtf", Data([0x7b, 0x5c, 0x72, 0x74, 0x66, 0x7d]))],
            [("public.png", Data([0, 1, 2, 255]))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        try await controller.close()
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try await reopened.close() }
        let result = try await ContentRepository(controller: reopened).read(ContentStoreFixtures.ref(item, capture))
        XCTAssertTrue(result.isActionable)
        XCTAssertEqual(result.representations, capture.representations)
        let rows = try await ContentRepository(controller: reopened).recent(limit: 10)
        XCTAssertEqual(rows.map(\.itemID), [item.id])
        try await reopened.close()
    }
}
