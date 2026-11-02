import Foundation
import Observation

enum LibraryScope: String, CaseIterable, Sendable {
    case recentClips
    case allSnippets
    case uncategorized
}

struct LibraryEntry: Identifiable, Equatable, Sendable {
    let id: ItemID
    let ref: ContentRef
    let title: String
    let snippet: String?
    let lastCopiedAt: Date
    let kind: ContentKind
    let isMemo: Bool
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

    private func reload(refreshIndex: Bool) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        hasMoreEntries = false
        searchIsPartial = false
        message = nil
        do {
            if refreshIndex { try await refreshSearch() }
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

    func setScope(_ value: LibraryScope) async {
        guard scope != value else { return }
        scope = value
        await reload()
    }

    func setQuery(_ value: String) async {
        guard query != value else { return }
        query = value
        await reload(refreshIndex: false)
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

    func startNew() async {
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
            kind: .plainText, storeIdentity: storeIdentity
        )
        install(session)
        selectedEntryID = nil
        message = nil
    }

    func saveSelectedHistory() async throws -> SaveMemoOutcome {
        guard let current = editor, let ref = current.ref else {
            throw LibraryWorkspaceError.unavailableSelection
        }
        if ref.facet == .memo { return .existing(ref) }
        let navigation = navigationGeneration
        let draftID = current.draftID
        let outcome: SaveMemoOutcome
        let snapshot: MemoEditingSnapshot
        do {
            outcome = try await libraryService.saveAsMemo(ref.itemID, expecting: storeIdentity)
            snapshot = try await libraryService.editingSnapshot(outcome.ref)
        } catch {
            message = "This clip could not be saved as a snippet."
            throw error
        }
        guard navigation == navigationGeneration, editor?.draftID == draftID, editor?.ref == ref else {
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
        return outcome
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
            baseMemoFingerprint: draft.baseMemoFingerprint, languageHint: draft.languageHint
        )
        install(session)
        editorDidChange(session)
        selectedEntryID = draft.itemID
    }

    func prepareToClose() async -> Bool {
        if isClosed { return true }
        guard !isClosing else { return false }
        isClosing = true
        pasteSession?.end()
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
            return false
        }
    }

    func endEditingSession() async -> Bool { await prepareToClose() }

    func resumeAfterCloseCancellation() {
        guard isClosing || isClosed else { return }
        isClosing = false
        isClosed = false
        pasteSession = pasteService?.beginSession()
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
            isComposing: session.isComposing, revision: session.revision, savedAt: Date()
        )
    }

    private func makeSession(_ ref: ContentRef) async throws -> MemoEditorSession {
        if ref.facet == .memo { return makeSession(try await libraryService.editingSnapshot(ref)) }
        let content = try await repository.read(ref)
        guard content.integrity == .complete else { throw StoreError.staleReference }
        let state = try await repository.recordState(.item(ref.itemID))
        guard case .item(let item) = state.value else { throw StoreError.staleReference }
        let extracted = try MemoTextExtractor.editableText(from: content)
        return MemoEditorSession(
            itemID: ref.itemID, ref: ref, isReadOnly: true, title: item.title,
            body: extracted?.text, note: "", kind: .plainText,
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
        if let searchService {
            let searchScope: SearchScope = scope == .recentClips ? .history : .memo
            let collection: CollectionFilter? = scope == .uncategorized ? .uncategorized : nil
            var latest: [SearchResult] = []
            var totalMatches = 0
            var isPartial = false
            for try await page in searchService.search(SearchRequest(
                query: query, scope: searchScope, collection: collection,
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
        guard query.isEmpty, scope != .uncategorized else {
            throw LibraryWorkspaceError.searchUnavailable
        }
        let recent = try await repository.recent(limit: 200)
        let all = recent.compactMap { summary -> LibraryEntry? in
            let ref = scope == .recentClips ? summary.history : summary.memo
            guard let ref else { return nil }
            return LibraryEntry(
                id: summary.itemID, ref: ref, title: summary.title, snippet: nil,
                lastCopiedAt: summary.lastCopiedAt, kind: summary.kind, isMemo: summary.memo != nil
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
            kind: result.kind, isMemo: result.savedAsMemo
        )
    }

    nonisolated private static func historyEntry(_ summary: ItemSummary) -> LibraryEntry? {
        guard let ref = summary.history else { return nil }
        return LibraryEntry(
            id: summary.itemID, ref: ref, title: summary.title, snippet: nil,
            lastCopiedAt: summary.lastCopiedAt, kind: summary.kind, isMemo: summary.memo != nil
        )
    }

    nonisolated private static func recoveredSummary(_ draft: RecoverableDraft) -> RecoveredDraftSummary {
        RecoveredDraftSummary(
            id: draft.draftID, title: draft.title,
            bodyPreview: draft.body.map { String($0.prefix(160)) }, savedAt: draft.savedAt
        )
    }
}
