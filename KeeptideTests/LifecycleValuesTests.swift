import Foundation
import XCTest
@testable import Keeptide

final class LifecycleValuesTests: XCTestCase {
    func testDeletedFacetIdentityUsesCaptureForHistoryAndMemoIDForMemo() {
        let itemID = ItemID()
        let captureID = UUID()
        let memoID = UUID()
        let contentVersion = UUID()

        XCTAssertEqual(
            DeletedFacetIdentity.history(itemID: itemID, captureID: captureID),
            DeletedFacetIdentity(itemID: itemID, facet: .history, generationID: captureID)
        )
        let memo = DeletedFacetIdentity.memo(itemID: itemID, memoID: memoID)
        XCTAssertEqual(memo, DeletedFacetIdentity(itemID: itemID, facet: .memo, generationID: memoID))
        XCTAssertNotEqual(memo.generationID, contentVersion, "Memo cleanup identity must never use its body version")
    }

    func testCleanupPayloadIdentityCanonicalDataCoversEveryDeletionFence() throws {
        let value = CleanupPayloadIdentity(
            representationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            envelopeByteCount: 42,
            envelopeDigest: Data([1, 2, 3]),
            cloudToken: Data([4, 5, 6])
        )

        XCTAssertEqual(try JSONDecoder().decode(CleanupPayloadIdentity.self, from: value.canonicalData()), value)
        let first = try value.canonicalData()
        let second = try value.canonicalData()
        XCTAssertEqual(first, second)
    }

    func testDurablePhasesAndRecoveryPermitRoundTripWithoutUnknownFallback() throws {
        XCTAssertEqual(Set(CleanupIntentPhase.allCases), [.prepared, .cloudCommitted, .completed, .blocked])
        XCTAssertEqual(Set(RawRecoveryPlanPhase.allCases), [.prepared, .reconciling, .completed, .blocked])
        let permit = RecoveryPermit(
            planID: UUID(),
            identity: StoreIdentity(storeID: UUID(), generation: UUID())
        )
        let encoded = try JSONEncoder().encode(permit)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryPermit.self, from: encoded), permit)
        XCTAssertThrowsError(try JSONDecoder().decode(
            CleanupIntentPhase.self,
            from: Data(#""futurePhase""#.utf8)
        ))
    }
}
