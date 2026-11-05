import XCTest
@testable import Keeptide

final class CollectionMenuTests: XCTestCase {
    private let prompts = CollectionValue(name: "Prompts", color: "blue", sortOrder: 0)
    private let drafts = CollectionValue(name: "Drafts", color: "orange", sortOrder: 1)

    func testRowsFollowTheSidebarOrderBetweenUnfiledAndNewCollection() {
        let entries = CollectionMenu.make(collections: [drafts, prompts], current: [])

        XCTAssertEqual(entries.map(\.title), ["Unfiled", "", "Drafts", "Prompts", "", "New Collection…"])
        XCTAssertEqual(entries.map(\.isSeparator), [false, true, false, false, true, false])
        XCTAssertTrue(entries[0].isUnfiled)
        XCTAssertEqual(entries[2].collectionID, drafts.id)
        XCTAssertEqual(entries[2].color, "orange")
        XCTAssertTrue(entries[5].isNewCollection)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertTrue(entries.filter(\.isChecked).isEmpty)
    }

    func testTheSelectionsCollectionIsChecked() {
        let entries = CollectionMenu.make(collections: [prompts, drafts], current: [drafts.id])

        XCTAssertEqual(entries.filter(\.isChecked).map(\.collectionID), [drafts.id])
    }

    func testUnfiledIsCheckedWhenTheSelectionIsInNoCollection() {
        let entries = CollectionMenu.make(collections: [prompts, drafts], current: [nil])

        XCTAssertEqual(entries.filter(\.isChecked).map(\.isUnfiled), [true])
    }

    func testAMixedSelectionChecksNothing() {
        let entries = CollectionMenu.make(collections: [prompts, drafts], current: [nil, prompts.id])

        XCTAssertTrue(entries.filter(\.isChecked).isEmpty)
    }

    func testWithoutCollectionsOnlyUnfiledAndNewCollectionRemain() {
        var deleted = drafts
        deleted.deletedAt = Date()

        let entries = CollectionMenu.make(collections: [deleted], current: [nil])

        XCTAssertEqual(entries.map(\.title), ["Unfiled", "", "New Collection…"])
        XCTAssertTrue(entries[0].isChecked)
    }

    func testThePanelLeavesOutNewCollection() {
        let entries = CollectionMenu.make(collections: [prompts], current: [], includesNewCollection: false)

        XCTAssertEqual(entries.map(\.title), ["Unfiled", "", "Prompts"])
    }
}
