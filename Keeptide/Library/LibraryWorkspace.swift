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
}

struct LibraryEntry: Identifiable, Equatable, Sendable {
    let id: ItemID
    let ref: ContentRef
    let title: String
    let snippet: String?
    let lastCopiedAt: Date
    let kind: ContentKind
    let isMemo: Bool
    var isFavorite = false
    var sourceApp: String? = nil
    /// The memo's collection; nil for an unfiled memo and for every clip.
    var collectionID: CollectionID? = nil
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
    private(set) var entries: [LibraryEntry] = []
    private(set) var selectedEntryID: ItemID?
    private(set) var editor: MemoEditorSession?
    private(set) var recoveredDrafts: [RecoveredDraftSummary] = []
    private(set) var isLoading = false
    private(set) var message: String?
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
        pasteSession = pasteService?.beginSession()
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
        do { collections = try await collectionService.list(expecting: storeIdentity) }
        catch { message = "Collections could not be loaded." }
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

    func deleteCollection(_ snapshot: CollectionSnapshot) async -> Bool {
        await changeCollection {
            let change = try await self.collectionService.delete(snapshot, expecting: self.storeIdentity)
            if self.scope.collectionID == snapshot.value.id {
                self.navigationGeneration &+= 1
                self.scope = .uncategorized
            }
            return change
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
            guard !isClosing, !isClosed else { return true }
            collections = try await collectionService.list(expecting: storeIdentity)
            try await refreshSearch()
            if !isClosing, !isClosed { await reload(refreshIndex: false) }
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
                collections = try await collectionService.list(expecting: storeIdentity)
            }
            guard generation == loadGeneration else { return }
            let loaded = try await loadEntries(generation: generation, offset: 0)
            guard generation == loadGeneration else { return }
            entries = loaded.entries
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
            let loaded = try await loadEntries(generation: generation, offset: entries.count)
            guard generation == loadGeneration else { return }
            let known = Set(entries.map(\.ref))
            entries.append(contentsOf: loaded.entries.filter { !known.contains($0.ref) })
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
        if value == .recentlyDeleted {
            queryTask?.cancel()
            queryTask = nil
            loadGeneration &+= 1
            query = ""
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

    /// Publish native input synchronously, before SwiftUI can render the old value.
    /// Only result loading is asynchronous; every edit invalidates older loads.
    func updateQuery(_ value: String) {
        guard !isClosing, !isClosed else { return }
        guard scope != .recentlyDeleted else { return }
        guard query != value else { return }
        query = value
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
            message = nil
        } catch {
            guard navigation == navigationGeneration else { return }
            selectedEntryID = nil
            message = "This item is no longer available."
        }
    }

    func startNew(in requestedScope: LibraryScope? = nil) async {
        guard !isClosing, !isClosed else { return }
        guard requestedScope != .recentlyDeleted, scope != .recentlyDeleted else {
            message = "Choose a snippet collection before creating a new snippet."
            return
        }
        if let requestedScope { updateScope(requestedScope) }
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
        message = nil
    }

    /// Saves the selected clip as a memo, straight into `collectionID` and as a favorite when asked, in one
    /// transaction. The editor then holds the memo, and a new save can be undone.
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
            if case .created = outcome { await refreshRowsAfterSave() }
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
        if case .created = outcome { await refreshRowsAfterSave() }
        return outcome
    }

    /// Saves several clips as memos, one transaction each, in the order given. Every clip's content is read first:
    /// one that is not complete stops the batch before anything is written. A failure while saving stops it too; the
    /// memos saved before it stay, and the clips after it are left alone. Clips that already have a memo are reported,
    /// not failed. No editing session is installed, and the single-clip undo is untouched.
    func saveHistory(
        _ refs: [ContentRef], collectionID: CollectionID? = nil, isFavorite: Bool = false
    ) async -> HistorySaveOutcome {
        var outcome = HistorySaveOutcome()
        guard !isClosing, !isClosed else { return outcome }
        for ref in refs where ref.facet == .history {
            do {
                guard try await repository.read(ref).integrity == .complete else {
                    throw LibraryWorkspaceError.contentUnavailable
                }
            } catch {
                outcome.failure = HistorySaveFailure(ref: ref, error: error)
                return outcome
            }
        }
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
        if !outcome.saved.isEmpty { await refreshRowsAfterSave() }
        return outcome
    }

    /// A row's bookmark comes from the index, which the consumer brings up to date on its own later. After a save
    /// the index is refreshed and the list reloaded, so the bookmark shows at once.
    private func refreshRowsAfterSave() async {
        guard !isClosing, !isClosed else { return }
        do {
            try await refreshSearch()
            if !isClosing, !isClosed { await reload(refreshIndex: false) }
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
        return await pasteService.execute(PasteRequest(
            ref: ref, queryGeneration: generation, mode: mode, session: pasteSession
        ))
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
            pasteSession = pasteService?.beginSession()
            scheduleQueryLoad()
            return false
        }
    }

    func endEditingSession() async -> Bool { await prepareToClose() }

    func resumeAfterCloseCancellation() {
        guard isClosing || isClosed else { return }
        isClosing = false
        isClosed = false
        pasteSession = pasteService?.beginSession()
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
        if ref.facet == .memo { return makeSession(try await libraryService.editingSnapshot(ref)) }
        let content = try await repository.read(ref)
        guard content.integrity == .complete else { throw StoreError.staleReference }
        let state = try await repository.recordState(.item(ref.itemID))
        guard case .item(let item) = state.value else { throw StoreError.staleReference }
        let extracted = try MemoTextExtractor.editableText(from: content)
        let kind: MemoKind = extracted.map {
            ContentKind.isMarkdown($0.sourceRepresentationType) ? .markdown : .plainText
        } ?? .plainText
        return MemoEditorSession(
            itemID: ref.itemID, ref: ref, isReadOnly: true, title: item.title,
            body: extracted?.text, note: "", kind: kind,
            richSourceWarning: extracted.map { $0.sourceRepresentationType != "public.utf8-plain-text" } ?? false,
            storeIdentity: storeIdentity
        )
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
            let searchScope: SearchScope = scope == .recentClips ? .history : .memo
            let collection: CollectionFilter?
            switch scope {
            case .uncategorized: collection = .uncategorized
            case .collection(let id): collection = .collection(id)
            default: collection = nil
            }
            var latest: [SearchResult] = []
            var totalMatches = 0
            var isPartial = false
            for try await page in searchService.search(SearchRequest(
                query: query, scope: searchScope, collection: collection,
                favoritesOnly: scope == .favorites,
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
