import Foundation

enum DraftStoreError: Error, Equatable {
    case corruptDraft(UUID)
    case unsupportedSchema(Int)
    case storeIdentityMismatch
    case staleRevision
}

struct RecoverableDraft: Codable, Equatable, Sendable {
    var draftID: UUID
    var sessionID: UUID
    var itemID: ItemID
    /// Stable destination for a conflict copy, reused across retries.
    var conflictItemID: ItemID
    var storeIdentity: StoreIdentity
    var base: ContentRef?
    var baseMemoFingerprint: Data?
    var title: String
    /// Nil means metadata-only editing for content that cannot be safely converted to text.
    var body: String?
    var kind: MemoKind
    var languageHint: String?
    var note: String
    var isComposing: Bool
    /// Monotonic disk CAS generation, independent from the caller's edit sequence.
    var storageRevision: UInt64 = 1
    var revision: UInt64
    var savedAt: Date
    /// Captured when a new-draft session opens; nil means uncategorized.
    var collectionID: CollectionID? = nil
}

struct DraftRestoreResult: Equatable, Sendable {
    var drafts: [RecoverableDraft]
    var failedIDs: [UUID]
}

protocol DraftStoring: Sendable {
    func write(_ draft: RecoverableDraft) async throws
    func load(_ id: UUID) async throws -> RecoverableDraft?
    func loadAll() async throws -> [RecoverableDraft]
    func loadAllBestEffort() async throws -> DraftRestoreResult
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool
    func releaseRetiredRevision(_ id: UUID, through storageRevision: UInt64) async
}

extension DraftStoring {
    func releaseRetiredRevision(_: UUID, through _: UInt64) async {}

    func loadAllBestEffort() async throws -> DraftRestoreResult {
        DraftRestoreResult(drafts: try await loadAll(), failedIDs: [])
    }
}

actor DraftStore: DraftStoring {
    private static let schemaVersion = 1
    private let directory: URL
    private let identity: StoreIdentity
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// In-memory fence for the single coordinator that owns this draft directory.
    private var retiredRevisions: [UUID: UInt64] = [:]

    init(directory: URL, identity: StoreIdentity) throws {
        self.directory = directory
        self.identity = identity
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: try container.decode(UInt64.self)))
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    nonisolated func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func write(_ draft: RecoverableDraft) async throws {
        guard draft.storeIdentity == identity else { throw DraftStoreError.storeIdentityMismatch }
        if let retired = retiredRevisions[draft.draftID], draft.storageRevision <= retired {
            throw DraftStoreError.staleRevision
        }
        if let previous = try loadFromDisk(draft.draftID) {
            guard previous.storeIdentity == identity else { throw DraftStoreError.storeIdentityMismatch }
            guard draft.storageRevision >= previous.storageRevision else { throw DraftStoreError.staleRevision }
            if draft.storageRevision == previous.storageRevision, draft != previous {
                throw DraftStoreError.staleRevision
            }
        }
        let data = try encoder.encode(DraftEnvelope(schemaVersion: Self.schemaVersion, draft: draft))
        let destination = fileURL(for: draft.draftID)
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func load(_ id: UUID) async throws -> RecoverableDraft? {
        try loadFromDisk(id)
    }

    private func loadFromDisk(_ id: UUID) throws -> RecoverableDraft? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw error
        }
        let schema: Int
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["schemaVersion"] as? NSNumber else {
                throw DraftStoreError.corruptDraft(id)
            }
            schema = value.intValue
        } catch let error as DraftStoreError {
            throw error
        } catch {
            throw DraftStoreError.corruptDraft(id)
        }
        guard schema == Self.schemaVersion else { throw DraftStoreError.unsupportedSchema(schema) }
        let envelope: DraftEnvelope
        do {
            envelope = try decoder.decode(DraftEnvelope.self, from: data)
        } catch {
            throw DraftStoreError.corruptDraft(id)
        }
        guard envelope.draft.draftID == id else { throw DraftStoreError.corruptDraft(id) }
        guard envelope.draft.storeIdentity == identity else { throw DraftStoreError.storeIdentityMismatch }
        return envelope.draft
    }

    func loadAll() async throws -> [RecoverableDraft] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension == "json" }
        var drafts: [RecoverableDraft] = []
        drafts.reserveCapacity(urls.count)
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            guard let draft = try loadFromDisk(id) else { continue }
            drafts.append(draft)
        }
        return drafts.sorted { $0.draftID.uuidString < $1.draftID.uuidString }
    }

    func loadAllBestEffort() async throws -> DraftRestoreResult {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension == "json" }
        var drafts: [RecoverableDraft] = []
        var failedIDs: [UUID] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                if let draft = try loadFromDisk(id) { drafts.append(draft) }
            } catch {
                failedIDs.append(id)
            }
        }
        return DraftRestoreResult(
            drafts: drafts.sorted { $0.draftID.uuidString < $1.draftID.uuidString },
            failedIDs: failedIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        guard let current = try loadFromDisk(id) else { return false }
        guard current.storageRevision == ifStorageRevision else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            retiredRevisions[id] = max(retiredRevisions[id] ?? 0, ifStorageRevision)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return false
        }
    }

    func releaseRetiredRevision(_ id: UUID, through storageRevision: UInt64) async {
        guard let retired = retiredRevisions[id], retired <= storageRevision else { return }
        retiredRevisions.removeValue(forKey: id)
    }
}

private struct DraftEnvelope: Codable {
    let schemaVersion: Int
    let draft: RecoverableDraft
}
