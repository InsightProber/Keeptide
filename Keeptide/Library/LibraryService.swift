import Foundation

struct LibraryService: Sendable {
    let controller: PersistenceController

    func saveAsMemo(
        _ itemID: ItemID, expecting expectedIdentity: StoreIdentity? = nil
    ) async throws -> SaveMemoOutcome {
        let identity = try await operationIdentity(expectedIdentity)
        let repository = ContentRepository(controller: controller)
        let itemState = try await repository.recordState(.item(itemID))
        guard case .item(var item) = itemState.value, item.deletedAt == nil else {
            throw StoreError.staleReference
        }
        if item.memoID != nil {
            let existing = try await currentMemoState(itemID: itemID).ref
            try await validateIdentity(identity)
            return .existing(existing)
        }

        let historyRef = try await currentHistoryRef(item: item, repository: repository)
        let content = try await repository.read(historyRef)
        guard content.integrity == .complete else { throw StoreError.staleReference }
        let extracted = try MemoTextExtractor.editableText(from: content)
        let memo = MemoValue(
            itemID: itemID, bodyMode: .inheritedCapture,
            sourceRepresentationType: extracted?.sourceRepresentationType,
            displayKind: MemoKind.plainText.rawValue
        )
        item.memoID = memo.id
        do {
            _ = try await writer.commit(StoreTransaction(
                identity: identity,
                preconditions: [
                    .recordUnchanged(.item(itemID), fingerprint: itemState.fingerprint),
                    .contentVersion(historyRef),
                    .facetVisible(itemID, .memo, false),
                ],
                mutations: [.insert(.memo(memo)), .update(.item(item))]
            ))
            return .created(ContentRef(
                itemID: itemID, facet: .memo,
                version: historyRef.version, digest: historyRef.digest
            ))
        } catch StoreError.preconditionFailed {
            do {
                let existing = try await currentMemoState(itemID: itemID).ref
                try await validateIdentity(identity)
                return .existing(existing)
            } catch {
                try await validateIdentity(identity)
                throw StoreError.preconditionFailed
            }
        }
    }

    func create(
        _ draft: MemoDraft, expecting expectedIdentity: StoreIdentity? = nil
    ) async throws -> ContentRef {
        let identity = try await operationIdentity(expectedIdentity)
        guard !isBlank(draft.title) || !isBlank(draft.body) || !isBlank(draft.note) else {
            throw LibraryServiceError.invalidDraft
        }
        if let existing = try await retryEquivalentRef(for: draft, identity: identity) { return existing }
        let collectionPrecondition = activeCollectionPrecondition(draft.collectionID)

        let body = Data(draft.body.utf8)
        let version = ContentVersion()
        let digest = ContentDigest.sha256(body)
        let memo = MemoValue(
            itemID: draft.itemID, title: draft.title, bodyMode: draft.kind.bodyMode,
            body: body, version: version, digest: digest, languageHint: draft.languageHint,
            note: draft.note, displayKind: draft.kind.rawValue
        )
        let item = ItemValue(id: draft.itemID, memoID: memo.id, collectionID: draft.collectionID)
        var preconditions: [StorePrecondition] = [
            .absent(.item(draft.itemID)),
            .absent(.memo(memo.id)),
        ]
        if let collectionPrecondition { preconditions.append(collectionPrecondition) }
        do {
            _ = try await writer.commit(StoreTransaction(
                identity: identity,
                preconditions: preconditions,
                mutations: [.insert(.memo(memo)), .insert(.item(item))]
            ))
            return ContentRef(itemID: draft.itemID, facet: .memo, version: version, digest: digest)
        } catch StoreError.preconditionFailed {
            if let existing = try await retryEquivalentRef(for: draft, identity: identity) { return existing }
            try await validateIdentity(identity)
            throw StoreError.preconditionFailed
        }
    }

    func commit(
        _ edit: MemoEdit, base: ContentRef, expecting expectedIdentity: StoreIdentity? = nil
    ) async throws -> CommitOutcome {
        let identity = try await operationIdentity(expectedIdentity)
        guard base.facet == .memo else { throw StoreError.staleReference }
        let state = try await currentMemoState(itemID: base.itemID)
        if state.memoFingerprint != edit.expectedMemoFingerprint {
            if try await alreadyReflects(edit, state: state) {
                try await validateIdentity(identity)
                return .updated(state.ref)
            }
            return try await conflictCopy(edit, state: state, identity: identity)
        }
        guard state.ref == base else { throw StoreError.staleReference }

        var updated = state.memo
        updated.title = edit.title
        updated.languageHint = edit.languageHint
        updated.note = edit.note
        if let bodyText = edit.body {
            if state.memo.bodyMode == .inheritedCapture {
                guard try MemoTextExtractor.editableText(from: state.content) != nil else {
                    throw LibraryServiceError.contentNotEditable
                }
            }
            let kind = edit.kind ?? kind(for: state.memo)
            let bytes = Data(bodyText.utf8)
            let bodyChanged = state.memo.bodyMode == .inheritedCapture
                || state.memo.bodyMode != kind.bodyMode
                || state.memo.body != bytes
            updated.bodyMode = kind.bodyMode
            updated.body = bytes
            updated.digest = ContentDigest.sha256(bytes)
            updated.displayKind = kind.rawValue
            if bodyChanged { updated.version = ContentVersion() }
        } else if let kind = edit.kind {
            updated.displayKind = kind.rawValue
        }

        guard updated != state.memo else {
            try await validateIdentity(identity)
            return .unchanged(state.ref)
        }
        let resultRef = try await ref(
            for: updated, item: state.item, repository: ContentRepository(controller: controller)
        )
        do {
            _ = try await writer.commit(StoreTransaction(
                identity: identity,
                preconditions: [
                    .recordUnchanged(.memo(state.memo.id), fingerprint: state.memoFingerprint),
                    .contentVersion(state.ref),
                ],
                mutations: [.update(.memo(updated))]
            ))
            return .updated(resultRef)
        } catch StoreError.preconditionFailed {
            try await validateIdentity(identity)
            let latest = try await currentMemoState(itemID: base.itemID)
            if try await alreadyReflects(edit, state: latest) {
                try await validateIdentity(identity)
                return .updated(latest.ref)
            }
            guard latest.memoFingerprint != edit.expectedMemoFingerprint else {
                throw StoreError.preconditionFailed
            }
            return try await conflictCopy(edit, state: latest, identity: identity)
        }
    }

    func duplicate(
        _ ref: ContentRef,
        stableItemID: ItemID = ItemID(),
        expecting expectedIdentity: StoreIdentity? = nil
    ) async throws -> ContentRef {
        let identity = try await operationIdentity(expectedIdentity)
        guard ref.facet == .memo else { throw StoreError.staleReference }
        let state = try await currentMemoState(itemID: ref.itemID)
        guard state.ref == ref else { throw StoreError.staleReference }
        if state.memo.bodyMode == .inheritedCapture {
            return try await inheritedCopy(
                itemID: stableItemID, title: state.memo.title,
                displayKind: state.memo.displayKind, languageHint: state.memo.languageHint,
                note: state.memo.note, source: state, identity: identity
            )
        }
        let snapshot = try editingSnapshot(state)
        guard let body = snapshot.body else { throw LibraryServiceError.contentNotEditable }
        return try await create(MemoDraft(
            itemID: stableItemID, title: snapshot.title, body: body, kind: snapshot.kind,
            languageHint: snapshot.languageHint, note: snapshot.note
        ), expecting: identity)
    }

    func editingSnapshot(_ ref: ContentRef) async throws -> MemoEditingSnapshot {
        guard ref.facet == .memo else { throw StoreError.staleReference }
        let state = try await currentMemoState(itemID: ref.itemID)
        guard state.ref == ref else { throw StoreError.staleReference }
        return try editingSnapshot(state)
    }

    private var writer: WriteCoordinator { WriteCoordinator(controller: controller) }

    private func currentHistoryRef(item: ItemValue, repository: ContentRepository) async throws -> ContentRef {
        guard item.historyEligible, item.historyDeletedAt == nil, let captureID = item.captureID else {
            throw StoreError.staleReference
        }
        return try await captureRef(
            itemID: item.id, captureID: captureID, facet: .history, repository: repository
        )
    }

    private func captureRef(
        itemID: ItemID, captureID: UUID, facet: ContentFacet, repository: ContentRepository
    ) async throws -> ContentRef {
        let captureState = try await repository.recordState(.capture(captureID))
        guard case .capture(let capture) = captureState.value else { throw StoreError.corruptStore }
        return ContentRef(
            itemID: itemID, facet: facet, version: ContentVersion(rawValue: captureID), digest: capture.digest
        )
    }

    private func currentMemoState(itemID: ItemID) async throws -> CurrentMemoState {
        let repository = ContentRepository(controller: controller)
        do {
            let itemState = try await repository.recordState(.item(itemID))
            guard case .item(let item) = itemState.value,
                  item.deletedAt == nil, let memoID = item.memoID else {
                throw StoreError.staleReference
            }
            let memoState = try await repository.recordState(.memo(memoID))
            guard case .memo(let memo) = memoState.value,
                  memo.itemID == itemID, memo.deletedAt == nil else {
                throw StoreError.staleReference
            }
            let currentRef = try await ref(for: memo, item: item, repository: repository)
            let content = try await repository.read(currentRef)
            guard content.integrity == .complete else { throw StoreError.staleReference }
            return CurrentMemoState(
                item: item, memo: memo, memoFingerprint: memoState.fingerprint,
                ref: currentRef, content: content
            )
        } catch StoreError.notFound {
            throw StoreError.staleReference
        }
    }

    private func ref(
        for memo: MemoValue, item: ItemValue, repository: ContentRepository
    ) async throws -> ContentRef {
        switch memo.bodyMode {
        case .inheritedCapture:
            guard let captureID = item.captureID else { throw StoreError.corruptStore }
            return try await captureRef(
                itemID: item.id, captureID: captureID, facet: .memo, repository: repository
            )
        case .ownedPlainText, .ownedMarkdown:
            guard let version = memo.version, let digest = memo.digest else { throw StoreError.corruptStore }
            return ContentRef(itemID: item.id, facet: .memo, version: version, digest: digest)
        }
    }

    private func editingSnapshot(_ state: CurrentMemoState) throws -> MemoEditingSnapshot {
        let body: String?
        switch state.memo.bodyMode {
        case .inheritedCapture:
            body = try MemoTextExtractor.editableText(from: state.content)?.text
        case .ownedPlainText, .ownedMarkdown:
            guard let bytes = state.memo.body, let decoded = String(data: bytes, encoding: .utf8) else {
                throw StoreError.corruptStore
            }
            body = decoded
        }
        return MemoEditingSnapshot(
            ref: state.ref, itemID: state.item.id, memoID: state.memo.id,
            title: state.memo.title, body: body, bodyMode: state.memo.bodyMode,
            kind: kind(for: state.memo), languageHint: state.memo.languageHint,
            note: state.memo.note, memoFingerprint: state.memoFingerprint
        )
    }

    private func kind(for memo: MemoValue) -> MemoKind {
        if let raw = memo.displayKind, let kind = MemoKind(rawValue: raw) { return kind }
        if memo.bodyMode == .ownedMarkdown { return .markdown }
        if memo.languageHint != nil { return .code }
        return .plainText
    }

    private func conflictCopy(
        _ edit: MemoEdit, state: CurrentMemoState, identity: StoreIdentity
    ) async throws -> CommitOutcome {
        if edit.body == nil, state.memo.bodyMode == .inheritedCapture {
            return .conflictCopy(try await inheritedCopy(
                itemID: edit.conflictItemID, title: edit.title,
                displayKind: edit.kind?.rawValue ?? state.memo.displayKind,
                languageHint: edit.languageHint, note: edit.note, source: state, identity: identity
            ))
        }
        if edit.body != nil, state.memo.bodyMode == .inheritedCapture,
           try MemoTextExtractor.editableText(from: state.content) == nil {
            throw LibraryServiceError.contentNotEditable
        }
        let snapshot = try editingSnapshot(state)
        guard let body = edit.body ?? snapshot.body else { throw LibraryServiceError.contentNotEditable }
        return .conflictCopy(try await create(MemoDraft(
            itemID: edit.conflictItemID, title: edit.title, body: body,
            kind: edit.kind ?? snapshot.kind, languageHint: edit.languageHint, note: edit.note,
            collectionID: state.item.collectionID
        ), expecting: identity))
    }

    private func inheritedCopy(
        itemID: ItemID,
        title: String,
        displayKind: String?,
        languageHint: String?,
        note: String,
        source: CurrentMemoState,
        identity: StoreIdentity
    ) async throws -> ContentRef {
        guard let captureID = source.item.captureID else { throw StoreError.corruptStore }
        if let existing = try await retryEquivalentInheritedRef(
            itemID: itemID, captureID: captureID, title: title,
            displayKind: displayKind, sourceRepresentationType: source.memo.sourceRepresentationType,
            languageHint: languageHint, note: note, collectionID: source.item.collectionID,
            identity: identity
        ) {
            return existing
        }

        let memo = MemoValue(
            itemID: itemID, title: title, bodyMode: .inheritedCapture,
            sourceRepresentationType: source.memo.sourceRepresentationType,
            languageHint: languageHint, note: note, displayKind: displayKind
        )
        let item = ItemValue(
            id: itemID, captureID: captureID, memoID: memo.id,
            collectionID: source.item.collectionID
        )
        var preconditions: [StorePrecondition] = [
            .contentVersion(source.ref),
            .recordUnchanged(.memo(source.memo.id), fingerprint: source.memoFingerprint),
            .exists(.capture(captureID)),
            .absent(.item(itemID)),
            .absent(.memo(memo.id)),
        ]
        if let collectionPrecondition = activeCollectionPrecondition(source.item.collectionID) {
            preconditions.append(collectionPrecondition)
        }
        do {
            _ = try await writer.commit(StoreTransaction(
                identity: identity,
                preconditions: preconditions,
                mutations: [.insert(.memo(memo)), .insert(.item(item))]
            ))
            return try await ref(
                for: memo, item: item, repository: ContentRepository(controller: controller)
            )
        } catch StoreError.preconditionFailed {
            if let existing = try await retryEquivalentInheritedRef(
                itemID: itemID, captureID: captureID, title: title,
                displayKind: displayKind, sourceRepresentationType: source.memo.sourceRepresentationType,
                languageHint: languageHint, note: note, collectionID: source.item.collectionID,
                identity: identity
            ) {
                return existing
            }
            try await validateIdentity(identity)
            throw StoreError.preconditionFailed
        }
    }

    private func retryEquivalentInheritedRef(
        itemID: ItemID,
        captureID: UUID,
        title: String,
        displayKind: String?,
        sourceRepresentationType: String?,
        languageHint: String?,
        note: String,
        collectionID: CollectionID?,
        identity: StoreIdentity
    ) async throws -> ContentRef? {
        let repository = ContentRepository(controller: controller)
        let itemState: RecordState
        do {
            itemState = try await repository.recordState(.item(itemID))
        } catch StoreError.notFound {
            return nil
        }
        guard case .item(let item) = itemState.value,
              item.deletedAt == nil, item.captureID == captureID,
              !item.historyEligible, item.historyDeletedAt == nil,
              item.collectionID == collectionID,
              let memoID = item.memoID else {
            try await validateIdentity(identity)
            throw LibraryServiceError.stableIdentityCollision
        }
        let memoState: RecordState
        do {
            memoState = try await repository.recordState(.memo(memoID))
        } catch StoreError.notFound {
            try await validateIdentity(identity)
            throw LibraryServiceError.stableIdentityCollision
        }
        guard case .memo(let memo) = memoState.value,
              memo.itemID == itemID, memo.deletedAt == nil,
              memo.title == title, memo.bodyMode == .inheritedCapture,
              memo.sourceRepresentationType == sourceRepresentationType,
              memo.body == nil, memo.version == nil, memo.digest == nil,
              memo.languageHint == languageHint, memo.displayKind == displayKind,
              memo.note == note else {
            try await validateIdentity(identity)
            throw LibraryServiceError.stableIdentityCollision
        }
        let currentRef = try await ref(for: memo, item: item, repository: repository)
        let content = try await repository.read(currentRef)
        guard content.integrity == .complete else { throw StoreError.staleReference }
        try await validateIdentity(identity)
        return currentRef
    }

    private func alreadyReflects(_ edit: MemoEdit, state: CurrentMemoState) async throws -> Bool {
        guard state.memo.title == edit.title,
              state.memo.languageHint == edit.languageHint,
              state.memo.note == edit.note else { return false }
        if let kind = edit.kind, state.memo.displayKind != kind.rawValue { return false }
        guard let body = edit.body else { return true }
        let expectedKind = edit.kind ?? kind(for: state.memo)
        return state.memo.bodyMode == expectedKind.bodyMode && state.memo.body == Data(body.utf8)
    }

    private func retryEquivalentRef(
        for draft: MemoDraft, identity: StoreIdentity
    ) async throws -> ContentRef? {
        let repository = ContentRepository(controller: controller)
        let itemState: RecordState
        do {
            itemState = try await repository.recordState(.item(draft.itemID))
        } catch StoreError.notFound {
            return nil
        }
        guard case .item(let item) = itemState.value,
              item.deletedAt == nil, item.captureID == nil, !item.historyEligible,
              item.historyDeletedAt == nil, item.collectionID == draft.collectionID,
              let memoID = item.memoID else {
            try await validateIdentity(identity)
            throw LibraryServiceError.stableIdentityCollision
        }
        let memoState: RecordState
        do {
            memoState = try await repository.recordState(.memo(memoID))
        } catch StoreError.notFound {
            try await validateIdentity(identity)
            throw LibraryServiceError.stableIdentityCollision
        }
        let bytes = Data(draft.body.utf8)
        guard case .memo(let memo) = memoState.value,
              memo.itemID == draft.itemID, memo.deletedAt == nil,
              memo.title == draft.title, memo.bodyMode == draft.kind.bodyMode,
              memo.body == bytes, memo.digest == ContentDigest.sha256(bytes),
              memo.languageHint == draft.languageHint, memo.displayKind == draft.kind.rawValue,
              memo.note == draft.note else {
            try await validateIdentity(identity)
            throw LibraryServiceError.stableIdentityCollision
        }
        let currentRef = try await ref(for: memo, item: item, repository: repository)
        try await validateIdentity(identity)
        return currentRef
    }

    private func activeCollectionPrecondition(
        _ collectionID: CollectionID?
    ) -> StorePrecondition? {
        collectionID.map(StorePrecondition.collectionActive)
    }

    private func operationIdentity(_ expected: StoreIdentity?) async throws -> StoreIdentity {
        let current = try await controller.identity()
        guard expected == nil || expected == current else { throw StoreError.preconditionFailed }
        return expected ?? current
    }

    private func validateIdentity(_ expected: StoreIdentity) async throws {
        guard try await controller.identity() == expected else { throw StoreError.preconditionFailed }
    }

    private func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct CurrentMemoState: Sendable {
    let item: ItemValue
    let memo: MemoValue
    let memoFingerprint: Data
    let ref: ContentRef
    let content: ResolvedContent
}
