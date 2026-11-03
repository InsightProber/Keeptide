import Foundation

actor MemoCommitCoordinator {
    enum Event: Sendable {
        case saved(draftID: UUID, revision: UInt64, receipt: MemoCommitReceipt)
        case failed(draftID: UUID, revision: UInt64, storageRevision: UInt64, stage: DraftCoordinationStage)
    }
    private let onEvent: @Sendable (Event) -> Void

    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Commit = @Sendable (RecoverableDraft) async throws -> MemoCommitReceipt

    private let store: any DraftStoring
    private let persistDelay: Duration
    private let commitDelay: Duration
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let commit: Commit
    private var drafts: [UUID: RecoverableDraft] = [:]
    private var persistTasks: [UUID: Task<Void, Never>] = [:]
    private var commitTasks: [UUID: Task<Void, Never>] = [:]
    private var inFlightCommits: [UUID: InFlightCommit] = [:]
    private var lineages: [UUID: DraftLineage] = [:]
    private var pendingWrites: [UUID: Int] = [:]
    private var failures: [UUID: DraftCoordinationFailure] = [:]

    init(
        store: any DraftStoring,
        persistDelay: Duration = .milliseconds(300),
        commitDelay: Duration = .seconds(1),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in },
        commit: @escaping Commit
    ) {
        self.onEvent = onEvent
        self.store = store
        self.persistDelay = persistDelay
        self.commitDelay = commitDelay
        self.sleep = sleep
        self.now = now
        self.commit = commit
    }

    func update(_ incoming: RecoverableDraft) {
        var draft = incoming
        if let current = drafts[incoming.draftID] {
            guard incoming.revision > current.revision,
                  current.storageRevision < UInt64.max else { return }
            draft.itemID = current.itemID
            draft.conflictItemID = current.conflictItemID
            draft.base = current.base
            draft.baseMemoFingerprint = current.baseMemoFingerprint
            draft.storeIdentity = current.storeIdentity
            draft.storageRevision = current.storageRevision + 1
        } else if let lineage = lineages[incoming.draftID] {
            guard incoming.revision > lineage.revision,
                  lineage.storageRevision < UInt64.max else { return }
            draft.itemID = lineage.itemID
            draft.conflictItemID = lineage.conflictItemID
            draft.base = lineage.base
            draft.baseMemoFingerprint = lineage.baseMemoFingerprint
            draft.storeIdentity = lineage.storeIdentity
            draft.storageRevision = lineage.storageRevision + 1
        }
        draft.savedAt = now()
        drafts[draft.draftID] = draft
        cancelTimers(draft.draftID)
        schedulePersistence(for: draft)
        if !draft.isComposing { scheduleCommit(for: draft) }
    }

    func focusLost(_ draftID: UUID) async throws -> MemoCommitReceipt? {
        cancelTimers(draftID)
        guard let draft = drafts[draftID] else { return nil }
        do {
            try await persist(draft)
            clearFailure(draftID, generation: draft.generation)
        } catch {
            if let receipt = completedReceipt(for: draft) { return receipt }
            recordFailure(.persistence, draft: draft)
            throw error
        }
        guard !draft.isComposing else { return nil }
        return try await commitExplicitly(draft)
    }

    func commitNow(_ draftID: UUID) async throws -> MemoCommitReceipt? {
        cancelTimers(draftID)
        guard let draft = drafts[draftID] else { return nil }
        do {
            try await persist(draft)
            clearFailure(draftID, generation: draft.generation)
        } catch {
            if let receipt = completedReceipt(for: draft) { return receipt }
            recordFailure(.persistence, draft: draft)
            throw error
        }
        guard !draft.isComposing else { return nil }
        return try await commitExplicitly(draft)
    }

    func latestDraft(_ draftID: UUID) -> RecoverableDraft? { drafts[draftID] }
    func lastFailure(_ draftID: UUID) -> DraftCoordinationFailure? { failures[draftID] }

    @discardableResult
    func endSession(_ draftID: UUID) async -> Bool {
        guard drafts[draftID] == nil,
              inFlightCommits[draftID] == nil,
              pendingWrites[draftID] == nil else { return false }
        cancelTimers(draftID)
        if let lineage = lineages.removeValue(forKey: draftID) {
            await store.releaseRetiredRevision(draftID, through: lineage.storageRevision)
        }
        failures.removeValue(forKey: draftID)
        return true
    }

    func cancel(_ draftID: UUID) async throws {
        while let draft = drafts[draftID] {
            cancelTimers(draftID)
            do {
                try await persist(draft)
                clearFailure(draftID, generation: draft.generation)
            } catch {
                if completedReceipt(for: draft) != nil { continue }
                // A newer revision may have reached disk while this write was
                // suspended. Drain it rather than reporting an obsolete CAS.
                if error as? DraftStoreError == .staleRevision,
                   drafts[draftID]?.generation != draft.generation { continue }
                recordFailure(.persistence, draft: draft)
                throw error
            }
            guard drafts[draftID]?.generation != draft.generation else {
                cancelTimers(draftID)
                return
            }
        }
        cancelTimers(draftID)
    }

    func restore() async throws -> [RecoverableDraft] {
        register(try await store.loadAll())
    }

    func restoreBestEffort() async throws -> DraftRestoreResult {
        let result = try await store.loadAllBestEffort()
        return DraftRestoreResult(drafts: register(result.drafts), failedIDs: result.failedIDs)
    }

    private func register(_ recovered: [RecoverableDraft]) -> [RecoverableDraft] {
        for draft in recovered {
            guard var current = drafts[draft.draftID] else {
                drafts[draft.draftID] = draft
                continue
            }
            if current.storageRevision > draft.storageRevision { continue }
            if current.storageRevision == draft.storageRevision {
                if current == draft { continue }
                guard current.revision > draft.revision,
                      current.storageRevision < UInt64.max else {
                    drafts[draft.draftID] = draft
                    continue
                }
                current.storageRevision += 1
                drafts[current.draftID] = current
                continue
            }
            drafts[draft.draftID] = draft
        }
        return drafts.values.sorted { $0.draftID.uuidString < $1.draftID.uuidString }
    }

    private func schedulePersistence(for draft: RecoverableDraft) {
        let delay = persistDelay
        let sleep = sleep
        persistTasks[draft.draftID] = Task { [weak self] in
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                try await self?.persistIfCurrent(draft.draftID, generation: draft.generation)
            } catch is CancellationError {
            } catch {
                await self?.recordFailure(.persistence, draft: draft)
            }
        }
    }

    private func scheduleCommit(for draft: RecoverableDraft) {
        let delay = commitDelay
        let sleep = sleep
        commitTasks[draft.draftID] = Task { [weak self] in
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                _ = try await self?.commitIfCurrent(draft.draftID, generation: draft.generation)
            } catch is CancellationError {
            } catch {
                await self?.recordFailure(.commit, draft: draft)
            }
        }
    }

    private func persistIfCurrent(_ draftID: UUID, generation: DraftGeneration) async throws {
        guard let current = drafts[draftID], current.generation == generation else { return }
        do {
            try await persist(current)
        } catch {
            if completedReceipt(for: current) != nil { return }
            throw error
        }
        clearFailure(draftID, generation: generation)
    }

    private func commitIfCurrent(_ draftID: UUID, generation: DraftGeneration) async throws -> MemoCommitReceipt? {
        guard let current = drafts[draftID], current.generation == generation else { return nil }
        do {
            try await persist(current)
        } catch {
            if let receipt = completedReceipt(for: current) { return receipt }
            throw error
        }
        guard !current.isComposing else { return nil }
        return try await commitPersisted(current)
    }

    private func commitPersisted(_ committedDraft: RecoverableDraft) async throws -> MemoCommitReceipt? {
        if let receipt = completedReceipt(for: committedDraft) { return receipt }
        if let active = inFlightCommits[committedDraft.draftID] {
            return try await join(active, requested: committedDraft)
        }
        do {
            try await persist(committedDraft)
        } catch {
            if let receipt = completedReceipt(for: committedDraft) { return receipt }
            if let current = drafts[committedDraft.draftID], current.generation != committedDraft.generation {
                return try await commitPersisted(current)
            }
            recordFailure(.persistence, draft: committedDraft)
            throw error
        }
        if let receipt = completedReceipt(for: committedDraft) { return receipt }
        guard let current = drafts[committedDraft.draftID] else {
            throw StoreError.preconditionFailed
        }
        if current.generation != committedDraft.generation {
            guard !current.isComposing else { return nil }
            return try await commitPersisted(current)
        }
        if let active = inFlightCommits[committedDraft.draftID] {
            return try await join(active, requested: committedDraft)
        }
        guard !current.isComposing else { return nil }
        let token = UUID()
        let commit = commit
        let task = Task { [weak self] in
            let receipt = try await commit(committedDraft)
            guard let self else { return receipt }
            try await self.finish(token: token, draft: committedDraft, receipt: receipt)
            return receipt
        }
        let active = InFlightCommit(token: token, draft: committedDraft, task: task)
        inFlightCommits[committedDraft.draftID] = active
        let receipt: MemoCommitReceipt
        do {
            receipt = try await task.value
        } catch {
            if inFlightCommits[committedDraft.draftID]?.token == token {
                inFlightCommits.removeValue(forKey: committedDraft.draftID)
            }
            throw error
        }
        return receipt
    }

    private func join(_ active: InFlightCommit, requested: RecoverableDraft) async throws -> MemoCommitReceipt? {
        let receipt = try await active.task.value
        if requested.revision > active.draft.revision,
           let current = drafts[requested.draftID], current.revision > active.draft.revision {
            guard !current.isComposing else { return receipt }
            return try await commitPersisted(current)
        }
        return receipt
    }

    private func finish(token: UUID, draft committedDraft: RecoverableDraft, receipt: MemoCommitReceipt) async throws {
        guard inFlightCommits[committedDraft.draftID]?.token == token else { return }
        defer { inFlightCommits.removeValue(forKey: committedDraft.draftID) }
        guard var current = drafts[committedDraft.draftID] else { return }
        if current.generation == committedDraft.generation {
            let removed = try await store.remove(
                committedDraft.draftID,
                ifStorageRevision: committedDraft.storageRevision
            )
            guard let afterRemoval = drafts[committedDraft.draftID] else { return }
            if afterRemoval.generation == committedDraft.generation {
                if removed {
                    lineages[committedDraft.draftID] = lineage(after: committedDraft, receipt: receipt)
                    cancelTimers(committedDraft.draftID)
                    drafts.removeValue(forKey: committedDraft.draftID)
                    failures.removeValue(forKey: committedDraft.draftID)
                    onEvent(.saved(draftID: committedDraft.draftID,
                                   revision: committedDraft.revision, receipt: receipt))
                }
                return
            }
            current = afterRemoval
        }
        if current.revision > committedDraft.revision {
            try await advance(current, from: committedDraft, receipt: receipt)
            onEvent(.saved(draftID: committedDraft.draftID,
                           revision: committedDraft.revision, receipt: receipt))
        }
    }

    private func advance(
        _ currentDraft: RecoverableDraft,
        from committedDraft: RecoverableDraft,
        receipt: MemoCommitReceipt
    ) async throws {
        var current = currentDraft
        guard current.storageRevision < UInt64.max else { throw StoreError.invalidTransaction }
        guard current.base == committedDraft.base,
              current.baseMemoFingerprint == committedDraft.baseMemoFingerprint else {
            throw StoreError.preconditionFailed
        }
        current.base = receipt.ref
        current.baseMemoFingerprint = receipt.memoFingerprint
        if receipt.ref.itemID != committedDraft.itemID {
            current.itemID = receipt.ref.itemID
            current.conflictItemID = ItemID()
            while current.conflictItemID == current.itemID {
                current.conflictItemID = ItemID()
            }
        }
        current.storageRevision += 1
        drafts[current.draftID] = current
        cancelTimers(current.draftID)
        do {
            try await persist(current)
            clearFailure(current.draftID, generation: current.generation)
        } catch {
            recordFailure(.persistence, draft: current)
            throw error
        }
        guard drafts[current.draftID]?.revision == current.revision else { return }
        schedulePersistence(for: current)
        if !current.isComposing { scheduleCommit(for: current) }
    }

    private func commitExplicitly(_ draft: RecoverableDraft) async throws -> MemoCommitReceipt? {
        do {
            let receipt = try await commitPersisted(draft)
            clearFailure(draft.draftID, generation: draft.generation)
            return receipt
        } catch {
            recordFailure(.commit, draft: draft)
            throw error
        }
    }

    private func recordFailure(_ stage: DraftCoordinationStage, draft: RecoverableDraft) {
        if let current = failures[draft.draftID],
           current.storageRevision >= draft.storageRevision,
           current.stage == .persistence {
            return
        }
        failures[draft.draftID] = DraftCoordinationFailure(
            stage: stage,
            draftID: draft.draftID,
            revision: draft.revision,
            storageRevision: draft.storageRevision
        )
        onEvent(.failed(draftID: draft.draftID, revision: draft.revision,
                        storageRevision: draft.storageRevision, stage: stage))
    }

    private func clearFailure(_ draftID: UUID, generation: DraftGeneration) {
        guard let failure = failures[draftID],
              failure.storageRevision <= generation.storageRevision else { return }
        failures.removeValue(forKey: draftID)
    }

    private func cancelTimers(_ draftID: UUID) {
        persistTasks.removeValue(forKey: draftID)?.cancel()
        commitTasks.removeValue(forKey: draftID)?.cancel()
    }

    private func persist(_ draft: RecoverableDraft) async throws {
        pendingWrites[draft.draftID, default: 0] += 1
        defer {
            let remaining = (pendingWrites[draft.draftID] ?? 1) - 1
            if remaining == 0 {
                pendingWrites.removeValue(forKey: draft.draftID)
            } else {
                pendingWrites[draft.draftID] = remaining
            }
        }
        try await store.write(draft)
    }

    private func completedReceipt(for draft: RecoverableDraft) -> MemoCommitReceipt? {
        guard let lineage = lineages[draft.draftID],
              lineage.revision == draft.revision,
              lineage.storageRevision == draft.storageRevision else { return nil }
        return MemoCommitReceipt(ref: lineage.base, memoFingerprint: lineage.baseMemoFingerprint)
    }

    private func lineage(after draft: RecoverableDraft, receipt: MemoCommitReceipt) -> DraftLineage {
        var itemID = draft.itemID
        var conflictItemID = draft.conflictItemID
        if receipt.ref.itemID != draft.itemID {
            itemID = receipt.ref.itemID
            conflictItemID = ItemID()
            while conflictItemID == itemID {
                conflictItemID = ItemID()
            }
        }
        return DraftLineage(
            revision: draft.revision,
            storageRevision: draft.storageRevision,
            itemID: itemID,
            conflictItemID: conflictItemID,
            storeIdentity: draft.storeIdentity,
            base: receipt.ref,
            baseMemoFingerprint: receipt.memoFingerprint
        )
    }
}

private struct InFlightCommit {
    let token: UUID
    let draft: RecoverableDraft
    let task: Task<MemoCommitReceipt, Error>
}

private struct DraftLineage {
    let revision: UInt64
    let storageRevision: UInt64
    let itemID: ItemID
    let conflictItemID: ItemID
    let storeIdentity: StoreIdentity
    let base: ContentRef
    let baseMemoFingerprint: Data
}

struct MemoCommitReceipt: Equatable, Sendable {
    var ref: ContentRef
    var memoFingerprint: Data
}

enum DraftCoordinationStage: Equatable, Sendable {
    case persistence
    case commit
}

struct DraftCoordinationFailure: Equatable, Sendable {
    let stage: DraftCoordinationStage
    let draftID: UUID
    let revision: UInt64
    let storageRevision: UInt64
}

private struct DraftGeneration: Equatable, Sendable {
    let revision: UInt64
    let storageRevision: UInt64
}

private extension RecoverableDraft {
    var generation: DraftGeneration {
        DraftGeneration(revision: revision, storageRevision: storageRevision)
    }
}

extension MemoCommitCoordinator {
    func discardEmptyDraft(_ draftID: UUID) async throws -> Bool {
        guard let draft = drafts[draftID], draft.base == nil, !draft.isComposing,
              [draft.title, draft.body ?? "", draft.note].allSatisfy({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }), inFlightCommits[draftID] == nil, pendingWrites[draftID] == nil else { return false }
        cancelTimers(draftID)
        // Persist before conditional removal so the store fences delayed writes.
        try await persist(draft)
        guard drafts[draftID]?.generation == draft.generation,
              inFlightCommits[draftID] == nil else { return false }
        guard try await store.remove(draftID, ifStorageRevision: draft.storageRevision),
              drafts[draftID]?.generation == draft.generation else { return false }
        drafts.removeValue(forKey: draftID)
        failures.removeValue(forKey: draftID)
        // Keep the retired revision until this coordinator is released: an editor
        // callback queued before closing must not resurrect the blank draft.
        return true
    }
}
