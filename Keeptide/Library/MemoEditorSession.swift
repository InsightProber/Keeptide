import Foundation
import Observation

enum MemoEditorSaveStatus: Equatable, Sendable {
    case clean
    case saving
    case saved
    case failed
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

    @ObservationIgnored private(set) var conflictItemID: ItemID
    @ObservationIgnored private(set) var storeIdentity: StoreIdentity
    @ObservationIgnored private(set) var baseMemoFingerprint: Data?
    @ObservationIgnored private(set) var languageHint: String?
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
        onChange: (() -> Void)? = nil
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

    func setNote(_ value: String, isComposing: Bool = false) {
        guard !isReadOnly, note != value || noteIsComposing != isComposing else { return }
        note = value
        noteIsComposing = isComposing
        didEdit()
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
