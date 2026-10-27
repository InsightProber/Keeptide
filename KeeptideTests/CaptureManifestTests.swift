import CryptoKit
import Foundation
import XCTest
@testable import Keeptide

final class CaptureManifestTests: XCTestCase {
    func testCanonicalDataUsesStableSortedJSONWithoutRandomRepresentationIdentity() throws {
        let manifest = CaptureManifest(
            itemCount: 1,
            entries: [
                ManifestEntry(
                    itemIndex: 0,
                    representationIndex: 0,
                    typeIdentifier: "public.utf8-plain-text",
                    storage: .portable,
                    byteCount: 1,
                    digest: Data([1, 2])
                )
            ]
        )

        XCTAssertEqual(
            String(decoding: try manifest.canonicalData(), as: UTF8.self),
            #"{"entries":[{"byteCount":1,"digest":"AQI=","itemIndex":0,"representationIndex":0,"storage":"portable","typeIdentifier":"public.utf8-plain-text"}],"itemCount":1,"version":1}"#
        )
    }

    func testEquivalentVisibleTextWithDifferentRepresentationsHasDifferentCanonicalData() throws {
        let plainBytes = Data("hello".utf8)
        let htmlBytes = Data("<p>hello</p>".utf8)
        let plain = manifest(typeIdentifier: "public.utf8-plain-text", bytes: plainBytes)
        let html = manifest(typeIdentifier: "public.html", bytes: htmlBytes)

        XCTAssertNotEqual(try plain.canonicalData(), try html.canonicalData())
        XCTAssertNotEqual(
            ContentDigest.sha256(try plain.canonicalData()),
            ContentDigest.sha256(try html.canonicalData())
        )
    }

    func testEquivalentContentIgnoresRandomRepresentationAndSnapshotIdentities() throws {
        let bytes = Data("same bytes".utf8)
        let digest = sha256(bytes)
        let firstSnapshot = UUID()
        let secondSnapshot = UUID()
        let first = RepresentationValue(
            id: UUID(), snapshotID: firstSnapshot, itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.data", storage: .portable,
            byteCount: Int64(bytes.count), digest: digest, bytes: bytes
        )
        let second = RepresentationValue(
            id: UUID(), snapshotID: secondSnapshot, itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.data", storage: .portable,
            byteCount: Int64(bytes.count), digest: digest, bytes: bytes
        )
        let firstManifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(first)])
        let secondManifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(second)])

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.snapshotID, second.snapshotID)
        XCTAssertEqual(try firstManifest.canonicalData(), try secondManifest.canonicalData())
    }

    func testCompleteMixedPortableAndLocalReferenceCaptureIsValidWithoutLocalBytes() {
        let snapshotID = UUID()
        let text = Data("portable".utf8)
        let localDigest = sha256(Data("local file bytes live outside CloudContent".utf8))
        let representations = [
            representation(snapshotID: snapshotID, itemIndex: 0, representationIndex: 0,
                           typeIdentifier: "public.utf8-plain-text", bytes: text),
            RepresentationValue(
                snapshotID: snapshotID, itemIndex: 0, representationIndex: 1,
                typeIdentifier: "public.file-url", storage: .localReference,
                byteCount: 43, digest: localDigest, bytes: nil
            )
        ]
        let manifest = CaptureManifest(itemCount: 1, entries: representations.map(ManifestEntry.init))

        XCTAssertEqual(manifest.validate(representations, snapshotID: snapshotID), .complete)
    }

    func testMissingPortablePayloadIsRecovering() {
        let snapshotID = UUID()
        let bytes = Data("not restored yet".utf8)
        let value = representation(snapshotID: snapshotID, bytes: bytes, includePayload: false)
        let manifest = CaptureManifest(itemCount: 1, entries: [
            ManifestEntry(itemIndex: 0, representationIndex: 0, typeIdentifier: value.typeIdentifier,
                          storage: .portable, byteCount: Int64(bytes.count), digest: sha256(bytes))
        ])

        XCTAssertEqual(manifest.validate([value], snapshotID: snapshotID), .recovering)
    }

    func testMissingRepresentationIsRecovering() {
        let bytes = Data("one".utf8)
        let manifest = CaptureManifest(itemCount: 1, entries: [
            ManifestEntry(itemIndex: 0, representationIndex: 0, typeIdentifier: "public.data",
                          storage: .portable, byteCount: Int64(bytes.count), digest: sha256(bytes))
        ])

        XCTAssertEqual(manifest.validate([], snapshotID: UUID()), .recovering)
    }

    func testMissingRepresentationBeforeARestoredRepresentationIsRecovering() {
        let snapshotID = UUID()
        let missing = representation(snapshotID: snapshotID, representationIndex: 0, bytes: Data([1]))
        let restored = representation(snapshotID: snapshotID, representationIndex: 1, bytes: Data([2]))
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(missing), ManifestEntry(restored)])

        XCTAssertEqual(manifest.validate([restored], snapshotID: snapshotID), .recovering)
    }

    func testExtraRepresentationIsCorrupt() {
        let snapshotID = UUID()
        let first = representation(snapshotID: snapshotID, representationIndex: 0, bytes: Data([1]))
        let extra = representation(snapshotID: snapshotID, representationIndex: 1, bytes: Data([2]))
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(first)])

        XCTAssertEqual(manifest.validate([first, extra], snapshotID: snapshotID), .corrupt)
    }

    func testDuplicateRepresentationIdentityIsCorrupt() {
        let snapshotID = UUID()
        let duplicateID = UUID()
        let first = representation(id: duplicateID, snapshotID: snapshotID, representationIndex: 0,
                                   bytes: Data([1]))
        let second = representation(id: duplicateID, snapshotID: snapshotID, representationIndex: 1,
                                    bytes: Data([2]))
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(first), ManifestEntry(second)])

        XCTAssertEqual(manifest.validate([first, second], snapshotID: snapshotID), .corrupt)
    }

    func testWrongSnapshotTypeLengthOrDigestIsCorrupt() {
        let snapshotID = UUID()
        let bytes = Data("payload".utf8)
        let valid = representation(snapshotID: snapshotID, bytes: bytes)
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(valid)])

        var wrongSnapshot = valid
        wrongSnapshot.snapshotID = UUID()
        var wrongType = valid
        wrongType.typeIdentifier = "public.html"
        var wrongLength = valid
        wrongLength.byteCount += 1
        var wrongDigest = valid
        wrongDigest.digest = Data(repeating: 0, count: 32)
        var corruptBytes = valid
        corruptBytes.bytes = Data("payloae".utf8)

        XCTAssertEqual(manifest.validate([wrongSnapshot], snapshotID: snapshotID), .corrupt)
        XCTAssertEqual(manifest.validate([wrongType], snapshotID: snapshotID), .corrupt)
        XCTAssertEqual(manifest.validate([wrongLength], snapshotID: snapshotID), .corrupt)
        XCTAssertEqual(manifest.validate([wrongDigest], snapshotID: snapshotID), .corrupt)
        XCTAssertEqual(manifest.validate([corruptBytes], snapshotID: snapshotID), .corrupt)
    }

    func testLocalReferenceContainingPortableBytesIsCorrupt() {
        let snapshotID = UUID()
        let bytes = Data("must remain local".utf8)
        let value = RepresentationValue(
            snapshotID: snapshotID, itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.file-url", storage: .localReference,
            byteCount: Int64(bytes.count), digest: sha256(bytes), bytes: bytes
        )
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(value)])

        XCTAssertEqual(manifest.validate([value], snapshotID: snapshotID), .corrupt)
    }

    func testNoncontiguousOrUnorderedManifestCoordinatesAreCorrupt() {
        let digest = Data(repeating: 1, count: 32)
        let gap = CaptureManifest(itemCount: 1, entries: [
            ManifestEntry(itemIndex: 0, representationIndex: 1, typeIdentifier: "public.data",
                          storage: .portable, byteCount: 0, digest: digest)
        ])
        let unordered = CaptureManifest(itemCount: 1, entries: [
            ManifestEntry(itemIndex: 0, representationIndex: 1, typeIdentifier: "public.data",
                          storage: .localReference, byteCount: 0, digest: digest),
            ManifestEntry(itemIndex: 0, representationIndex: 0, typeIdentifier: "public.data",
                          storage: .localReference, byteCount: 0, digest: digest)
        ])

        XCTAssertEqual(gap.validate([], snapshotID: UUID()), .corrupt)
        XCTAssertEqual(unordered.validate([], snapshotID: UUID()), .corrupt)
    }

    func testManifestCannotStartAtItemOne() {
        let manifest = CaptureManifest(itemCount: 2, entries: [
            ManifestEntry(itemIndex: 1, representationIndex: 0, typeIdentifier: "public.data",
                          storage: .portable, byteCount: 0, digest: Data(repeating: 1, count: 32))
        ])

        XCTAssertEqual(manifest.validate([], snapshotID: UUID()), .corrupt)
    }

    func testResolvedContentIsActionableOnlyWhenIntegrityIsComplete() {
        let ref = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data())
        let untrusted = RepresentationValue(
            snapshotID: UUID(), itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.data", storage: .portable,
            byteCount: 0, digest: Data(repeating: 0, count: 32), bytes: Data()
        )

        XCTAssertTrue(ResolvedContent(ref: ref, integrity: .complete, representations: []).isActionable)
        XCTAssertFalse(ResolvedContent(ref: ref, integrity: .recovering, representations: []).isActionable)
        XCTAssertFalse(ResolvedContent(ref: ref, integrity: .corrupt, representations: []).isActionable)
        XCTAssertFalse(ResolvedContent(ref: ref, integrity: .requiresRelocation, representations: []).isActionable)
        XCTAssertTrue(ResolvedContent(ref: ref, integrity: .corrupt, representations: [untrusted]).representations.isEmpty)
    }

    private func manifest(typeIdentifier: String, bytes: Data) -> CaptureManifest {
        CaptureManifest(itemCount: 1, entries: [
            ManifestEntry(itemIndex: 0, representationIndex: 0, typeIdentifier: typeIdentifier,
                          storage: .portable, byteCount: Int64(bytes.count), digest: sha256(bytes))
        ])
    }

    private func representation(
        id: UUID = UUID(),
        snapshotID: UUID,
        itemIndex: Int = 0,
        representationIndex: Int = 0,
        typeIdentifier: String = "public.data",
        bytes: Data,
        includePayload: Bool = true
    ) -> RepresentationValue {
        RepresentationValue(
            id: id,
            snapshotID: snapshotID,
            itemIndex: itemIndex,
            representationIndex: representationIndex,
            typeIdentifier: typeIdentifier,
            storage: .portable,
            byteCount: Int64(bytes.count),
            digest: sha256(bytes),
            bytes: includePayload ? bytes : nil
        )
    }

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
