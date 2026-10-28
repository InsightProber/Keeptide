import Foundation

/// One result row. `ref` is the only identity an action may use.
struct QuickAccessRow: Identifiable, Equatable, Sendable {
    let ref: ContentRef
    let title: String
    let snippet: SearchSnippet?
    let kind: ContentKind
    /// Bundle identifier of the app the clip came from.
    let sourceApp: String?
    let date: Date
    let savedAsMemo: Bool
    let isPartiallyIndexed: Bool
    let isTextUnavailable: Bool

    var id: ContentRef { ref }
}

enum SelectionMove: Equatable {
    case moved, atTop, atBottom, unchanged
}

/// Which row is selected, and whether it may be acted on, for one query generation.
///
/// A new generation keeps the old rows on screen but makes them inert. Its first
/// page selects the top row; incomplete pages keep following the top until the user
/// chooses a row. After that, refreshes keep the chosen identity, and a selection
/// that disappears is cleared rather than moved to a neighbour the user never saw.
struct SelectionCoordinator: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var rows: [QuickAccessRow] = []
    private(set) var selection: ContentRef?
    private(set) var selectionLost = false
    private var hasPage = false
    private var isComplete = false
    private var userChose = false

    var executableSelection: ContentRef? {
        guard hasPage, let selection, isComplete || userChose else { return nil }
        return selection
    }

    mutating func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        hasPage = false
        isComplete = false
        userChose = false
        selectionLost = false
    }

    mutating func apply(_ rows: [QuickAccessRow], generation: UInt64, isComplete: Bool) {
        guard generation == self.generation else { return }
        let followsTop = !hasPage || (!self.isComplete && !userChose)
        self.rows = rows
        hasPage = true
        self.isComplete = isComplete
        if followsTop {
            selection = rows.first?.ref
        } else if let selection, !rows.contains(where: { $0.ref == selection }) {
            self.selection = nil
            selectionLost = true
        }
    }

    mutating func append(_ rows: [QuickAccessRow], generation: UInt64) {
        guard generation == self.generation, hasPage else { return }
        let existing = Set(self.rows.map(\.ref))
        self.rows += rows.filter { !existing.contains($0.ref) }
    }

    mutating func select(_ ref: ContentRef) {
        guard rows.contains(where: { $0.ref == ref }) else { return }
        choose(ref)
    }

    mutating func move(by offset: Int) -> SelectionMove {
        guard !rows.isEmpty else { return offset < 0 ? .atTop : .unchanged }
        guard let selection, let index = rows.firstIndex(where: { $0.ref == selection }) else {
            guard offset > 0 else { return .atTop }
            choose(rows[0].ref)
            return .moved
        }
        let target = index + offset
        if target < 0 { return .atTop }
        if target >= rows.count { return .atBottom }
        choose(rows[target].ref)
        return .moved
    }

    private mutating func choose(_ ref: ContentRef) {
        selection = ref
        userChose = true
        selectionLost = false
    }
}
