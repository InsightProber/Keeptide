import Foundation
import Observation

enum LibraryScope: Hashable, Sendable {
    case recentClips
    case favorites
    case allSnippets
    case uncategorized
    case recentlyDeleted
    case collection(CollectionID)

    var collectionID: CollectionID? {
        if case .collection(let id) = self { return id }
        return nil
    }

    /// Where a new snippet made from this list goes, and the list that then shows it: a collection keeps its snippet,
    /// All Snippets and Unfiled keep theirs in no collection, and the lists that would not show a new snippet
    /// (Recent Clips, Favorites and Recently Deleted) give way to All Snippets.
    var newSnippetScope: LibraryScope {
        switch self {
        case .collection, .allSnippets, .uncategorized: self
        case .recentClips, .favorites, .recentlyDeleted: .allSnippets
        }
    }
}

/// An item Show in Library brought into view: the list it is in and the item, for the window to select both.
struct LibraryReveal: Equatable, Sendable {
    let scope: LibraryScope
    let ref: ContentRef
    let generation: Int

    var itemID: ItemID { ref.itemID }
}

/// What a search looks through: every clip and snippet (the default), or only the list on screen.
enum LibrarySearchScope: Hashable, Sendable {
    case allContent
    case thisView
}

/// The library's lists in sidebar order, and the moves between them.
enum LibrarySidebar {
    /// A list as the scope menus name it.
    struct ListEntry: Equatable {
        let scope: LibraryScope
        let title: String
        let symbolName: String
    }

    /// The help on the toolbar's scope menu. ⌘L also finds the menu's place in the toolbar by it.
    static let chooseListHelp = "Choose a List"

    /// The sidebar's sections as the scope menus list them: Recent Clips; All Snippets and Favorites; the
    /// collections and Unfiled, while there is a collection; Recently Deleted.
    static func sections(collections: [(id: CollectionID, name: String)]) -> [[ListEntry]] {
        var sections: [[ListEntry]] = [
            [ListEntry(scope: .recentClips, title: "Recent Clips", symbolName: "clock")],
            [ListEntry(scope: .allSnippets, title: "All Snippets", symbolName: "bookmark"),
             ListEntry(scope: .favorites, title: "Favorites", symbolName: "star")],
        ]
        if !collections.isEmpty {
            sections.append(
                collections.map { ListEntry(scope: .collection($0.id), title: $0.name, symbolName: "circle.fill") }
                    + [ListEntry(scope: .uncategorized, title: "Unfiled", symbolName: "tray")]
            )
        }
        sections.append([ListEntry(scope: .recentlyDeleted, title: "Recently Deleted", symbolName: "trash")])
        return sections
    }

    /// Recent Clips; All Snippets and Favorites; each collection, then Unfiled while there is a collection;
    /// Recently Deleted. Without a collection, Unfiled would only repeat All Snippets.
    static func scopes(collections: [CollectionID]) -> [LibraryScope] {
        var scopes: [LibraryScope] = [.recentClips, .allSnippets, .favorites]
        scopes += collections.map { .collection($0) }
        if !collections.isEmpty { scopes.append(.uncategorized) }
        scopes.append(.recentlyDeleted)
        return scopes
    }

    /// The list `offset` places along the sidebar from `current` (⌘] is 1, ⌘[ is -1), or nil past either end: the
    /// commands stop there rather than wrap around.
    static func scope(_ offset: Int, from current: LibraryScope, collections: [CollectionID]) -> LibraryScope? {
        let scopes = scopes(collections: collections)
        guard let index = scopes.firstIndex(of: current), scopes.indices.contains(index + offset) else { return nil }
        return scopes[index + offset]
    }

    /// The list to show instead of `current` once the collections are `collections`, or nil while it is still shown:
    /// a collection that is gone gives way to Unfiled, or to All Snippets when no collection is left, and Unfiled
    /// gives way to All Snippets when it hides with the last collection.
    static func scope(replacing current: LibraryScope, collections: [CollectionID]) -> LibraryScope? {
        switch current {
        case .collection(let id) where !collections.contains(id):
            return collections.isEmpty ? .allSnippets : .uncategorized
        case .uncategorized where collections.isEmpty:
            return .allSnippets
        default:
            return nil
        }
    }

    /// The window's subtitle for a list called `name`: past `limit` characters, the middle gives way to an ellipsis
    /// so the start and end of a long collection name both stay readable.
    /// A list's menu item identifier. The items of the list menu share one action, and AppKit otherwise names each
    /// after it, so assistive apps and UI tests could not tell them apart.
    static func menuIdentifier(for scope: LibraryScope) -> String {
        switch scope {
        case .recentClips: "ChooseList-RecentClips"
        case .allSnippets: "ChooseList-AllSnippets"
        case .favorites: "ChooseList-Favorites"
        case .uncategorized: "ChooseList-Unfiled"
        case .recentlyDeleted: "ChooseList-RecentlyDeleted"
        case .collection(let id): "ChooseList-Collection-\(id.rawValue.uuidString)"
        }
    }

    /// The window's subtitle for a list: a collection's name, which anyone may make long, shortened in the middle;
    /// Keeptide's own lists by their whole names.
    static func listSubtitle(for scope: LibraryScope, named name: String) -> String {
        scope.collectionID == nil ? name : subtitle(name)
    }

    static func subtitle(_ name: String, limit: Int = 15) -> String {
        guard name.count > limit else { return name }
        let head = (limit - 1) / 2
        return String(name.prefix(head)) + "…" + String(name.suffix(limit - 1 - head))
    }
}

struct LibraryEntry: Identifiable, Equatable, Sendable {
    let id: ItemID
    let ref: ContentRef
    let title: String
    let snippet: String?
    let lastCopiedAt: Date
    let kind: ContentKind
    var isMemo: Bool
    var isFavorite = false
    var sourceApp: String? = nil
    /// The memo's collection; nil for an unfiled memo and for every clip.
    var collectionID: CollectionID? = nil

    /// One row per item, each where the item first appears. An item whose clip and edited snippet both match
    /// stands as its snippet: the rows are selected and opened by item.
    static func oneRowPerItem(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        var rows: [LibraryEntry] = []
        var rowOfItem: [ItemID: Int] = [:]
        for entry in entries {
            if let row = rowOfItem[entry.id] {
                if entry.ref.facet == .memo, rows[row].ref.facet != .memo { rows[row] = entry }
            } else {
                rowOfItem[entry.id] = rows.count
                rows.append(entry)
            }
        }
        return rows
    }
}

struct RecoveredDraftSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let bodyPreview: String?
    let savedAt: Date
}

enum LibraryWorkspaceError: Error, Equatable {
    case notImplemented
    case unavailableSelection
    case saveFailed
    case searchUnavailable
    /// A clip's content is not complete, so it cannot become a memo yet.
    case contentUnavailable
    /// A clip's memo is in Recently Deleted; recovering it is the way back, not a second memo.
    case snippetInRecentlyDeleted
}

/// What a batch save did, in request order.
struct HistorySaveOutcome: Sendable {
    /// The memos this call created.
    var saved: [ContentRef] = []
    /// The memos of clips that already had one; nothing was written for them.
    var alreadySaved: [ContentRef] = []
    /// The clip that stopped the batch, and why; the clips after it were not attempted.
    var failure: HistorySaveFailure?
}

struct HistorySaveFailure: Sendable {
    let ref: ContentRef
    let error: any Error
}

@MainActor @Observable
final class LibraryWorkspace {
    private(set) var scope: LibraryScope = .recentClips
    private(set) var query = ""
    private(set) var searchScope: LibrarySearchScope = .allContent
    /// How many results the loaded pages hold, which can be more than the rows: the next page starts after them.
    @ObservationIgnored private var loadedResultCount = 0
    private(set) var entries: [LibraryEntry] = []
    private(set) var selectedEntryID: ItemID?
    /// The last item Show in Library found in its list; the window selects the list and the row.
    private(set) var revealed: LibraryReveal?
    /// The item the last open could not read, until another item or a new snippet opens. The editor keeps the item
    /// it had, so the detail says this one is unavailable instead.
    private(set) var unavailableItemID: ItemID?
    private(set) var editor: MemoEditorSession?
    private(set) var recoveredDrafts: [RecoveredDraftSummary] = []
    private(set) var isLoading = false
    private(set) var message: String?
    /// What the last action on the selection did ("Copied", "Saved to “Prompts”"), until the selection changes.
    private(set) var actionMessage: String?
    private(set) var canUndoNewSave = false
    private(set) var hasMoreEntries = false
    private(set) var searchIsPartial = false
    private(set) var isClosing = false
    private(set) var recoveryNotice: String?
    private(set) var collections: [CollectionSnapshot] = []
    private(set) var canUndoCollectionChange = false

    @ObservationIgnored private let controller: PersistenceController
    @ObservationIgnored private let repository: ContentRepository
    @ObservationIgnored private let libraryService: LibraryService
    @ObservationIgnored private let searchService: SearchService?
    @ObservationIgnored private let refreshSearch: @Sendable () async throws -> Void
    @ObservationIgnored private let pasteService: PasteService?
    @ObservationIgnored private var pasteSession: PasteSession?
    @ObservationIgnored private let storeIdentity: StoreIdentity
    @ObservationIgnored private let coordinator: MemoCommitCoordinator
    @ObservationIgnored private var recoveredByID: [UUID: RecoverableDraft]
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var navigationGeneration: UInt64 = 0
    @ObservationIgnored private var undoSave: UndoSave?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var refreshedRevisionByDraft: [UUID: UInt64] = [:]
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var collectionUndo: CollectionUndoToken?
    @ObservationIgnored private var isChangingCollection = false
    @ObservationIgnored private var collectionCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    /// Called after the collections changed, so the quick-access panel can read them again.
    @ObservationIgnored var onCollectionsChanged: (@MainActor () -> Void)?

    private struct UndoSave {
        let itemID: ItemID
        let memoID: UUID
        let fingerprint: Data
        let identity: StoreIdentity
        let historyRef: ContentRef
    }

    private init(
        controller: PersistenceController,
        searchService: SearchService?,
        refreshSearch: @escaping @Sendable () async throws -> Void,
        pasteService: PasteService?,
        storeIdentity: StoreIdentity,
        coordinator: MemoCommitCoordinator,
        recovered: [RecoverableDraft],
        recoveryFailedIDs: [UUID]
    ) {
        self.controller = controller
        repository = ContentRepository(controller: controller)
        libraryService = LibraryService(controller: controller)
        self.searchService = searchService
        self.refreshSearch = refreshSearch
        self.pasteService = pasteService
        // The library only copies. Its session has no target, so the app in front never changes what is copied:
        // a terminal's session would make text a command, without its trailing newline.
        pasteSession = pasteService?.beginSession(target: nil)
        self.storeIdentity = storeIdentity
        self.coordinator = coordinator
        recoveredByID = Dictionary(uniqueKeysWithValues: recovered.map { ($0.draftID, $0) })
        recoveredDrafts = recovered.map(Self.recoveredSummary).sorted { $0.savedAt > $1.savedAt }
        if !recoveryFailedIDs.isEmpty {
            recoveryNotice = "Some drafts could not be recovered. Their files were kept for repair."
        }
    }

    static func make(
        controller: PersistenceController,
        draftDirectory: URL,
        searchService: SearchService? = nil,
        pasteService: PasteService? = nil,
        refreshSearch: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> LibraryWorkspace {
        let identity = try await controller.identity()
        let store = try DraftStore(directory: draftDirectory, identity: identity)
        let service = LibraryService(controller: controller)
        let (events, continuation) = AsyncStream<MemoCommitCoordinator.Event>.makeStream()
        let coordinator = MemoCommitCoordinator(
            store: store,
            onEvent: { continuation.yield($0) },
            commit: { try await service.submitDraft($0) }
        )
        let recovery = try await coordinator.restoreBestEffort()
        let workspace = LibraryWorkspace(
            controller: controller,
            searchService: searchService,
            refreshSearch: refreshSearch,
            pasteService: pasteService,
            storeIdentity: identity,
            coordinator: coordinator,
            recovered: recovery.drafts,
            recoveryFailedIDs: recovery.failedIDs
        )
        workspace.eventTask = Task { [weak workspace] in
            for await event in events {
                guard let workspace else { return }
                workspace.handle(event)
            }
        }
        return workspace
    }

    func reload() async {
        await reload(refreshIndex: true)
    }

    func refreshCollections() async {
        guard !isClosing, !isClosed else { return }
        do {
            setCollections(try await collectionService.list(expecting: storeIdentity))
            if leaveListIfGone() { scheduleQueryLoad() }
        } catch {
            message = "Collections could not be loaded."
        }
    }

    func createCollection(_ draft: CollectionDraft) async -> Bool {
        await changeCollection {
            _ = try await self.collectionService.create(draft, expecting: self.storeIdentity)
            return nil
        }
    }

    func editCollection(_ snapshot: CollectionSnapshot, name: String, color: String) async -> Bool {
        await changeCollection {
            _ = try await self.collectionService.edit(snapshot, name: name, color: color, expecting: self.storeIdentity)
            return nil
        }
    }

    /// Deleting the collection shown, or the last collection while Unfiled is shown, leaves for the list
    /// `LibrarySidebar.scope(replacing:collections:)` names.
    func deleteCollection(_ snapshot: CollectionSnapshot) async -> Bool {
        await changeCollection {
            try await self.collectionService.delete(snapshot, expecting: self.storeIdentity)
        }
    }

    func reorderCollection(_ snapshot: CollectionSnapshot, offset: Int) async -> Bool {
        guard let index = collections.firstIndex(where: { $0.value.id == snapshot.value.id }),
              collections[index].fingerprint == snapshot.fingerprint,
              offset == -1 || offset == 1,
              collections.indices.contains(index + offset) else { return false }
        var ordered = collections
        ordered.swapAt(index, index + offset)
        return await changeCollection {
            _ = try await self.collectionService.reorder(ordered, expecting: self.storeIdentity)
            return nil
        }
    }

    func moveItems(_ refs: [ContentRef], to collection: CollectionSnapshot?) async -> Bool {
        await changeCollection {
            try await self.collectionService.move(refs, to: collection, expecting: self.storeIdentity)
        }
    }

    func setFavorite(_ refs: [ContentRef], isFavorite: Bool) async -> Bool {
        await changeCollection {
            try await self.collectionService.setFavorite(refs, isFavorite: isFavorite, expecting: self.storeIdentity)
        }
    }

    func undoCollectionChange() async -> Bool {
        guard let token = collectionUndo else { return false }
        return await changeCollection {
            _ = try await self.collectionService.undo(token)
            return nil
        }
    }

    private var collectionService: CollectionService { CollectionService(controller: controller) }

    private func setCollections(_ latest: [CollectionSnapshot]) {
        guard latest != collections else { return }
        collections = latest
        onCollectionsChanged?()
    }

    /// Moves off a list the sidebar no longer shows; true when it did. The caller loads the new list's entries.
    @discardableResult
    private func leaveListIfGone() -> Bool {
        guard let next = LibrarySidebar.scope(replacing: scope, collections: collections.map(\.value.id)) else {
            return false
        }
        navigationGeneration &+= 1
        scope = next
        return true
    }

    private func changeCollection(_ operation: () async throws -> CollectionChange?) async -> Bool {
        guard !isClosing, !isClosed, !isChangingCollection else { return false }
        isChangingCollection = true
        defer {
            isChangingCollection = false
            collectionCompletionWaiters.forEach { $0.resume() }
            collectionCompletionWaiters.removeAll()
        }
        var committed = false
        do {
            let change = try await operation()
            committed = true
            collectionUndo = change?.undoToken
            canUndoCollectionChange = !(collectionUndo?.records.isEmpty ?? true)
            // The item changed since a new save, so the save can no longer be undone as it was.
            undoSave = nil
            canUndoNewSave = false
            guard !isClosing, !isClosed else { return true }
            setCollections(try await collectionService.list(expecting: storeIdentity))
            leaveListIfGone()
            try await refreshSearch()
            if !isClosing, !isClosed { await reload(refreshIndex: false) }
            await refreshEditorDetails()
            return true
        } catch {
            message = committed
                ? "Saved. Library results are still updating."
                : "This change could not be applied. The items or collection may have changed."
            return committed
        }
    }

    private func reload(refreshIndex: Bool) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        hasMoreEntries = false
        searchIsPartial = false
        message = nil
        if scope == .recentlyDeleted {
            entries = []
            selectedEntryID = nil
            isLoading = false
            return
        }
        do {
            if refreshIndex {
                try await refreshSearch()
                setCollections(try await collectionService.list(expecting: storeIdentity))
            }
            guard generation == loadGeneration else { return }
            let loaded = try await loadEntries(generation: generation, offset: 0)
            guard generation == loadGeneration else { return }
            entries = LibraryEntry.oneRowPerItem(loaded.entries)
            loadedResultCount = loaded.entries.count
            hasMoreEntries = loaded.hasMore
            searchIsPartial = loaded.isPartial
            if let selectedEntryID, !loaded.entries.contains(where: { $0.id == selectedEntryID }) {
                self.selectedEntryID = nil
            }
        } catch is CancellationError {
        } catch {
            guard generation == loadGeneration else { return }
            message = "The library could not be loaded."
        }
        if generation == loadGeneration { isLoading = false }
    }

    func loadMore() async {
        guard hasMoreEntries, !isLoading else { return }
        let generation = loadGeneration
        isLoading = true
        do {
            let loaded = try await loadEntries(generation: generation, offset: loadedResultCount)
            guard generation == loadGeneration else { return }
            let known = Set(entries.map(\.ref))
            entries = LibraryEntry.oneRowPerItem(entries + loaded.entries.filter { !known.contains($0.ref) })
            loadedResultCount += loaded.entries.count
            hasMoreEntries = loaded.hasMore
            searchIsPartial = loaded.isPartial
        } catch is CancellationError {
        } catch {
            guard generation == loadGeneration else { return }
            message = "More library items could not be loaded."
        }
        if generation == loadGeneration { isLoading = false }
    }

    /// Scope is published before any asynchronous work, just like native search input.
    /// Changing it also invalidates pending navigation from the previous scope.
    func updateScope(_ value: LibraryScope) {
        guard !isClosing, !isClosed, scope != value else { return }
        navigationGeneration &+= 1
        scope = value
        actionMessage = nil
        if value == .recentlyDeleted {
            // The query stays: nothing rewrites the search field while nobody types in it, so an input method's
            // composition there survives, and Recently Deleted is searched by the same field.
            queryTask?.cancel()
            queryTask = nil
            loadGeneration &+= 1
            entries = []
            selectedEntryID = nil
            hasMoreEntries = false
            searchIsPartial = false
            isLoading = false
            message = nil
            return
        }
        scheduleQueryLoad(refreshIndex: true)
    }

    func setScope(_ value: LibraryScope) async {
        updateScope(value)
        await queryTask?.value
    }

    func setQuery(_ value: String) async {
        updateQuery(value)
        await queryTask?.value
    }

    /// All Content or This View. Only a search reads it, so nothing reloads without a query.
    func updateSearchScope(_ value: LibrarySearchScope) {
        guard !isClosing, !isClosed, searchScope != value else { return }
        searchScope = value
        if !query.isEmpty { scheduleQueryLoad() }
    }

    func setSearchScope(_ value: LibrarySearchScope) async {
        updateSearchScope(value)
        await queryTask?.value
    }

    /// Publish native input synchronously, before SwiftUI can render the old value.
    /// Only result loading is asynchronous; every edit invalidates older loads.
    func updateQuery(_ value: String) {
        guard !isClosing, !isClosed else { return }
        guard query != value else { return }
        query = value
        // In Recently Deleted the view filters the deleted items by title; the reload only clears the rows.
        scheduleQueryLoad()
    }

    private func scheduleQueryLoad(refreshIndex: Bool = false) {
        queryTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        queryTask = Task { [weak self] in
            guard !Task.isCancelled, let self,
                  self.loadGeneration == generation else { return }
            await self.reload(refreshIndex: refreshIndex)
        }
    }

    func select(_ itemID: ItemID) async {
        navigationGeneration &+= 1
        guard let entry = entries.first(where: { $0.id == itemID }) else {
            selectedEntryID = nil
            return
        }
        await open(entry.ref)
        if editor?.ref == entry.ref { selectedEntryID = itemID }
    }

    func open(_ ref: ContentRef) async {
        guard !isClosing, !isClosed else { return }
        if editor?.ref == ref { return }
        actionMessage = nil
        navigationGeneration &+= 1
        let navigation = navigationGeneration
        do {
            _ = try await flush()
        } catch {
            message = "Your current changes could not be saved."
            return
        }
        do {
            let session = try await makeSession(ref)
            guard navigation == navigationGeneration else { return }
            install(session)
            selectedEntryID = ref.itemID
            unavailableItemID = nil
            message = nil
        } catch {
            guard navigation == navigationGeneration else { return }
            selectedEntryID = nil
            unavailableItemID = ref.itemID
            message = "This item is no longer available."
        }
    }

    /// A new snippet, in the list `requestedScope` (or the list shown) puts it: see `LibraryScope.newSnippetScope`. The
    /// list that shows it is shown.
    /// Show in Library from quick access. The list the item is in comes first, then the item is selected there: a
    /// snippet's list is its collection, or All Snippets; a clip's is Recent Clips; a clip saved as a snippet shows as
    /// the snippet when the request asks. A row not on the pages loaded brings up to five more; past them the item still
    /// opens, and the status line says the list does not show it yet. Going anywhere else meanwhile stops it.
    func open(_ request: LibraryOpenRequest) async {
        guard !isClosing, !isClosed else { return }
        var ref = request.ref
        if request.showsSnippet, ref.facet != .memo,
           let memo = try? await repository.currentRef(itemID: ref.itemID, facet: .memo) {
            ref = memo
        }
        var target = LibraryScope.recentClips
        if ref.facet == .memo {
            target = .allSnippets
            if case .item(let item)? = try? await repository.recordState(.item(ref.itemID)).value,
               let id = item.collectionID {
                // The sidebar lists the collection before it is chosen: one not known yet is read first.
                if !collections.contains(where: { $0.value.id == id }) { await refreshCollections() }
                if collections.contains(where: { $0.value.id == id }) { target = .collection(id) }
            }
        }
        guard !isClosing, !isClosed else { return }
        // The list is read again, without a search: what quick access just saved is in it, and nothing hides the item.
        query = ""
        if scope == target {
            navigationGeneration &+= 1
            scheduleQueryLoad(refreshIndex: true)
        } else {
            updateScope(target)
        }
        let navigation = navigationGeneration
        await queryTask?.value
        // Choosing another list or row, or typing a search, stops the paging. A page the list asked for itself, as it
        // scrolled, is waited for rather than counted.
        var pages = 0
        var waits = 0
        while navigation == navigationGeneration, query.isEmpty, !entries.contains(where: { $0.id == ref.itemID }),
              hasMoreEntries, pages < 5 {
            if isLoading {
                guard waits < 250 else { break }
                waits += 1
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            await loadMore()
            pages += 1
        }
        guard navigation == navigationGeneration, query.isEmpty else { return }
        let listed = entries.contains { $0.id == ref.itemID }
        await open(ref)
        guard editor?.ref == ref else { return }
        if listed {
            revealed = LibraryReveal(scope: target, ref: ref, generation: request.generation)
        } else {
            message = "Opened. The list doesn't show it yet."
        }
    }

    func startNew(in requestedScope: LibraryScope? = nil) async {
        guard !isClosing, !isClosed else { return }
        var target = (requestedScope ?? scope).newSnippetScope
        // A collection asked for from quick access may have gone meanwhile: the snippet then goes to Unfiled.
        var collectionIsGone = false
        if case .collection(let id) = target, !collections.contains(where: { $0.value.id == id }) {
            await refreshCollections()
            if !collections.contains(where: { $0.value.id == id }) {
                target = .allSnippets
                collectionIsGone = true
            }
        }
        guard !isClosing, !isClosed else { return }
        updateScope(target)
        navigationGeneration &+= 1
        let navigation = navigationGeneration
        do {
            _ = try await flush()
        } catch {
            message = "Your current changes could not be saved."
            return
        }
        guard navigation == navigationGeneration else { return }
        let session = MemoEditorSession(
            itemID: ItemID(), ref: nil, isReadOnly: false, title: "", body: "", note: "",
            kind: .plainText, storeIdentity: storeIdentity, collectionID: scope.collectionID
        )
        install(session)
        selectedEntryID = nil
        unavailableItemID = nil
        message = collectionIsGone ? "This collection no longer exists." : nil
    }

    /// Saves the selected clip as a memo, straight into `collectionID` and as a favorite when asked, in one
    /// transaction; a clip that already has a memo is returned as it is. The editor then holds the memo, and a new
    /// save can be undone.
    func saveSelectedHistory(
        collectionID: CollectionID? = nil, isFavorite: Bool = false
    ) async throws -> SaveMemoOutcome {
        guard let current = editor, let ref = current.ref else {
            throw LibraryWorkspaceError.unavailableSelection
        }
        if ref.facet == .memo { return .existing(ref) }
        let navigation = navigationGeneration
        let draftID = current.draftID
        let outcome: SaveMemoOutcome
        let snapshot: MemoEditingSnapshot
        do {
            outcome = try await libraryService.saveAsMemo(
                ref.itemID, collectionID: collectionID, isFavorite: isFavorite, expecting: storeIdentity
            )
            snapshot = try await libraryService.editingSnapshot(outcome.ref)
        } catch {
            message = "This clip could not be saved as a snippet."
            throw error
        }
        guard navigation == navigationGeneration, editor?.draftID == draftID, editor?.ref == ref else {
            if case .created = outcome { await markSavedRows([ref.itemID]) }
            return outcome
        }
        if case .created = outcome {
            undoSave = UndoSave(
                itemID: ref.itemID, memoID: snapshot.memoID,
                fingerprint: snapshot.memoFingerprint, identity: storeIdentity, historyRef: ref
            )
            canUndoNewSave = true
        }
        install(makeSession(snapshot), preservingUndo: true)
        selectedEntryID = ref.itemID
        if case .created = outcome { await markSavedRows([ref.itemID]) }
        return outcome
    }

    /// Saves several clips as memos, one transaction each, in the order given. Every clip is checked first
    /// (`checkHistory`): one whose content is not complete, or whose memo is in Recently Deleted, stops the batch
    /// before anything is written. A failure while saving stops it too; the memos saved before it stay, and the clips
    /// after it are left alone. Clips that already have a memo are reported, not failed. No editing session is
    /// installed, and the single-clip undo is untouched.
    func saveHistory(
        _ refs: [ContentRef], collectionID: CollectionID? = nil, isFavorite: Bool = false
    ) async -> HistorySaveOutcome {
        guard !isClosing, !isClosed else { return HistorySaveOutcome() }
        if let failure = await checkHistory(refs) { return HistorySaveOutcome(failure: failure) }
        return await saveCheckedHistory(refs, collectionID: collectionID, isFavorite: isFavorite)
    }

    /// The check `saveHistory` runs before writing anything: the first clip that cannot be saved, or nil. The
    /// toolbar's save item is enabled on the same answer.
    func checkHistory(_ refs: [ContentRef]) async -> HistorySaveFailure? {
        for ref in refs where ref.facet == .history {
            do {
                guard try await repository.read(ref).integrity == .complete else {
                    throw LibraryWorkspaceError.contentUnavailable
                }
                try await requireNoDeletedMemo(ref.itemID)
            } catch {
                return HistorySaveFailure(ref: ref, error: error)
            }
        }
        return nil
    }

    /// A clip keeps its memo facet while the memo sits in Recently Deleted, so it cannot be saved again until the
    /// memo is recovered or purged. The check names that state instead of letting the save fail on it.
    private func requireNoDeletedMemo(_ itemID: ItemID) async throws {
        guard case .item(let item) = try await repository.recordState(.item(itemID)).value,
              let memoID = item.memoID else { return }
        guard case .memo(let memo) = try await repository.recordState(.memo(memoID)).value,
              memo.deletedAt == nil else {
            throw LibraryWorkspaceError.snippetInRecentlyDeleted
        }
    }

    /// The saving half of `saveHistory`, for clips `checkHistory` passed: one transaction per clip, in order,
    /// stopping at the first failure. A clip that changed since the check is reported as that failure.
    func saveCheckedHistory(
        _ refs: [ContentRef], collectionID: CollectionID? = nil, isFavorite: Bool = false
    ) async -> HistorySaveOutcome {
        var outcome = HistorySaveOutcome()
        for ref in refs {
            if ref.facet == .memo {
                outcome.alreadySaved.append(ref)
                continue
            }
            do {
                switch try await libraryService.saveAsMemo(
                    ref.itemID, collectionID: collectionID, isFavorite: isFavorite, expecting: storeIdentity
                ) {
                case .created(let memo): outcome.saved.append(memo)
                case .existing(let memo): outcome.alreadySaved.append(memo)
                }
            } catch {
                outcome.failure = HistorySaveFailure(ref: ref, error: error)
                break
            }
        }
        if !outcome.saved.isEmpty { await markSavedRows(Set(outcome.saved.map(\.itemID))) }
        return outcome
    }

    /// A row's bookmark comes from the index, which the consumer brings up to date on its own later. The rows of the
    /// clips just saved are marked at once, keeping the loaded pages and the selection, and the index is refreshed
    /// so a later reload agrees.
    private func markSavedRows(_ itemIDs: Set<ItemID>) async {
        guard !isClosing, !isClosed else { return }
        entries = entries.map { entry in
            guard itemIDs.contains(entry.id), !entry.isMemo else { return entry }
            var marked = entry
            marked.isMemo = true
            return marked
        }
        do {
            try await refreshSearch()
        } catch {
            message = "Saved. Library results are still updating."
        }
    }

    func undoNewSave() async throws -> Bool {
        guard let undoSave else { return false }
        let navigation = navigationGeneration
        let draftID = editor?.draftID
        do {
            _ = try await flush()
            guard navigation == navigationGeneration, editor?.draftID == draftID else { return false }
            try await libraryService.undoSaveAsMemo(
                undoSave.itemID, memoID: undoSave.memoID,
                expectedFingerprint: undoSave.fingerprint, expecting: undoSave.identity
            )
        } catch {
            message = "The new snippet changed and could not be undone safely."
            throw error
        }
        self.undoSave = nil
        canUndoNewSave = false
        if navigation == navigationGeneration, editor?.draftID == draftID {
            let historySession = try await makeSession(undoSave.historyRef)
            if navigation == navigationGeneration, editor?.draftID == draftID {
                install(historySession)
                selectedEntryID = undoSave.itemID
            }
        }
        await reload()
        return true
    }

    func flush() async throws -> ContentRef? {
        guard let editor else { return nil }
        guard !editor.isReadOnly else { return editor.ref }
        if editor.status == .clean { return editor.ref }
        let submittedRevision = editor.revision
        if isBlankNew(editor) {
            if editor.revision > 0 {
                await coordinator.update(recoverableDraft(from: editor))
                guard try await coordinator.discardEmptyDraft(editor.draftID) else {
                    editor.markFailed("The empty draft could not be discarded.", revision: editor.revision)
                    throw LibraryWorkspaceError.saveFailed
                }
            }
            return nil
        }
        do {
            await coordinator.update(recoverableDraft(from: editor))
            let receipt = try await coordinator.commitNow(editor.draftID)
            guard let receipt else { return nil }
            editor.markSaved(receipt, revision: submittedRevision)
            if editor.revision == submittedRevision { removeRecovered(editor.draftID) }
            await refreshAfterCommit(draftID: editor.draftID, revision: submittedRevision)
            return receipt.ref
        } catch {
            editor.markFailed("The draft could not be saved.", revision: submittedRevision)
            message = "The draft could not be saved."
            throw error
        }
    }

    func focusLost() async throws -> ContentRef? {
        guard let editor, !editor.isReadOnly else { return editor?.ref }
        if editor.status == .clean { return editor.ref }
        if isBlankNew(editor) { return try await flush() }
        let submittedRevision = editor.revision
        do {
            await coordinator.update(recoverableDraft(from: editor))
            let receipt = try await coordinator.focusLost(editor.draftID)
            if let receipt {
                editor.markSaved(receipt, revision: submittedRevision)
                if editor.revision == submittedRevision { removeRecovered(editor.draftID) }
                await refreshAfterCommit(draftID: editor.draftID, revision: submittedRevision)
            }
            return receipt?.ref
        } catch {
            editor.markFailed("The draft could not be saved.", revision: submittedRevision)
            message = "The draft could not be saved."
            throw error
        }
    }

    func copyCurrent(mode: PasteMode = .original) async -> PasteOutcome? {
        guard !isClosing, !isClosed else { return .refused(.stale) }
        guard let pasteService, let pasteSession else { return nil }
        guard editor?.isComposing != true else { return .refused(.stale) }
        let ref: ContentRef
        do {
            guard let current = try await flush() ?? editor?.ref else { return nil }
            ref = current
        } catch {
            return nil
        }
        let generation = pasteSession.advanceQueryGeneration()
        let outcome = await pasteService.execute(PasteRequest(
            ref: ref, queryGeneration: generation, mode: mode, session: pasteSession
        ))
        report(outcome)
        return outcome
    }

    /// Copies a row's item; the open item is saved first, so the copy is what the editor shows.
    func copy(_ ref: ContentRef, mode: PasteMode = .original) async -> PasteOutcome? {
        if ref.itemID == editor?.ref?.itemID { return await copyCurrent(mode: mode) }
        guard !isClosing, !isClosed, let pasteService, let pasteSession else { return nil }
        let generation = pasteSession.advanceQueryGeneration()
        let outcome = await pasteService.execute(PasteRequest(
            ref: ref, queryGeneration: generation, mode: mode, session: pasteSession
        ))
        report(outcome)
        return outcome
    }

    private func report(_ outcome: PasteOutcome) {
        switch outcome {
        case .copied, .copiedInstead: actionMessage = "Copied"
        case .refused(.stale): break // A newer copy or selection owns the message.
        case .refused: actionMessage = "This clip could not be copied. Its original formats must all be available."
        case .dispatched, .needsConfirmation: break // A copy without a target never pastes or asks.
        }
    }

    // MARK: Saving, favorites and collections for the selection

    /// Saves the selected clips as snippets. The open clip is saved through its editor, which keeps the save
    /// undoable; several are saved one by one, and the first that fails stops the rest.
    func saveAsSnippets(_ refs: [ContentRef]) async {
        let clips = refs.filter { $0.facet == .history }
        guard !clips.isEmpty else { return }
        if clips.count == 1, editor?.ref == clips[0] {
            guard let outcome = try? await saveSelectedHistory() else { return }
            if case .created = outcome { actionMessage = "Saved to Snippets" } else { actionMessage = "Already in Snippets" }
            return
        }
        let outcome = await saveHistory(clips)
        if outcome.failure != nil {
            actionMessage = "Saved \(outcome.saved.count) of \(clips.count) · Some clips could not be saved."
        } else if outcome.saved.isEmpty {
            actionMessage = "Already in Snippets"
        } else {
            actionMessage = "Saved to Snippets"
        }
    }

    /// Marks the selection a favorite or not. A clip that is not a snippet yet is saved as one, a favorite; a clip
    /// that already is one marks its snippet. Snippets change in one transaction.
    func setFavorite(of refs: [ContentRef], to isFavorite: Bool) async {
        let clips = refs.filter { $0.facet == .history }
        var snippets = refs.filter { $0.facet == .memo }
        var saved = 0
        if !clips.isEmpty {
            guard let resolved = await snippetRefs(for: clips, saving: isFavorite, collectionID: nil) else { return }
            saved = resolved.saved
            snippets += resolved.existing
        }
        if !snippets.isEmpty {
            guard await setFavorite(snippets, isFavorite: isFavorite) else { return }
        }
        let change = isFavorite ? "Added to Favorites" : "Removed from Favorites"
        actionMessage = saved > 0 ? "Saved as Snippet · \(change)" : clips.isEmpty ? change : "Already in Snippets · \(change)"
        await refreshEditorDetails()
    }

    /// Puts the selection in `collection`, or in no collection. A clip that is not a snippet yet is saved into it.
    func file(_ refs: [ContentRef], into collection: CollectionSnapshot?) async {
        let place = collection.map { "“\($0.value.name)”" } ?? "Unfiled"
        let clips = refs.filter { $0.facet == .history }
        var snippets = refs.filter { $0.facet == .memo }
        var saved = 0
        if !clips.isEmpty {
            guard let resolved = await snippetRefs(for: clips, saving: true, collectionID: collection?.value.id)
            else { return }
            saved = resolved.saved
            snippets += resolved.existing
        }
        if !snippets.isEmpty {
            guard await moveItems(snippets, to: collection) else { return }
        }
        actionMessage = saved > 0 && snippets.isEmpty ? "Saved to \(place)" : "Moved to \(place)"
        await refreshEditorDetails()
    }

    /// ⌫ in a collection: the selected snippets leave it and become unfiled; nothing is deleted.
    func removeFromCollection(_ refs: [ContentRef]) async {
        guard let id = scope.collectionID, let collection = collections.first(where: { $0.value.id == id }) else {
            return
        }
        let snippets = refs.filter { $0.facet == .memo }
        guard !snippets.isEmpty, await moveItems(snippets, to: nil) else { return }
        actionMessage = "Removed from “\(collection.value.name)”"
        await refreshEditorDetails()
    }

    /// The snippets of `clips`: saved now when `saving`, into `collectionID` and as a favorite as asked, and the
    /// snippets of those already saved. The open clip is saved through its editor, which keeps the save undoable.
    private func snippetRefs(
        for clips: [ContentRef], saving: Bool, collectionID: CollectionID?
    ) async -> (saved: Int, existing: [ContentRef])? {
        let favorite = saving && collectionID == nil
        if clips.count == 1, let clip = clips.first, editor?.ref == clip {
            if let snippet = editor?.details?.savedSnippet { return (0, [snippet.ref]) }
            guard saving, let outcome = try? await saveSelectedHistory(collectionID: collectionID, isFavorite: favorite)
            else { return nil }
            if case .created = outcome { return (1, []) }
            return (0, [outcome.ref])
        }
        if !saving {
            let current = (try? await repository.summaries(for: clips.map(\.itemID))) ?? []
            return (0, current.compactMap(\.memo))
        }
        let outcome = await saveHistory(clips, collectionID: collectionID, isFavorite: favorite)
        if outcome.failure != nil, outcome.saved.isEmpty {
            message = "These clips could not be saved as snippets."
            return nil
        }
        return (outcome.saved.count, outcome.alreadySaved)
    }

    /// Safely ends any editor for the exact facet before the root maintenance facade performs a soft delete.
    /// The injected operation is the only code here that mutates lifecycle state, which keeps tests isolated and
    /// prevents this workspace from acquiring maintenance permits or duplicating backend rules.
    func moveToRecentlyDeleted(
        _ requestedRef: ContentRef,
        using remove: (ContentRef) async -> Bool
    ) async -> Bool {
        guard !isClosing, !isClosed else { return false }
        var target = requestedRef
        var editorDraftID: UUID?

        if requestedRef.facet == .memo,
           let current = editor,
           current.ref?.facet == .memo,
           current.itemID == requestedRef.itemID {
            guard !current.isComposing else {
                message = "Finish text composition before moving this snippet to Recently Deleted."
                return false
            }
            let draftID = current.draftID
            do {
                let flushed = try await flush()
                guard editor?.draftID == draftID,
                      let currentRef = flushed ?? editor?.ref,
                      currentRef.facet == .memo,
                      currentRef.itemID == requestedRef.itemID else {
                    message = "The edit was saved as a separate snippet. Review it before deleting anything."
                    return false
                }
                target = currentRef
                editorDraftID = draftID
            } catch {
                message = "The snippet could not be saved, so it was not moved to Recently Deleted."
                return false
            }
        }

        guard await remove(target) else {
            message = "This item could not be moved to Recently Deleted."
            return false
        }

        let matchingEditor = editor.flatMap { current -> MemoEditorSession? in
            guard current.itemID == target.itemID, current.ref?.facet == target.facet else { return nil }
            return current
        }
        if let matchingEditor {
            editorDraftID = editorDraftID ?? matchingEditor.draftID
            matchingEditor.attachChangeHandler({})
            editor = nil
        }
        if let editorDraftID { _ = await coordinator.endSession(editorDraftID) }

        navigationGeneration &+= 1
        selectedEntryID = nil
        undoSave = nil
        canUndoNewSave = false
        message = nil
        await reload()
        return true
    }

    func recoverDraft(_ draftID: UUID) async {
        guard let draft = recoveredByID[draftID] else { return }
        navigationGeneration &+= 1
        let navigation = navigationGeneration
        do {
            _ = try await flush()
        } catch {
            message = "Your current changes could not be saved."
            return
        }
        guard navigation == navigationGeneration else { return }
        guard draft.revision < UInt64.max else {
            message = "This recovered draft cannot be edited safely."
            return
        }
        let session = MemoEditorSession(
            draftID: draft.draftID, sessionID: draft.sessionID, itemID: draft.itemID,
            ref: draft.base, isReadOnly: false, title: draft.title, body: draft.body,
            note: draft.note, kind: draft.kind, status: .saving,
            isComposing: false, revision: draft.revision + 1,
            conflictItemID: draft.conflictItemID, storeIdentity: draft.storeIdentity,
            baseMemoFingerprint: draft.baseMemoFingerprint, languageHint: draft.languageHint,
            collectionID: draft.collectionID
        )
        install(session)
        editorDidChange(session)
        selectedEntryID = draft.itemID
    }

    func prepareToClose() async -> Bool {
        if isClosed { return true }
        guard !isClosing else { return false }
        isClosing = true
        navigationGeneration &+= 1
        queryTask?.cancel()
        loadGeneration &+= 1
        isLoading = false
        pasteSession?.end()
        if isChangingCollection {
            await withCheckedContinuation { collectionCompletionWaiters.append($0) }
        }
        do {
            while let editor, !editor.isReadOnly {
                let draftID = editor.draftID
                let revision = editor.revision
                if editor.isComposing {
                    await coordinator.update(recoverableDraft(from: editor))
                    try await coordinator.cancel(editor.draftID)
                } else {
                    _ = try await flush()
                }
                guard self.editor?.draftID == draftID else { continue }
                if self.editor?.revision == revision { break }
            }
            isClosed = true
            return true
        } catch {
            editor?.markFailed("The draft could not be saved before closing.", revision: editor?.revision ?? 0)
            message = "The draft could not be saved before closing."
            isClosing = false
            pasteSession = pasteService?.beginSession(target: nil)
            scheduleQueryLoad()
            return false
        }
    }

    func endEditingSession() async -> Bool { await prepareToClose() }

    func resumeAfterCloseCancellation() {
        guard isClosing || isClosed else { return }
        isClosing = false
        isClosed = false
        pasteSession = pasteService?.beginSession(target: nil)
        scheduleQueryLoad()
    }

    private func install(_ session: MemoEditorSession, preservingUndo: Bool = false) {
        if !preservingUndo {
            undoSave = nil
            canUndoNewSave = false
        }
        session.attachChangeHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.editorDidChange(session)
        }
        editor = session
    }

    private func editorDidChange(_ session: MemoEditorSession) {
        let draft = recoverableDraft(from: session)
        Task { await coordinator.update(draft) }
    }

    private func recoverableDraft(from session: MemoEditorSession) -> RecoverableDraft {
        RecoverableDraft(
            draftID: session.draftID, sessionID: session.sessionID, itemID: session.itemID,
            conflictItemID: session.conflictItemID, storeIdentity: session.storeIdentity,
            base: session.ref, baseMemoFingerprint: session.baseMemoFingerprint,
            title: session.title, body: session.body, kind: session.kind,
            languageHint: session.languageHint, note: session.note,
            isComposing: session.isComposing, revision: session.revision, savedAt: Date(),
            collectionID: session.collectionID
        )
    }

    private func makeSession(_ ref: ContentRef) async throws -> MemoEditorSession {
        if ref.facet == .memo {
            let session = makeSession(try await libraryService.editingSnapshot(ref))
            session.updateDetails(try await details(of: ref, content: nil))
            return session
        }
        // A clip whose formats cannot all be read still opens, read-only and without a body, so its details can say
        // why it cannot be copied or saved.
        let content = try await repository.read(ref)
        let state = try await repository.recordState(.item(ref.itemID))
        guard case .item(let item) = state.value else { throw StoreError.staleReference }
        let extracted = content.integrity == .complete ? try MemoTextExtractor.editableText(from: content) : nil
        let kind: MemoKind = extracted.map {
            ContentKind.isMarkdown($0.sourceRepresentationType) ? .markdown : .plainText
        } ?? .plainText
        let session = MemoEditorSession(
            itemID: ref.itemID, ref: ref, isReadOnly: true, title: item.title,
            body: extracted?.text, note: "", kind: kind,
            richSourceWarning: extracted.map { $0.sourceRepresentationType != "public.utf8-plain-text" } ?? false,
            storeIdentity: storeIdentity
        )
        session.updateDetails(try await details(of: ref, content: content))
        return session
    }

    /// The details of the item `ref` opens: the clip's formats and its snippet, or the snippet's collection, favorite
    /// mark and original clip.
    private func details(of ref: ContentRef, content: ResolvedContent?) async throws -> LibraryItemDetails {
        let state = try await repository.recordState(.item(ref.itemID))
        guard case .item(let item) = state.value else { throw StoreError.staleReference }
        let current = try await repository.summaries(for: [ref.itemID]).first
        var details = LibraryItemDetails(
            sourceApp: item.sourceApp, createdAt: item.createdAt, lastCopiedAt: item.lastCopiedAt,
            copyCount: item.copyCount
        )
        if ref.facet == .history {
            if let content {
                details.integrity = content.integrity
                details.formatCount = content.representations.count
                details.byteCount = content.representations.reduce(0) { $0 + $1.byteCount }
            }
            if let memo = current?.memo {
                details.savedSnippet = .init(ref: memo, collectionID: item.collectionID, isFavorite: item.isFavorite)
            }
        } else {
            details.collectionID = item.collectionID
            details.isFavorite = item.isFavorite
            if item.captureID != nil {
                if let history = current?.history {
                    details.originalClip = .available(history)
                } else if item.historyDeletedAt != nil, let purgeAfter = item.historyPurgeAfter, purgeAfter > Date() {
                    details.originalClip = .recentlyDeleted(until: purgeAfter)
                } else {
                    details.originalClip = .gone
                }
            }
        }
        return details
    }

    /// Reads the open item's details again, after its favorite mark or collection changed.
    private func refreshEditorDetails() async {
        guard let editor, let ref = editor.ref else { return }
        let content = ref.facet == .history ? try? await repository.read(ref) : nil
        guard let details = try? await details(of: ref, content: content), self.editor === editor else { return }
        editor.updateDetails(details)
    }

    private func makeSession(_ snapshot: MemoEditingSnapshot) -> MemoEditorSession {
        MemoEditorSession(
            itemID: snapshot.itemID, ref: snapshot.ref, isReadOnly: false,
            title: snapshot.title, body: snapshot.body, note: snapshot.note, kind: snapshot.kind,
            storeIdentity: storeIdentity, baseMemoFingerprint: snapshot.memoFingerprint,
            languageHint: snapshot.languageHint
        )
    }

    private func loadEntries(
        generation: UInt64, offset: Int
    ) async throws -> (entries: [LibraryEntry], hasMore: Bool, isPartial: Bool) {
        if scope == .recentlyDeleted { return ([], false, false) }
        if let searchService {
            // All Content looks through every clip and snippet, whatever list is shown; This View, and the list
            // itself without a query, keep to the list.
            let searchesEverything = !query.isEmpty && self.searchScope == .allContent
            let searchScope: SearchScope = searchesEverything ? .all : scope == .recentClips ? .history : .memo
            let collection: CollectionFilter?
            switch scope {
            case .uncategorized where !searchesEverything: collection = .uncategorized
            case .collection(let id) where !searchesEverything: collection = .collection(id)
            default: collection = nil
            }
            var latest: [SearchResult] = []
            var totalMatches = 0
            var isPartial = false
            for try await page in searchService.search(SearchRequest(
                query: query, scope: searchScope, collection: collection,
                favoritesOnly: !searchesEverything && scope == .favorites,
                // An owned memo's copy time is its creation time and never moves, so memos are listed by use.
                order: searchScope == .memo ? .lastUsed : .lastCopied,
                generation: generation, offset: offset, limit: 100
            )) where page.generation == generation {
                latest = page.results
                totalMatches = page.totalMatches
                isPartial = !page.isComplete
            }
            if scope == .recentClips, query.isEmpty, latest.isEmpty {
                let recent = try await repository.recent(limit: 1_000)
                let fallback = recent.compactMap(Self.historyEntry)
                let page = Array(fallback.dropFirst(offset).prefix(100))
                return (page, offset + page.count < fallback.count, recent.count == 1_000)
            }
            return (latest.map(Self.entry), offset + latest.count < totalMatches, isPartial)
        }
        guard query.isEmpty, scope == .recentClips || scope == .allSnippets else {
            throw LibraryWorkspaceError.searchUnavailable
        }
        let recent = try await repository.recent(limit: 200)
        let all = recent.compactMap { summary -> LibraryEntry? in
            let ref = scope == .recentClips ? summary.history : summary.memo
            guard let ref else { return nil }
            return LibraryEntry(
                id: summary.itemID, ref: ref, title: summary.title, snippet: nil,
                lastCopiedAt: summary.lastCopiedAt, kind: summary.kind, isMemo: summary.memo != nil,
                sourceApp: summary.sourceApp
            )
        }
        let page = Array(all.dropFirst(offset).prefix(100))
        return (page, offset + page.count < all.count, false)
    }

    private func handle(_ event: MemoCommitCoordinator.Event) {
        switch event {
        case .saved(let draftID, let revision, let receipt):
            guard editor?.draftID == draftID else { return }
            editor?.markSaved(receipt, revision: revision)
            if editor?.revision == revision {
                removeRecovered(draftID)
                message = nil
            }
            Task { await refreshAfterCommit(draftID: draftID, revision: revision) }
        case .failed(let draftID, let revision, _, _):
            guard editor?.draftID == draftID, editor?.revision == revision else { return }
            editor?.markFailed("The draft could not be saved.", revision: revision)
            message = "The draft could not be saved."
        }
    }

    private func removeRecovered(_ draftID: UUID) {
        recoveredByID.removeValue(forKey: draftID)
        recoveredDrafts.removeAll { $0.id == draftID }
    }

    private func refreshAfterCommit(draftID: UUID, revision: UInt64) async {
        guard refreshedRevisionByDraft[draftID] != revision else { return }
        refreshedRevisionByDraft[draftID] = revision
        do {
            try await refreshSearch()
            await reload(refreshIndex: false)
        } catch {
            if refreshedRevisionByDraft[draftID] == revision {
                refreshedRevisionByDraft.removeValue(forKey: draftID)
            }
            message = "Saved. Search results are still updating."
        }
    }

    private func isBlankNew(_ editor: MemoEditorSession) -> Bool {
        editor.ref == nil && editor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (editor.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editor.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func entry(_ result: SearchResult) -> LibraryEntry {
        LibraryEntry(
            id: result.ref.itemID, ref: result.ref, title: result.title,
            snippet: result.snippet?.text, lastCopiedAt: result.lastCopiedAt,
            kind: result.kind, isMemo: result.ref.facet == .memo || result.savedAsMemo,
            isFavorite: result.isFavorite, sourceApp: result.sourceApp, collectionID: result.collectionID
        )
    }

    nonisolated private static func historyEntry(_ summary: ItemSummary) -> LibraryEntry? {
        guard let ref = summary.history else { return nil }
        return LibraryEntry(
            id: summary.itemID, ref: ref, title: summary.title, snippet: nil,
            lastCopiedAt: summary.lastCopiedAt, kind: summary.kind, isMemo: summary.memo != nil,
            sourceApp: summary.sourceApp
        )
    }

    nonisolated private static func recoveredSummary(_ draft: RecoverableDraft) -> RecoveredDraftSummary {
        RecoveredDraftSummary(
            id: draft.draftID, title: draft.title,
            bodyPreview: draft.body.map { String($0.prefix(160)) }, savedAt: draft.savedAt
        )
    }
}
