import XCTest
@testable import Keeptide

final class RecentlyDeletedViewTests: XCTestCase {
    func testRowsNameExactFacetAndExplainWhyRestoreIsUnavailable() {
        let now = Date(timeIntervalSince1970: 1_000)
        let history = TrashFacetSnapshot(
            identity: .history(itemID: ItemID(), captureID: UUID()),
            title: "Copied command",
            deletedAt: now,
            purgeAfter: now.addingTimeInterval(7 * 24 * 60 * 60),
            canRestore: false
        )
        let memo = TrashFacetSnapshot(
            identity: .memo(itemID: ItemID(), memoID: UUID()),
            title: "Saved prompt",
            deletedAt: now,
            purgeAfter: now,
            canRestore: false
        )

        XCTAssertEqual(RecentlyDeletedPresentation.facetName(history.identity.facet), "Clipboard History")
        XCTAssertEqual(RecentlyDeletedPresentation.facetName(memo.identity.facet), "Saved Snippet")
        XCTAssertTrue(RecentlyDeletedPresentation.restoreUnavailableReason(for: history).contains("retention"))
        XCTAssertTrue(RecentlyDeletedPresentation.restoreUnavailableReason(for: memo).contains("recovery window"))
    }

    func testPermanentConfirmationNamesTheExactFacetAndTitle() {
        let row = TrashFacetSnapshot(
            identity: .memo(itemID: ItemID(), memoID: UUID()),
            title: "Production prompt",
            deletedAt: Date(),
            purgeAfter: Date().addingTimeInterval(60),
            canRestore: true
        )

        XCTAssertEqual(
            RecentlyDeletedPresentation.permanentConfirmationTitle(for: row),
            "Permanently Delete Saved Snippet?"
        )
        XCTAssertTrue(
            RecentlyDeletedPresentation.permanentConfirmationMessage(for: row)
                .contains("Production prompt")
        )
    }
}
