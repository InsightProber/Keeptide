import Foundation
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
}
