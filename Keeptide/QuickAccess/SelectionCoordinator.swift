import Foundation

/// One result row. The same clip may be listed twice, once in each wing, so a row is known by its `id`; `ref` is the
/// only identity an action may use.
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
    /// How many times the clip was used, for a row of the frequent wing; nil for recent clips and search results.
    var frequentUses: Int64? = nil

    /// A row's place in the list: its clip, and whether it is the clip's frequent copy.
    struct ID: Hashable, Sendable {
        let ref: ContentRef
        let isFrequent: Bool
    }

    var id: ID { ID(ref: ref, isFrequent: isFrequent) }
    var isFrequent: Bool { frequentUses != nil }
}

enum SelectionMove: Equatable {
    case moved, atTop, atBottom, unchanged
}

/// Which row is selected, and whether it may be acted on, for one query generation.
///
/// A new generation keeps the old rows on screen but makes them inert: they cannot be
/// chosen. Its first page selects the top row after the frequent wing, the newest recent
/// clip; incomplete pages keep following it until the user chooses a row. After that,
/// pages of the same search keep the chosen row even when late ranking pushes it out of
/// the window, and a re-read that no longer contains the selection clears it rather than
/// moving to a neighbour the user never saw. Rows are told apart by their `id`, so a clip
/// listed in both wings is two rows; actions take the selected row's clip.
struct SelectionCoordinator: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var rows: [QuickAccessRow] = []
    private(set) var selectedID: QuickAccessRow.ID?
    private(set) var selectionLost = false
    private var hasPage = false
    /// Whether the latest page of this generation ranked every candidate.
    private(set) var isComplete = false
    private var userChose = false

    /// The selected row's clip: what actions use.
    var selection: ContentRef? { selectedID?.ref }

    var selectedRow: QuickAccessRow? {
        selectedID.flatMap { selected in rows.first { $0.id == selected } }
    }

    /// How many rows lead the list as the frequent wing.
    var frequentCount: Int { rows.prefix { $0.isFrequent }.count }

    var executableSelection: ContentRef? {
        guard hasPage, let selectedID, isComplete || userChose else { return nil }
        return selectedID.ref
    }

    mutating func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        hasPage = false
        isComplete = false
        userChose = false
        selectionLost = false
    }

    mutating func apply(_ rows: [QuickAccessRow], generation: UInt64, isComplete: Bool,
                        keepsChosenRow: Bool = false) {
        guard generation == self.generation else { return }
        let followsTop = !hasPage || (!self.isComplete && !userChose)
        let previousRows = self.rows
        self.rows = rows
        hasPage = true
        self.isComplete = isComplete
        if followsTop {
            // The newest recent clip, after the frequent wing; the first row when every row is frequent.
            selectedID = (rows.first { !$0.isFrequent } ?? rows.first)?.id
        } else if let selectedID, !rows.contains(where: { $0.id == selectedID }) {
            if keepsChosenRow, let index = previousRows.firstIndex(where: { $0.id == selectedID }) {
                // One search reads one snapshot, so the row was re-ranked, not removed.
                self.rows.insert(previousRows[index], at: min(index, self.rows.count))
            } else {
                self.selectedID = nil
                selectionLost = true
            }
        }
    }

    mutating func append(_ rows: [QuickAccessRow], generation: UInt64) {
        guard generation == self.generation, hasPage else { return }
        // A page of recent clips keeps a clip the frequent wing lists as well: the two are different rows.
        let existing = Set(self.rows.map(\.id))
        self.rows += rows.filter { !existing.contains($0.id) }
    }

    mutating func select(_ id: QuickAccessRow.ID) {
        guard hasPage, rows.contains(where: { $0.id == id }) else { return }
        choose(id)
    }

    mutating func move(by offset: Int) -> SelectionMove {
        guard hasPage else { return .unchanged }
        guard !rows.isEmpty else { return offset < 0 ? .atTop : .unchanged }
        guard let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) else {
            // A vanished selection leaves its slot before the whole list, the frequent wing included.
            guard offset > 0 else { return .atTop }
            choose(rows[0].id)
            return .moved
        }
        let target = index + offset
        if target < 0 { return .atTop }
        if target >= rows.count { return .atBottom }
        choose(rows[target].id)
        return .moved
    }

    private mutating func choose(_ id: QuickAccessRow.ID) {
        selectedID = id
        userChose = true
        selectionLost = false
    }
}
