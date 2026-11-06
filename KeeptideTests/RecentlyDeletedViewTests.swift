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

        XCTAssertEqual(RecentlyDeletedPresentation.facetName(history.identity.facet), "Clip")
        XCTAssertEqual(RecentlyDeletedPresentation.facetName(memo.identity.facet), "Snippet")
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
            "Permanently Delete Snippet?"
        )
        XCTAssertEqual(
            RecentlyDeletedPresentation.permanentConfirmationMessage(for: row),
            "“Production prompt” will be removed for good. This cannot be undone."
        )
    }

    func testARowSaysWhenItWasDeletedWhatItWasAndOnlyThenWhenItGoes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let english = Locale(identifier: "en_US")
        func row(deletedHoursAgo: Double, removedInHours: Double, facet: ContentFacet) -> TrashFacetSnapshot {
            TrashFacetSnapshot(
                identity: facet == .memo ? .memo(itemID: ItemID(), memoID: UUID())
                    : .history(itemID: ItemID(), captureID: UUID()),
                title: "Synthetic", deletedAt: now.addingTimeInterval(-deletedHoursAgo * 3_600),
                purgeAfter: now.addingTimeInterval(removedInHours * 3_600), canRestore: true
            )
        }

        XCTAssertEqual(
            RecentlyDeletedPresentation.metadata(for: row(deletedHoursAgo: 48, removedInHours: 120, facet: .memo),
                                                 now: now, locale: english),
            "Deleted 2 days ago · Snippet"
        )
        // A day or less before it goes, the row says when.
        XCTAssertEqual(
            RecentlyDeletedPresentation.metadata(for: row(deletedHoursAgo: 144, removedInHours: 20, facet: .history),
                                                 now: now, locale: english),
            "Deleted 6 days ago · Clip · Removed in 20 hours"
        )
        XCTAssertEqual(RecentlyDeletedPresentation.retentionNote,
                       "Deleted items are kept for \(Int(DeletionWindow.duration / 86_400)) days, then removed permanently.")
    }
}
