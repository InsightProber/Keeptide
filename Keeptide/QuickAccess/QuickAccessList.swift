import Foundation

/// Which rows quick access lists: every clip, every memo, or one collection's memos. The panel opens on `.all`.
enum QuickAccessList: Equatable, Sendable {
    case all
    case snippets
    case collection(CollectionID)
}

/// A collection as quick access knows it: read as the panel opens, and again when the Library changes them.
struct CollectionSummary: Equatable, Sendable, Identifiable {
    let id: CollectionID
    let name: String
    let color: String
    let sortOrder: Double
}

/// Where quick access reads the collections: the collection service, or a stand-in in tests.
protocol QuickAccessCollections: Sendable {
    /// The collections in the sidebar's order.
    func collections() async throws -> [CollectionSummary]
}

extension CollectionService: QuickAccessCollections {
    func collections() async throws -> [CollectionSummary] {
        try await list().map {
            CollectionSummary(id: $0.value.id, name: $0.value.name, color: $0.value.color, sortOrder: $0.value.sortOrder)
        }
    }
}

/// How quick access places snippets: in a collection, or none, and marked as a favorite or not. Only snippets are
/// placed; a clip is saved as one first.
protocol QuickAccessCollectionChanges: Sendable {
    /// Moves the snippets into `collection`, or out of any with nil. False when all were there already, and nothing
    /// was written. A collection that is no longer there throws `CollectionServiceError.deletedCollection`.
    func moveSnippets(_ refs: [ContentRef], into collection: CollectionID?, expecting identity: StoreIdentity?)
        async throws -> Bool
    func markSnippets(_ refs: [ContentRef], favorite: Bool, expecting identity: StoreIdentity?) async throws
}

extension CollectionService: QuickAccessCollectionChanges {
    func moveSnippets(_ refs: [ContentRef], into collection: CollectionID?, expecting identity: StoreIdentity?)
        async throws -> Bool {
        var target: CollectionSnapshot?
        if let collection {
            guard let snapshot = try await list(expecting: identity).first(where: { $0.value.id == collection }) else {
                throw CollectionServiceError.deletedCollection
            }
            target = snapshot
        }
        return try await move(refs, to: target, expecting: identity).affectedItems.isEmpty == false
    }

    func markSnippets(_ refs: [ContentRef], favorite: Bool, expecting identity: StoreIdentity?) async throws {
        _ = try await setFavorite(refs, isFavorite: favorite, expecting: identity)
    }
}
