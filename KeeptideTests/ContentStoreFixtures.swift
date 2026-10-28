import Foundation
import XCTest
@testable import Keeptide

enum ContentStoreFixtures {
    static func capture(_ items: [[(String, Data)]]) throws -> CaptureValue {
        let id = UUID()
        var values: [RepresentationValue] = []
        for (i, item) in items.enumerated() {
            for (r, representation) in item.enumerated() {
                values.append(RepresentationValue(snapshotID: id, itemIndex: i, representationIndex: r,
                    typeIdentifier: representation.0, storage: .portable,
                    byteCount: Int64(representation.1.count), digest: ContentDigest.sha256(representation.1),
                    bytes: representation.1))
            }
        }
        let manifest = CaptureManifest(itemCount: items.count, entries: values.map(ManifestEntry.init))
        return CaptureValue(id: id, manifest: manifest, digest: ContentDigest.sha256(try manifest.canonicalData()),
                            representations: values)
    }

    static func item(_ capture: CaptureValue, id: ItemID = ItemID()) -> ItemValue {
        ItemValue(id: id, title: "Synthetic content", captureID: capture.id, historyEligible: true, copyCount: 1)
    }

    static func ref(_ item: ItemValue, _ capture: CaptureValue, facet: ContentFacet = .history) -> ContentRef {
        ContentRef(itemID: item.id, facet: facet, version: ContentVersion(rawValue: capture.id), digest: capture.digest)
    }

    static func insert(_ item: ItemValue, _ capture: CaptureValue, into controller: PersistenceController) async throws {
        let transaction = StoreTransaction(identity: try await controller.identity(),
            mutations: [.insert(.capture(capture)), .insert(.item(item))])
        _ = try await WriteCoordinator(controller: controller).commit(transaction)
    }

    /// A one-item file reference whose URL bytes live only in local file-access state.
    static func localReferenceCapture() throws -> CaptureValue {
        let captureID = UUID()
        let representation = RepresentationValue(id: UUID(), snapshotID: captureID, itemIndex: 0,
            representationIndex: 0, typeIdentifier: "public.file-url", storage: .localReference,
            byteCount: 0, digest: Data(repeating: 0x59, count: 32), bytes: nil)
        let manifest = CaptureManifest(version: LocalReferencePrivacy.manifestVersion, itemCount: 1,
                                       entries: [ManifestEntry(representation)])
        return CaptureValue(id: captureID, manifest: manifest, digest: ContentDigest.sha256(try manifest.canonicalData()),
                            representations: [representation])
    }

    static func insertLocalReference(_ item: ItemValue, _ capture: CaptureValue,
                                     into controller: PersistenceController) async throws {
        let representation = try XCTUnwrap(capture.representations.first)
        try await FileAccessStore(controller: controller).put(
            LocalFileAccess(id: representation.id, snapshotID: capture.id, bytes: Data("file:///Synthetic/report.txt".utf8)),
            expecting: controller.identity()
        )
        try await insert(item, capture, into: controller)
    }
}
