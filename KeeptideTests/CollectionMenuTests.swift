import XCTest
@testable import Keeptide

final class CollectionMenuTests: XCTestCase {
    private let prompts = CollectionValue(name: "Prompts", color: "blue", sortOrder: 0)
    private let drafts = CollectionValue(name: "Drafts", color: "orange", sortOrder: 1)
    private let shell = CollectionValue(name: "Shell", color: "green", sortOrder: 2)

    func testRowsFollowTheSidebarOrderBeforeNewCollection() {
        let entries = CollectionMenu.make(collections: [drafts, prompts], memberships: [])

        XCTAssertEqual(entries.map(\.title), ["Drafts", "Prompts", "", "New Collection…"])
        XCTAssertEqual(entries.map(\.isSeparator), [false, false, true, false])
        XCTAssertEqual(entries[0].collectionID, drafts.id)
        XCTAssertEqual(entries[0].color, "orange")
        XCTAssertTrue(entries[3].isNewCollection)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertTrue(entries.filter(\.isChecked).isEmpty)
    }

    func testEveryCollectionTheSnippetIsInIsChecked() {
        let entries = CollectionMenu.make(collections: [prompts, drafts, shell], memberships: [[drafts.id, shell.id]])

        XCTAssertEqual(entries.filter(\.isChecked).map(\.collectionID), [drafts.id, shell.id])
    }

    func testOnlyACollectionAllOfTheSelectionIsInIsChecked() {
        let entries = CollectionMenu.make(collections: [prompts, drafts, shell],
                                          memberships: [[prompts.id, drafts.id], [drafts.id], [drafts.id, shell.id]])

        XCTAssertEqual(entries.filter(\.isChecked).map(\.collectionID), [drafts.id])
        XCTAssertTrue(CollectionMenu.isEveryOne(of: [[prompts.id, drafts.id], [drafts.id]], in: drafts.id))
        XCTAssertFalse(CollectionMenu.isEveryOne(of: [[prompts.id, drafts.id], [drafts.id]], in: prompts.id))
    }

    func testAnItemInNoCollectionChecksNothing() {
        let entries = CollectionMenu.make(collections: [prompts, drafts], memberships: [[], [prompts.id]])

        XCTAssertTrue(entries.filter(\.isChecked).isEmpty)
        XCTAssertFalse(CollectionMenu.isEveryOne(of: [], in: prompts.id))
    }

    func testWithoutCollectionsOnlyNewCollectionRemains() {
        var deleted = drafts
        deleted.deletedAt = Date()

        let entries = CollectionMenu.make(collections: [deleted], memberships: [[deleted.id]])

        XCTAssertEqual(entries.map(\.title), ["New Collection…"])
    }

    func testThePanelLeavesOutNewCollection() {
        let entries = CollectionMenu.make(collections: [prompts], memberships: [], includesNewCollection: false)

        XCTAssertEqual(entries.map(\.title), ["Prompts"])
    }

    func testABadgeNamesOneCollectionAndCountsPastThree() {
        let ordered = [prompts, drafts, shell]
        let fourth = CollectionValue(name: "Archive", color: "gray", sortOrder: 3)

        XCTAssertEqual(CollectionBadge.caption(for: [prompts]), "Prompts")
        XCTAssertEqual(CollectionBadge.caption(for: [prompts, drafts]), "")
        XCTAssertEqual(CollectionBadge.dots(for: ordered + [fourth]).shown.map(\.id), ordered.map(\.id))
        XCTAssertEqual(CollectionBadge.caption(for: ordered + [fourth]), "+1")
        // The collections come in the sidebar's order, whatever the order of the ids; deleted ones are left out.
        var deleted = fourth
        deleted.deletedAt = Date()
        XCTAssertEqual(CollectionBadge.collections([shell.id, prompts.id, deleted.id], in: ordered + [deleted]).map(\.id),
                       [prompts.id, shell.id])
        XCTAssertEqual(CollectionBadge.ordered([shell.id, CollectionID(), prompts.id], by: ordered.map(\.id)).prefix(2),
                       [prompts.id, shell.id])
    }
}
