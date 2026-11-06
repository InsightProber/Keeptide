import Foundation
import Observation

enum MemoEditorSaveStatus: Equatable, Sendable {
    case clean
    case saving
    case saved
    case failed
}

/// What the detail header and the inspector say about the item open in the editor. Read when the item opens and
/// again after a favorite or collection change; nothing here is edited in place.
struct LibraryItemDetails: Equatable, Sendable {
    /// Whether all of a clip's original formats can be read; a snippet's own text is always complete.
    var integrity: ContentIntegrity = .complete
    var formatCount = 0
    var byteCount: Int64 = 0
    var sourceApp: String?
    var createdAt: Date
    var lastCopiedAt: Date
    var copyCount: Int64
    /// A snippet's own collection and favorite mark.
    var collectionID: CollectionID?
    var isFavorite = false
    /// The snippet a clip was saved as.
    var savedSnippet: SavedSnippet?
    /// Where the clip a snippet was saved from is now; nil for a snippet written in Keeptide.
    var originalClip: OriginalClip?

    struct SavedSnippet: Equatable, Sendable {
        var ref: ContentRef
        var collectionID: CollectionID?
        var isFavorite: Bool
    }

    enum OriginalClip: Equatable, Sendable {
        case available(ContentRef)
        case recentlyDeleted(until: Date)
        case gone
    }
}

@MainActor @Observable
final class MemoEditorSession {
    let draftID: UUID
    let sessionID: UUID
    private(set) var itemID: ItemID
    private(set) var ref: ContentRef?
    private(set) var isReadOnly: Bool
    private(set) var title: String
    private(set) var body: String?
    private(set) var note: String
    private(set) var kind: MemoKind
    private(set) var status: MemoEditorSaveStatus
    private(set) var failureMessage: String?
    private(set) var isComposing: Bool
    private(set) var titleIsComposing: Bool
    private(set) var bodyIsComposing: Bool
    private(set) var noteIsComposing: Bool
    private(set) var revision: UInt64
    private(set) var richSourceWarning: Bool
    private(set) var details: LibraryItemDetails?

    @ObservationIgnored private(set) var conflictItemID: ItemID
    @ObservationIgnored private(set) var storeIdentity: StoreIdentity
    @ObservationIgnored private(set) var baseMemoFingerprint: Data?
    @ObservationIgnored private(set) var languageHint: String?
    /// The collection a new snippet is created in; it applies only until the first save.
    private(set) var collectionID: CollectionID?
    @ObservationIgnored private var onChange: (() -> Void)?
    @ObservationIgnored private var lastAppliedReceiptRevision: UInt64?

    init(
        draftID: UUID = UUID(),
        sessionID: UUID = UUID(),
        itemID: ItemID,
        ref: ContentRef?,
        isReadOnly: Bool,
        title: String,
        body: String?,
        note: String,
        kind: MemoKind,
        status: MemoEditorSaveStatus = .clean,
        isComposing: Bool = false,
        revision: UInt64 = 0,
        richSourceWarning: Bool = false,
        conflictItemID: ItemID = ItemID(),
        storeIdentity: StoreIdentity,
        baseMemoFingerprint: Data? = nil,
        languageHint: String? = nil,
        onChange: (() -> Void)? = nil,
        collectionID: CollectionID? = nil
    ) {
        self.draftID = draftID
        self.sessionID = sessionID
        self.itemID = itemID
        self.ref = ref
        self.isReadOnly = isReadOnly
        self.title = title
        self.body = body
        self.note = note
        self.kind = kind
        self.status = status
        failureMessage = nil
        self.isComposing = isComposing
        titleIsComposing = isComposing
        bodyIsComposing = isComposing
        noteIsComposing = false
        self.revision = revision
        self.richSourceWarning = richSourceWarning
        self.conflictItemID = conflictItemID
        self.storeIdentity = storeIdentity
        self.baseMemoFingerprint = baseMemoFingerprint
        self.languageHint = languageHint
        self.collectionID = collectionID
        self.onChange = onChange
        lastAppliedReceiptRevision = nil
    }

    func setTitle(_ value: String, isComposing: Bool = false) {
        guard !isReadOnly, title != value || titleIsComposing != isComposing else { return }
        title = value
        titleIsComposing = isComposing
        didEdit()
    }

    func setBody(_ value: String, isComposing: Bool) {
        guard !isReadOnly, body != value || bodyIsComposing != isComposing else { return }
        body = value
        bodyIsComposing = isComposing
        didEdit()
    }

    func updateDetails(_ value: LibraryItemDetails?) {
        details = value
    }

    func setNote(_ value: String, isComposing: Bool = false) {
        guard !isReadOnly, note != value || noteIsComposing != isComposing else { return }
        note = value
        noteIsComposing = isComposing
        didEdit()
    }

    /// Chooses the collection a new snippet is created in. A saved snippet moves through its collection instead.
    func setCollectionID(_ value: CollectionID?) {
        guard ref == nil, !isReadOnly else { return }
        collectionID = value
    }

    func setKind(_ value: MemoKind) {
        guard !isReadOnly, kind != value else { return }
        kind = value
        didEdit()
    }

    func attachChangeHandler(_ handler: @escaping () -> Void) {
        onChange = handler
    }

    func markSaved(_ receipt: MemoCommitReceipt, revision savedRevision: UInt64) {
        if let lastAppliedReceiptRevision, savedRevision < lastAppliedReceiptRevision { return }
        ref = receipt.ref
        itemID = receipt.ref.itemID
        baseMemoFingerprint = receipt.memoFingerprint
        lastAppliedReceiptRevision = savedRevision
        if savedRevision == revision {
            status = .saved
            failureMessage = nil
            richSourceWarning = false
        }
    }

    func markFailed(_ text: String, revision failedRevision: UInt64) {
        guard failedRevision >= revision else { return }
        status = .failed
        failureMessage = text
    }

    private func didEdit() {
        guard revision < UInt64.max else {
            status = .failed
            failureMessage = "This editor session has reached its revision limit."
            return
        }
        revision += 1
        isComposing = titleIsComposing || bodyIsComposing || noteIsComposing
        status = .saving
        failureMessage = nil
        onChange?()
    }
}
