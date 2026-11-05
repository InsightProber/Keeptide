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
