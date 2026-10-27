import CoreData
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class FileReferencePrivacyTests: XCTestCase {
    func testPortableSystemFileReferencesAreRejectedAcrossModernLegacyAndDerivedTypes() async throws {
        try await withStore { controller in
            var cases: [(name: String, typeIdentifier: String, bytes: Data)] = [
                ("file URL", "public.file-url", Data("file:///Synthetic/report.txt".utf8)),
                ("uppercase file URL", "PUBLIC.FILE-URL", Data("file:///Synthetic/report.txt".utf8)),
                ("file list", "NSFilenamesPboardType", try PropertyListSerialization.data(
                    fromPropertyList: ["/Synthetic/report.txt"],
                    format: .binary,
                    options: 0
                )),
                ("promised file", "com.apple.pasteboard.promised-file-url", Data("file:///Synthetic/report.txt".utf8)),
                ("legacy Apple URL", "Apple URL pasteboard type", Data("file:///Synthetic/report.txt".utf8)),
                ("legacy Core Pasteboard URL", "CorePasteboardFlavorType 0x6675726C", Data("file:///Synthetic/report.txt".utf8)),
                ("generic URL containing a file URL", "public.url", Data("file:///Synthetic/report.txt".utf8))
            ]
            cases.append(contentsOf: [
                (
                    name: "derived file list",
                    typeIdentifier: "dyn.agu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",
                    bytes: Data("/Synthetic/report.txt".utf8)
                ),
                (
                    name: "derived Apple URL",
                    typeIdentifier: "dyn.agu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
                    bytes: Data("file:///Synthetic/report.txt".utf8)
                ),
                (
                    name: "derived Core Pasteboard URL",
                    typeIdentifier: "dyn.agu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0g25xnr3wg3bu",
                    bytes: Data("file:///Synthetic/report.txt".utf8)
                )
            ])

            for testCase in cases {
                let capture = try ContentStoreFixtures.capture([[
                    (testCase.typeIdentifier, testCase.bytes)
                ]])
                let item = ContentStoreFixtures.item(capture)

                do {
                    _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                        identity: try await controller.identity(),
                        mutations: [.insert(.capture(capture)), .insert(.item(item))]
                    ))
                    XCTFail("Accepted portable local file reference: \(testCase.name) [\(testCase.typeIdentifier)]")
                } catch {
                    XCTAssertEqual(
                        error as? StoreError,
                        .invalidTransaction,
                        "Unexpected error for \(testCase.name) [\(testCase.typeIdentifier)]"
                    )
                }
                let persistedCount = try await representationCount(snapshotID: capture.id, in: controller)
                XCTAssertEqual(persistedCount, 0, "Partially persisted \(testCase.name)")
            }
        }
    }

    func testPortableWebURLsAndPlainTextThatLooksLikeAPathRemainUserData() async throws {
        try await withStore { controller in
            let cases: [(name: String, typeIdentifier: String, bytes: Data)] = [
                ("web URL", "public.url", Data("https://example.invalid/document".utf8)),
                ("plain POSIX path", "public.utf8-plain-text", Data("/Users/example/Documents/report.txt".utf8)),
                ("plain file URL text", "public.utf8-plain-text", Data("file:///Users/example/Documents/report.txt".utf8))
            ]

            for testCase in cases {
                let capture = try ContentStoreFixtures.capture([[
                    (testCase.typeIdentifier, testCase.bytes)
                ]])
                let item = ContentStoreFixtures.item(capture)

                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.capture(capture)), .insert(.item(item))]
                ))

                let persistedCount = try await representationCount(snapshotID: capture.id, in: controller)
                XCTAssertEqual(persistedCount, 1, "Rejected ordinary user data: \(testCase.name)")
            }
        }
    }

    private func representationCount(
        snapshotID: UUID,
        in controller: PersistenceController
    ) async throws -> Int {
        try await controller.perform { context in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
            return try context.count(for: request)
        }
    }

    private func withStore<T: Sendable>(
        _ body: (PersistenceController) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-FileReferencePrivacyTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let result = try await body(controller)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
