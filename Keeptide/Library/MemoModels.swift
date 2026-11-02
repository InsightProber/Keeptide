import Foundation

enum MemoKind: String, Codable, Equatable, Sendable {
    case plainText
    case prompt
    case code
    case markdown

    var bodyMode: MemoBodyMode {
        self == .markdown ? .ownedMarkdown : .ownedPlainText
    }
}

struct MemoDraft: Codable, Equatable, Sendable {
    var itemID: ItemID
    var title: String
    var body: String
    var kind: MemoKind
    var languageHint: String?
    var note: String

    init(
        itemID: ItemID = ItemID(),
        title: String = "",
        body: String,
        kind: MemoKind = .plainText,
        languageHint: String? = nil,
        note: String = ""
    ) {
        self.itemID = itemID
        self.title = title
        self.body = body
        self.kind = kind
        self.languageHint = languageHint
        self.note = note
    }
}

struct MemoEdit: Codable, Equatable, Sendable {
    var title: String
    /// Nil keeps the current body and content version. An empty string is a real body edit.
    var body: String?
    var kind: MemoKind?
    var languageHint: String?
    var note: String
    var expectedMemoFingerprint: Data
    /// Stable across retries so a committed conflict copy is not duplicated after a crash.
    var conflictItemID: ItemID

    init(
        title: String,
        body: String? = nil,
        kind: MemoKind? = nil,
        languageHint: String? = nil,
        note: String = "",
        expectedMemoFingerprint: Data,
        conflictItemID: ItemID = ItemID()
    ) {
        self.title = title
        self.body = body
        self.kind = kind
        self.languageHint = languageHint
        self.note = note
        self.expectedMemoFingerprint = expectedMemoFingerprint
        self.conflictItemID = conflictItemID
    }
}

struct MemoExtractedText: Equatable, Sendable {
    var text: String
    var sourceRepresentationType: String
}

struct MemoEditingSnapshot: Equatable, Sendable {
    var ref: ContentRef
    var itemID: ItemID
    var memoID: UUID
    var title: String
    var body: String?
    var bodyMode: MemoBodyMode
    var kind: MemoKind
    var languageHint: String?
    var note: String
    var memoFingerprint: Data
}

enum SaveMemoOutcome: Equatable, Sendable {
    case created(ContentRef)
    case existing(ContentRef)

    var ref: ContentRef {
        switch self {
        case .created(let ref), .existing(let ref): ref
        }
    }
}

enum CommitOutcome: Equatable, Sendable {
    case updated(ContentRef)
    case unchanged(ContentRef)
    case conflictCopy(ContentRef)

    var ref: ContentRef {
        switch self {
        case .updated(let ref), .unchanged(let ref), .conflictCopy(let ref): ref
        }
    }
}

enum LibraryServiceError: Error, Equatable {
    case invalidDraft
    case contentNotEditable
    case stableIdentityCollision
}
