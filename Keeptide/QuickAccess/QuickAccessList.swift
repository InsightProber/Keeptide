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

/// How quick access places snippets: in collections, or out of them, and marked as a favorite or not. Only snippets
/// are placed; a clip is saved as one first.
protocol QuickAccessCollectionChanges: Sendable {
    /// Adds the snippets to `collection`, each keeping its other collections. False when all were in it already, and
    /// nothing was written. A collection that is no longer there throws `CollectionServiceError.deletedCollection`.
    func addSnippets(_ refs: [ContentRef], to collection: CollectionID, expecting identity: StoreIdentity?)
        async throws -> Bool
    /// Takes the snippets out of `collection`, each keeping its others. False when none was in it.
    func removeSnippets(_ refs: [ContentRef], from collection: CollectionID, expecting identity: StoreIdentity?)
        async throws -> Bool
    func markSnippets(_ refs: [ContentRef], favorite: Bool, expecting identity: StoreIdentity?) async throws
}

extension CollectionService: QuickAccessCollectionChanges {
    func addSnippets(_ refs: [ContentRef], to collection: CollectionID, expecting identity: StoreIdentity?)
        async throws -> Bool {
        guard let snapshot = try await list(expecting: identity).first(where: { $0.value.id == collection }) else {
            throw CollectionServiceError.deletedCollection
        }
        return try await add(refs, to: snapshot, expecting: identity).affectedItems.isEmpty == false
    }

    func removeSnippets(_ refs: [ContentRef], from collection: CollectionID, expecting identity: StoreIdentity?)
        async throws -> Bool {
        try await remove(refs, from: collection, expecting: identity).affectedItems.isEmpty == false
    }

    func markSnippets(_ refs: [ContentRef], favorite: Bool, expecting identity: StoreIdentity?) async throws {
        _ = try await setFavorite(refs, isFavorite: favorite, expecting: identity)
    }
}
