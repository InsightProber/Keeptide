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
    var savedAsMemo: Bool
    let isPartiallyIndexed: Bool
    let isTextUnavailable: Bool
    /// A memo's collections, in the sidebar's order as quick access last read it; empty for an unfiled memo and for
    /// every clip. The first gives the card its colour.
    var collectionIDs: [CollectionID] = []
    /// Whether a memo is a favorite; never true for a clip.
    var isFavorite = false
    /// How many times the clip was used, for a row of the frequent wing; nil for recent clips and search results.
    var frequentUses: Int64? = nil

    /// A row's place in the list: its clip, and whether it is the clip's frequent copy.
    struct ID: Hashable, Sendable {
        let ref: ContentRef
        let isFrequent: Bool
    }

    var id: ID { ID(ref: ref, isFrequent: isFrequent) }
    var isFrequent: Bool { frequentUses != nil }
    /// Whether the row is a clip or a memo.
    var facet: ContentFacet { ref.facet }
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
/// moving to a neighbour the user never saw; a frequent row it no longer lists hands the
/// selection to its clip's recent row instead, which holds the same content. Rows are told
/// apart by their `id`, so a clip listed in both wings is two rows; actions take the
/// selected row's clip.
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
                // One search reads one snapshot, so the row was re-ranked, not removed. It goes back where it was, but
                // within its own wing: a frequent row no further right than the wing reaches, a recent one no further
                // left.
                let wing = frequentCount
                let place = selectedID.isFrequent ? min(index, wing) : min(max(index, wing), self.rows.count)
                self.rows.insert(previousRows[index], at: place)
            } else if selectedID.isFrequent,
                      let recent = rows.first(where: { !$0.isFrequent && $0.ref == selectedID.ref }) {
                // The wing let the clip go, as when a refresh brings it to the first screen. Its recent row holds the
                // same content, read just now, so the selection stays with the clip there.
                self.selectedID = recent.id
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

    /// Changes the rows of one clip in place, in both wings, without moving the selection.
    mutating func updateRows(of ref: ContentRef, _ change: (inout QuickAccessRow) -> Void) {
        for index in rows.indices where rows[index].ref == ref { change(&rows[index]) }
    }

    mutating func select(_ id: QuickAccessRow.ID) {
        guard hasPage, rows.contains(where: { $0.id == id }) else { return }
        choose(id)
    }

    /// A clip's rows taken out of the list, in both wings, each with the place it had, so that they can be put back.
    struct RemovedRows: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let index: Int
            let row: QuickAccessRow
        }

        let generation: UInt64
        /// From left to right.
        let entries: [Entry]
        /// The one among them that was selected, if one was.
        let selectedID: QuickAccessRow.ID?
        /// Where the selection went as they were taken out: nil when it did not move, or when no row was left.
        let successorID: QuickAccessRow.ID?
    }

    /// Takes a clip's rows out of the list, in both wings, as when it moved to Recently Deleted; nil when the list does
    /// not hold it. A selected row hands the selection to the next row of another clip on its right, an older clip or
    /// the newest after the frequent wing, or else to the nearest on its left, so the selection stays beside where it
    /// was and can be acted on at once. With no other row left, nothing is selected; nothing was lost either, since the
    /// user took the row away.
    mutating func removeRows(of ref: ContentRef) -> RemovedRows? {
        let entries = rows.indices.filter { rows[$0].ref == ref }.map { RemovedRows.Entry(index: $0, row: rows[$0]) }
        guard !entries.isEmpty else { return nil }
        let selected = selectedID?.ref == ref ? selectedID : nil
        var successor: QuickAccessRow.ID?
        if let selected, let index = rows.firstIndex(where: { $0.id == selected }) {
            successor = rows[(index + 1)...].first { $0.ref != ref }?.id ?? rows[..<index].last { $0.ref != ref }?.id
        }
        rows.removeAll { $0.ref == ref }
        if selected != nil {
            if let successor { choose(successor) } else { selectedID = nil }
        }
        return RemovedRows(generation: generation, entries: entries, selectedID: selected, successorID: successor)
    }

    /// Puts rows `removeRows` took back where they were; rows a later page listed again are not listed twice. The one
    /// that was selected is selected again only while the selection is still `expected`, the row it was on when the
    /// rows were asked back, so it never moves under a person who moved on meanwhile: Return then acts on the clip they
    /// chose. False, with nothing changed, once another generation holds the list: its own pages list the clip if it
    /// belongs there.
    @discardableResult
    mutating func restore(_ removed: RemovedRows, reselectingWhileSelectionIs expected: QuickAccessRow.ID?) -> Bool {
        guard removed.generation == generation, hasPage else { return false }
        let selectionStayed = selectedID == expected
        for entry in removed.entries where !rows.contains(where: { $0.id == entry.row.id }) {
            rows.insert(entry.row, at: min(entry.index, rows.count))
        }
        if selectionStayed, let selected = removed.selectedID, rows.contains(where: { $0.id == selected }) {
            choose(selected)
        }
        return true
    }

    mutating func move(by offset: Int) -> SelectionMove {
        guard hasPage else { return .unchanged }
        guard !rows.isEmpty else { return offset < 0 ? .atTop : .unchanged }
        guard let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) else {
            // A vanished selection leaves its slot where the newest clip rests as the strip opens: just past the
            // divider, or before the first row without a frequent wing. → selects the newest clip after it, and ← the
            // most used frequent clip before it.
            let slot = frequentCount < rows.count ? frequentCount : 0
            guard offset != 0 else { return .unchanged }
            let target = offset > 0 ? slot : slot - 1
            guard target >= 0 else { return .atTop }
            choose(rows[target].id)
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
