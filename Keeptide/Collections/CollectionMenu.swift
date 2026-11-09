import Foundation

/// One row of the collection menu, shared by every place that offers it: the Library's toolbar menu, context
/// menu and Item menu, and the quick-access panel's menus. Each renders the same rows its own way.
struct CollectionMenuEntry: Equatable, Sendable, Identifiable {
    enum Role: Equatable, Sendable {
        case collection(CollectionID)
        case newCollection
        case separator
    }

    let id: String
    let role: Role
    let title: String
    /// The collection's color name; nil on every other row.
    let color: String?
    /// On when every selected item is in this collection: choosing it then takes them out of it.
    let isChecked: Bool

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

    /// Rows in menu order: the collections in the order given (the sidebar's), then a separator and New
    /// Collection…. `memberships` holds the collections of each selected item, empty for one in none, such as a clip
    /// not yet saved: a collection is checked when every one of them is in it. A snippet belongs to as many
    /// collections as it is added to, so there is no Unfiled row; it is where a snippet in none is listed. Deleted
    /// collections are left out. The quick-access panel never creates collections and passes
    /// `includesNewCollection: false`.
    static func make(
        collections: [CollectionValue], memberships: [Set<CollectionID>], includesNewCollection: Bool = true
    ) -> [CollectionMenuEntry] {
        var entries = collections.filter { $0.deletedAt == nil }.map { collection in
            CollectionMenuEntry(
                id: collection.id.rawValue.uuidString, role: .collection(collection.id),
                title: collection.name, color: collection.color,
                isChecked: isEveryOne(of: memberships, in: collection.id)
            )
        }
        if includesNewCollection {
            if !entries.isEmpty { entries.append(separator("separator-new")) }
            entries.append(CollectionMenuEntry(
                id: "new-collection", role: .newCollection, title: newCollectionTitle, color: nil, isChecked: false
            ))
        }
        return entries
    }

    /// Whether choosing `id` takes the items out of it rather than adds them: every one is in it already.
    static func isEveryOne(of memberships: [Set<CollectionID>], in id: CollectionID) -> Bool {
        !memberships.isEmpty && memberships.allSatisfy { $0.contains(id) }
    }

    private static func separator(_ id: String) -> CollectionMenuEntry {
        CollectionMenuEntry(id: id, role: .separator, title: "", color: nil, isChecked: false)
    }
}

/// How a row, a header or a card names a snippet's collections: one by its dot and name, several by up to three
/// dots and how many more there are, with every name in the help and for VoiceOver.
enum CollectionBadge {
    static let maximumDots = 3

    /// `ids` in the order `order` lists them (the sidebar's), and any it does not list after them as they were.
    static func ordered(_ ids: [CollectionID], by order: [CollectionID]) -> [CollectionID] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.enumerated()
            .sorted { (rank[$0.element] ?? .max, $0.offset) < (rank[$1.element] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// The collections among `collections` (in the sidebar's order) that `ids` names, and only those.
    static func collections(_ ids: [CollectionID], in collections: [CollectionValue]) -> [CollectionValue] {
        let wanted = Set(ids)
        return collections.filter { wanted.contains($0.id) && $0.deletedAt == nil }
    }

    /// The dots to draw, in order, and the number left over for "+N".
    static func dots(for collections: [CollectionValue]) -> (shown: [CollectionValue], more: Int) {
        (Array(collections.prefix(maximumDots)), max(0, collections.count - maximumDots))
    }

    /// The text beside the dots: the one collection's name, or "+N" when more than three; empty otherwise.
    static func caption(for collections: [CollectionValue]) -> String {
        if collections.count == 1 { return collections[0].name }
        let more = dots(for: collections).more
        return more > 0 ? "+\(more)" : ""
    }

    /// Every name as a list, such as "Prompts and Shell", for the help and for VoiceOver.
    static func names(of collections: [CollectionValue]) -> String {
        collections.map(\.name).formatted(.list(type: .and))
    }
}
