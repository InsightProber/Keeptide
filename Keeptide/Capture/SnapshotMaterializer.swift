import AppKit

/// Called only on the owning process's main thread.
enum SnapshotMaterializer {
    static func read(pasteboard: NSPasteboard, sourceApp: String?, expectedChangeCount: Int? = nil) throws -> CaptureSnapshotValue {
        if pasteboard.accessBehavior == .alwaysDeny {
            throw SnapshotReaderError.permissionDenied
        }

        let initialChangeCount = pasteboard.changeCount
        if let expectedChangeCount, expectedChangeCount != initialChangeCount {
            throw SnapshotReaderError.changedDuringRead(expected: expectedChangeCount, actual: initialChangeCount)
        }
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            throw SnapshotReaderError.emptyPasteboard
        }

        let allTypeIdentifiers = pasteboardItems.flatMap { item in
            item.types.map(\.rawValue)
        }
        guard allTypeIdentifiers.allSatisfy(CapturePolicy.isSafeTypeIdentifier) else {
            throw SnapshotReaderError.unsupportedType
        }
        guard CapturePolicy.decision(
            typeIdentifiers: allTypeIdentifiers,
            sourceApp: nil,
            excludedSourceApps: []
        ) == .capture else {
            throw SnapshotReaderError.privacyRestricted
        }

        var totalBytes = 0
        var capturedItems: [CapturedPasteboardItem] = []
        capturedItems.reserveCapacity(pasteboardItems.count)

        for (itemIndex, pasteboardItem) in pasteboardItems.enumerated() {
            let capturedTypes = pasteboardItem.types.filter {
                $0.rawValue != CaptureWire.ownWriteTypeIdentifier
            }
            guard !capturedTypes.isEmpty else {
                throw SnapshotReaderError.emptyPasteboard
            }

            var representations: [CapturedRepresentation] = []
            representations.reserveCapacity(capturedTypes.count)
            for type in capturedTypes {
                guard let bytes = pasteboardItem.data(forType: type) else {
                    let currentChangeCount = pasteboard.changeCount
                    if currentChangeCount != initialChangeCount {
                        throw SnapshotReaderError.changedDuringRead(
                            expected: initialChangeCount,
                            actual: currentChangeCount
                        )
                    }
                    throw SnapshotReaderError.incompleteRepresentation(
                        itemIndex: itemIndex,
                        typeIdentifier: type.rawValue
                    )
                }
                guard bytes.count <= CaptureWire.maximumPayloadBytes - totalBytes else {
                    throw SnapshotReaderError.payloadTooLarge(maximumBytes: CaptureWire.maximumPayloadBytes)
                }
                totalBytes += bytes.count
                representations.append(CapturedRepresentation(typeIdentifier: type.rawValue, bytes: bytes))
            }
            capturedItems.append(CapturedPasteboardItem(representations: representations))
        }

        let finalChangeCount = pasteboard.changeCount
        guard finalChangeCount == initialChangeCount else {
            throw SnapshotReaderError.changedDuringRead(
                expected: initialChangeCount,
                actual: finalChangeCount
            )
        }

        return CaptureSnapshotValue(
            items: capturedItems,
            changeCount: finalChangeCount,
            sourceApp: sourceApp
        )
    }
}
