import Foundation
import Observation

/// One local library's maintenance lifetime. All operations keep its opening
/// identity; a replaced store can never inherit a pending UI or timer action.
@MainActor @Observable
final class LibraryMaintenance {
    private(set) var trash: [TrashFacetSnapshot] = []
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var usage: StorageUsageReport?
    private let controller: PersistenceController
    private let identity: StoreIdentity
    private let directory: URL
    private let preferences: LifecyclePreferences
    private let didChange: @MainActor () async -> Void
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored private var settingsModel: LifecycleSettingsModel?

    /// Said while a blocked cleanup intent waits for review, after every action until it no longer does.
    private static let cleanupNeedsReview = "Some cleanup needs review. Its evidence was preserved."

    var settings: LifecycleSettingsModel {
        if let settingsModel { return settingsModel }
        let model = LifecycleSettingsModel(
        preferences: preferences,
        impact: { [weak self] choice in
            guard let self, !self.isClosed, let policy = choice.policy else { throw StoreError.closed }
            return try await LifecycleService(controller: self.controller).retentionImpact(
                policy: policy, at: Date(), expecting: self.identity
            ).historyCount
        },
        apply: { [weak self] change, confirmed in
            guard let self, !self.isClosed, !self.isWorking else { throw StoreError.operationDenied }
            let permit = try await StoreSafetyGate(controller: self.controller).permit(.maintenance)
            guard !self.isClosed, permit.identity == self.identity else { throw StoreError.preconditionFailed }
            try self.preferences.commit(change, confirmingShortening: confirmed)
            await self.runScheduledMaintenance()
            return self.preferences.snapshot()
        },
        usageRefresh: { [weak self] in
            guard let self, !self.isClosed else { throw StoreError.closed }
            return try await self.measureUsage()
        }
        )
        settingsModel = model
        return model
    }

    init(controller: PersistenceController, identity: StoreIdentity, directory: URL,
         preferences: LifecyclePreferences, didChange: @escaping @MainActor () async -> Void = {}) {
        self.controller = controller
        self.identity = identity
        self.directory = directory
        self.preferences = preferences
        self.didChange = didChange
    }

    func start() {
        guard periodicTask == nil, !isClosed else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isClosed else { return }
                await self.runScheduledMaintenance()
                do { try await Task.sleep(for: .seconds(60 * 60)) }
                catch { return }
            }
        }
    }

    func stopAndDrain() async {
        isClosed = true
        periodicTask?.cancel()
        if isWorking {
            await withCheckedContinuation { completionWaiters.append($0) }
        }
        await periodicTask?.value
        periodicTask = nil
    }

    func refreshTrash() async {
        guard !isClosed, !isWorking else { return }
        await perform { _ in try await self.loadTrash() }
    }

    @discardableResult
    func remove(_ ref: ContentRef) async -> Bool {
        await moveToRecentlyDeleted(ref, waitingForTurn: false) != nil
    }

    /// Quick access's Move to Recently Deleted: exactly this facet generation, waiting for an action already under way
    /// rather than being refused for it, as when ⌘⌫ is pressed again before the last move is done. What it moved, for
    /// an undo; nil when it could not move it.
    func moveToRecentlyDeleted(_ ref: ContentRef) async -> DeletedFacetIdentity? {
        await moveToRecentlyDeleted(ref, waitingForTurn: true)
    }

    /// Quick access's undo of a move: puts back what `moveToRecentlyDeleted` moved, after any action under way. True
    /// once it is back, even when Recently Deleted could not be read again after it.
    func recover(_ target: DeletedFacetIdentity) async -> Bool {
        await waitForTurn()
        var restored = false
        await perform { permit in
            _ = try await LifecycleService(controller: self.controller).restore(
                target, policy: self.policy, at: Date(), expecting: self.identity, permit: permit
            )
            restored = true
            await self.didChange()
            try await self.loadTrash()
        }
        return restored
    }

    /// Quick access (`waitingForTurn`) gets what was moved once it is moved, even when Recently Deleted could not be
    /// read again after it: the move stands, and its undo needs it. The library's own delete keeps `perform`'s answer
    /// of whether everything succeeded.
    private func moveToRecentlyDeleted(_ ref: ContentRef, waitingForTurn: Bool) async -> DeletedFacetIdentity? {
        if waitingForTurn { await waitForTurn() }
        var moved: DeletedFacetIdentity?
        let done = await perform { permit in
            moved = try await LifecycleService(controller: self.controller).remove(
                ref: ref, at: Date(), expecting: self.identity, permit: permit
            ).target
            await self.didChange()
            try await self.loadTrash()
        }
        if waitingForTurn { return moved }
        return done ? moved : nil
    }

    /// Returns once no action is under way. Waiters resume together when one ends, and the first to act takes the next
    /// turn; the others wait again.
    private func waitForTurn() async {
        while isWorking, !isClosed {
            await withCheckedContinuation { completionWaiters.append($0) }
        }
    }

    @discardableResult
    func restore(_ target: DeletedFacetIdentity) async -> Bool {
        await perform { permit in
            _ = try await LifecycleService(controller: self.controller).restore(
                target, policy: self.policy, at: Date(), expecting: self.identity, permit: permit
            )
            await self.didChange()
            try await self.loadTrash()
        }
    }

    /// Called only by the product's explicit permanent-delete confirmation.
    @discardableResult
    func permanentlyDelete(_ target: DeletedFacetIdentity) async -> Bool {
        await perform { permit in
            _ = try await LifecycleCleanupService(controller: self.controller).purgeFacet(
                target, trigger: .explicitUserRequest, at: Date(), expecting: self.identity, permit: permit
            )
            await self.didChange()
            try await self.loadTrash()
        }
    }

    func runScheduledMaintenance() async {
        await perform { permit in
            let now = Date()
            let intents = CleanupIntentStore(controller: self.controller)
            let reclaimer = PayloadReclaimer(controller: self.controller)
            var cursor: UUID?
            while !Task.isCancelled, !self.isClosed {
                let ids = try await intents.pendingIDs(expecting: self.identity, permit: permit, afterID: cursor)
                guard let last = ids.last else { break }
                for id in ids {
                    try Task.checkCancellation()
                    do { _ = try await reclaimer.resume(id, expecting: self.identity, permit: permit, at: now) }
                    catch CleanupError.blocked { self.message = Self.cleanupNeedsReview }
                    catch CleanupError.unsupportedIntent {
                        self.message = "Some cleanup needs a newer version. Its evidence was preserved."
                        return // Do not turn a permanent recovery requirement into an expiry retry.
                    }
                }
                cursor = last
            }
            try Task.checkCancellation()
            guard !self.isClosed else { throw StoreError.closed }
            _ = try await LifecycleService(controller: self.controller).expireHistory(
                policy: self.policy, at: now, expecting: self.identity, permit: permit
            )
            let planner = LifecycleCleanupPlanner(controller: self.controller)
            let cleanup = LifecycleCleanupService(controller: self.controller)
            var candidateCursor: LifecycleCleanupCandidateCursor?
            repeat {
                try Task.checkCancellation()
                guard !self.isClosed else { throw StoreError.closed }
                let page = try await planner.candidates(
                    policy: self.policy, at: now, expecting: self.identity,
                    permit: permit, after: candidateCursor
                )
                for candidate in page.candidates {
                    try Task.checkCancellation()
                    do {
                        _ = try await cleanup.purgeFacet(
                            candidate.target, trigger: candidate.trigger, at: now,
                            expecting: self.identity, permit: permit
                        )
                    } catch StoreError.contentProtected {
                        // An archive still reads this payload. Retry in a later pass.
                    } catch StoreError.preconditionFailed {
                        guard try await self.controller.identity() == self.identity else { throw StoreError.preconditionFailed }
                    } catch CleanupError.blocked {
                        self.message = Self.cleanupNeedsReview
                    }
                }
                candidateCursor = page.next
            } while candidateCursor != nil
            try await self.loadTrash()
            _ = try await self.measureUsage()
            await self.didChange()
        }
    }

    private var policy: RetentionPolicy { preferences.snapshot().historyRetention.policy ?? .permanent }

    private func loadTrash() async throws {
        let rows = try await LifecycleService(controller: controller).trash(
            policy: policy, at: Date(), expecting: identity
        )
        guard !isClosed else { return }
        trash = rows
    }

    private func measureUsage() async throws -> StorageUsageReport {
        guard !isClosed, try await controller.identity() == identity else { throw StoreError.preconditionFailed }
        let root = directory
        let report = await Task.detached(priority: .utility) { StorageUsageScanner().scan(libraryRoot: root) }.value
        guard !isClosed, try await controller.identity() == identity else { throw StoreError.preconditionFailed }
        usage = report
        return report
    }

    @discardableResult
    private func perform(_ operation: (StorePermit) async throws -> Void) async -> Bool {
        guard !isClosed, !isWorking else { return false }
        isWorking = true
        message = nil
        defer {
            isWorking = false
            let waiters = completionWaiters
            completionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            guard !isClosed, permit.identity == identity else { throw StoreError.preconditionFailed }
            try await operation(permit)
            // Every action starts without a message, and a blocked intent is not pending, so no later pass meets one
            // that an earlier pass blocked. It still holds its evidence for review, so each action that succeeds says
            // so, among them the refresh Recently Deleted runs as it appears. Not knowing leaves the action as it went.
            if message == nil, !isClosed {
                let intents = CleanupIntentStore(controller: controller)
                let isBlocked = (try? await intents.hasBlockedIntent(expecting: identity, permit: permit)) == true
                if isBlocked, !isClosed { message = Self.cleanupNeedsReview }
            }
            return true
        } catch is CancellationError {
            return false
        } catch StoreError.operationDenied {
            if !isClosed { message = "Maintenance requires a newer Keeptide version or library recovery. Existing content is preserved." }
            return false
        } catch {
            if !isClosed { message = "This maintenance action could not finish. Your remaining content is preserved. Try again." }
            return false
        }
    }
}

/// Quick access moves clips to Recently Deleted, and back, through the library's maintenance.
extension LibraryMaintenance: QuickAccessLifecycle {}
