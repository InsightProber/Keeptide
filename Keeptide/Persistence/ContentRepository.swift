import Foundation

struct RecordState: Sendable {
    let value: RecordValue
    let fingerprint: Data
}

struct ContentRepository: Sendable {
    let controller: PersistenceController

    func read(_ ref: ContentRef) async throws -> ResolvedContent {
        let cancellation = ContentReadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await controller.perform { context in
                try cancellation.check()
                context.reset()
                defer { context.reset() }
                let content = try StoredRecords.resolve(ref, in: context)
                try cancellation.check()
                return content
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func recent(limit: Int) async throws -> [ItemSummary] {
        guard (0...1000).contains(limit) else { throw StoreError.invalidTransaction }
        return try await controller.perform { context in
            context.reset()
            return try StoredRecords.summaries(limit: limit, in: context)
        }
    }

    func recordState(_ key: RecordKey) async throws -> RecordState {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard let value = try StoredRecords.value(key, in: context) else { throw StoreError.notFound }
            return RecordState(value: value, fingerprint: try StoredRecords.fingerprint(key, in: context))
        }
    }

    func candidateFingerprint(digest: Data) async throws -> Data {
        try await controller.perform { context in
            context.reset()
            return try StoredRecords.candidateFingerprint(digest: digest, in: context)
        }
    }

    func referenceFingerprint(snapshotID: UUID) async throws -> Data {
        try await controller.perform { context in
            context.reset()
            return try StoredRecords.referenceFingerprint(snapshotID: snapshotID, in: context)
        }
    }
}

private final class ContentReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func check() throws {
        if lock.withLock({ isCancelled }) {
            throw CancellationError()
        }
    }
}
