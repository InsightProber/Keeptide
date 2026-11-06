import Foundation

/// One row of the collection menu, shared by every place that offers it: the Library's toolbar menu, context
/// menu and inspector picker, and the quick-access panel's menu. Each renders the same rows its own way.
struct CollectionMenuEntry: Equatable, Sendable, Identifiable {
    enum Role: Equatable, Sendable {
        case unfiled
        case collection(CollectionID)
        case newCollection
        case separator
    }

    let id: String
    let role: Role
    let title: String
    /// The collection's color name; nil on every other row.
    let color: String?
    /// On when every selected memo is in this row's place.
    let isChecked: Bool

    var isUnfiled: Bool { role == .unfiled }
    var isNewCollection: Bool { role == .newCollection }
    var isSeparator: Bool { role == .separator }
    var collectionID: CollectionID? {
        if case .collection(let id) = role { return id }
        return nil
    }
}

enum CollectionMenu {
    static let unfiledTitle = "Unfiled"
    static let newCollectionTitle = "New Collection…"

    /// Rows in menu order: Unfiled, a separator, the collections in the order given (the sidebar's), a separator
    /// and New Collection…. `current` holds where each selected memo is, nil for unfiled: one place checks its row,
    /// several check none. Deleted collections are left out; without any collection only Unfiled and New Collection…
    /// remain. The quick-access panel never creates collections and passes `includesNewCollection: false`.
    static func make(
        collections: [CollectionValue], current: Set<CollectionID?>, includesNewCollection: Bool = true
    ) -> [CollectionMenuEntry] {
        var entries = [CollectionMenuEntry(
            id: "unfiled", role: .unfiled, title: unfiledTitle, color: nil,
            isChecked: current.count == 1 && current.contains(nil)
        )]
        let active = collections.filter { $0.deletedAt == nil }
        if !active.isEmpty {
            entries.append(separator("separator-collections"))
            entries += active.map { collection in
                CollectionMenuEntry(
                    id: collection.id.rawValue.uuidString, role: .collection(collection.id),
                    title: collection.name, color: collection.color,
                    isChecked: current.count == 1 && current.contains(collection.id)
                )
            }
        }
        if includesNewCollection {
            entries.append(separator("separator-new"))
            entries.append(CollectionMenuEntry(
                id: "new-collection", role: .newCollection, title: newCollectionTitle, color: nil, isChecked: false
            ))
        }
        return entries
    }

    private static func separator(_ id: String) -> CollectionMenuEntry {
        CollectionMenuEntry(id: id, role: .separator, title: "", color: nil, isChecked: false)
    }
}
