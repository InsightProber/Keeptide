import CoreData
import Foundation

/// Keeps the search index current from Core Data persistent history. Each pass
/// re-projects affected items from their current state, so replaying a change
/// is harmless, and the checkpoint advances in the same SQLite transaction as
/// the documents it covers. Passes never overlap.
actor HistoryConsumer {
    private static let batchSize = 128
    private static let textByteBudget: Int64 = 32 * 1_048_576
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

    private let controller: PersistenceController
    private let index: SQLiteSearchIndex
    private let status: SearchIndexStatus
    private let debounce: Duration
    private var observer: (any NSObjectProtocol)?
    private var scheduled: Task<Void, Never>?
    private var activePass: Task<Void, Error>?
    private var failures = 0
    private var rebuildRequested = false
    private var stopped = false

    init(controller: PersistenceController, index: SQLiteSearchIndex, status: SearchIndexStatus,
         debounce: Duration = .milliseconds(150)) {
        self.controller = controller
        self.index = index
        self.status = status
        self.debounce = debounce
    }

    /// Observes writer saves and schedules the first pass; returns immediately.
    func start() {
        guard !stopped, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: controller.writer, queue: nil
        ) { [weak self] _ in
            Task { await self?.schedule() }
        }
        status.setReadFailureHandler { [weak self] in
            Task { await self?.requestRebuild() }
        }
        schedule(after: .zero)
    }

    /// Runs one pass that starts after this call: validates or rebuilds the
    /// index, catches up until the history checkpoint stops moving, and
    /// refreshes the usage mirror.
    func synchronize() async throws {
        while let active = activePass { _ = await active.result }
        guard !stopped else { return }
        let pass = Task { try await self.runPass() }
        activePass = pass
        defer { if activePass == pass { activePass = nil } }
        try await pass.value
    }

    func stopAndDrain() async {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        scheduled?.cancel()
        scheduled = nil
        if let activePass {
            activePass.cancel()
            _ = await activePass.result
        }
    }

    private func schedule(after delay: Duration? = nil) {
        guard !stopped, scheduled == nil else { return }
        let delay = delay ?? debounce
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.runScheduled()
        }
    }

    private func runScheduled() async {
        scheduled = nil
        try? await synchronize()
    }

    private func requestRebuild() {
        rebuildRequested = true
        schedule(after: .zero)
    }

    private func runPass() async throws {
        guard !stopped else { return }
        do {
            try await synchronizeOnce()
            failures = 0
        } catch is CancellationError {
            throw CancellationError()
        } catch StoreError.closed {
            stopped = true
        } catch SearchIndexError.closed {
            stopped = true
        } catch {
            status.update(.unavailable)
            let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
            failures += 1
            schedule(after: delay)
            throw error
        }
    }

    private func synchronizeOnce() async throws {
        let identity = try await controller.identity()
        // nil: rebuild only if the index is unusable; .some(boundary): rebuild from it.
        var forcedRebuild: Data?? = rebuildRequested ? .some(nil) : nil
        rebuildRequested = false
        for _ in 0..<3 {
            do {
                if let boundary = forcedRebuild {
                    try await rebuild(identity: identity, from: boundary)
                    forcedRebuild = nil
                } else if try !(index.metadata()?.isUsable(for: identity) ?? false) {
                    try await rebuild(identity: identity, from: nil)
                }
                guard let metadata = try index.metadata() else { throw SearchIndexError.corrupt }
                try await catchUp(from: metadata.checkpoint, identity: identity)
                try index.replaceUsage(try await LocalUsageStore(controller: controller).allSummaries())
                status.update(.ready)
                return
            } catch SearchIndexError.corrupt {
                forcedRebuild = .some(nil)
            } catch StoreError.invalidToken {
                forcedRebuild = .some(nil)
            } catch StoreError.historyRequiresRebuild(let checkpoint) {
                forcedRebuild = .some(checkpoint)
            }
        }
        throw SearchIndexError.corrupt
    }

    /// Builds a new index from current facts. The boundary is taken before the
    /// scan, so anything committed during the scan is replayed afterwards.
    private func rebuild(identity: StoreIdentity, from provided: Data?) async throws {
        status.update(.rebuilding)
        try index.reset(identity: identity)
        var boundary = provided
        if boundary == nil {
            boundary = try await StoreChangeReader(controller: controller).currentCheckpoint()
        }
        let sequence = try boundary.map(StoreChangeReader.sequence(of:)) ?? 0
        let ids = try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            return try StoredRecords.searchAllItemIDs(in: context)
        }
        try await project(ids, sequence: sequence, checkpoint: .keep)
        try index.finishBuild(checkpoint: boundary)
    }

    private func catchUp(from start: Data?, identity: StoreIdentity) async throws {
        let reader = StoreChangeReader(controller: controller)
        var token = start
        while true {
            try Task.checkCancellation()
            let batch = try await reader.read(after: token)
            guard batch.identity == identity else { throw StoreError.invalidToken }
            // Relationship-only pages carry no changes but still move the token.
            guard let next = batch.token, next != token else { return }
            let changes = batch.transactions.flatMap(\.changes)
            let sequence = try StoreChangeReader.sequence(of: next)
            if changes.isEmpty {
                try index.apply([], sequence: sequence, checkpoint: .set(next))
            } else {
                status.update(.updating)
                try await project(try await affectedItems(changes), sequence: sequence, checkpoint: .set(next))
            }
            token = next
        }
    }

    private func affectedItems(_ changes: [StoreChange]) async throws -> [ItemID] {
        let fromStore = try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            return try StoredRecords.searchItemIDs(for: changes, in: context)
        }
        let references = Set(changes.filter { $0.entity == "CaptureSnapshot" || $0.entity == "MemoDocument" }.map(\.id))
        return Array(fromStore.union(try index.itemIDs(referencing: references)))
    }

    /// Replaces the documents of `ids` in bounded batches. Only the last batch
    /// carries the checkpoint, so an interruption replays the whole set.
    private func project(_ ids: [ItemID], sequence: Int64, checkpoint: CheckpointUpdate) async throws {
        var remaining = ids[...]
        if remaining.isEmpty, case .set = checkpoint {
            try index.apply([], sequence: sequence, checkpoint: checkpoint)
        }
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let batch = Array(remaining.prefix(Self.batchSize))
            let projected = try await controller.perform { context in
                context.reset()
                defer { context.reset() }
                return try StoredRecords.searchProjection(
                    itemIDs: batch, maximumTextBytes: Self.textByteBudget, in: context
                )
            }
            guard projected.processed > 0 else { throw SearchIndexError.corrupt }
            remaining = remaining.dropFirst(projected.processed)
            let documents = Dictionary(
                grouping: projected.inputs.flatMap(SearchDocumentBuilder.documents(for:)), by: \.ref.itemID.rawValue
            )
            let changes = batch.prefix(projected.processed).map {
                IndexedItemChange(itemID: $0, documents: documents[$0.rawValue] ?? [])
            }
            try index.apply(changes, sequence: sequence, checkpoint: remaining.isEmpty ? checkpoint : .keep)
        }
    }
}
