import AppKit

extension CapturedRepresentation {
    var isLocalFileReference: Bool {
        SystemFileReferenceClassifier.isLocalFileReference(
            typeIdentifier: typeIdentifier,
            bytes: bytes
        )
    }
}

@MainActor
protocol SnapshotReading: AnyObject {
    var changeCount: Int { get }
    func readAsynchronously(sourceApp: String?, expectedChangeCount: Int) async throws -> CaptureSnapshotValue
}

@MainActor
final class SnapshotReader: SnapshotReading {
    nonisolated static let maximumPayloadBytes = CaptureWire.maximumPayloadBytes
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }

    func readAsynchronously(sourceApp: String?, expectedChangeCount: Int) async throws -> CaptureSnapshotValue {
        if pasteboard.accessBehavior == .alwaysDeny { throw SnapshotReaderError.permissionDenied }
        let count = pasteboard.changeCount
        guard count == expectedChangeCount else {
            throw SnapshotReaderError.changedDuringRead(expected: expectedChangeCount, actual: count)
        }
        let name = pasteboard.name.rawValue
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeeptidePasteboardReader")
        let operation = PasteboardReadOperation()
        let snapshot = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try operation.read(executable: executable, pasteboardName: name, expectedChangeCount: count)
            }.value
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        return CaptureSnapshotValue(items: snapshot.items, changeCount: snapshot.changeCount, sourceApp: sourceApp)
    }

    // Hermetic same-executor test entry; production uses the isolated helper.
    func read(sourceApp: String?) throws -> CaptureSnapshotValue {
        try SnapshotMaterializer.read(pasteboard: pasteboard, sourceApp: sourceApp)
    }
}
