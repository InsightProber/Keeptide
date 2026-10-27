import Foundation
import Observation

@MainActor @Observable
final class PasteboardMonitor {
    private(set) var status = "Not recording"
    private(set) var isPausing = false
    @ObservationIgnored private let reader: any SnapshotReading
    @ObservationIgnored private let service: CaptureService
    @ObservationIgnored private let preferences: CapturePreferences
    @ObservationIgnored private let sourceApp: () -> String?
    @ObservationIgnored private let matchesOwnWrite: (OwnWriteToken) -> Bool
    @ObservationIgnored private var observedCount: Int
    @ObservationIgnored private var processedCount: Int
    @ObservationIgnored private var permit: CapturePermit?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isProcessing = false
    @ObservationIgnored private var ownWrite: OwnWriteToken?
    @ObservationIgnored var onCapture: (() async -> Void)?

    init(reader: any SnapshotReading, service: CaptureService, preferences: CapturePreferences,
         sourceApp: @escaping () -> String?, matchesOwnWrite: @escaping (OwnWriteToken) -> Bool) {
        self.reader = reader
        self.service = service
        self.preferences = preferences
        self.sourceApp = sourceApp
        self.matchesOwnWrite = matchesOwnWrite
        observedCount = reader.changeCount
        processedCount = reader.changeCount
        preferences.onChange = { [weak self] in self?.preferencesChanged() }
        preferencesChanged()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        permit?.revoke()
    }

    func suppressOwnWrite(_ token: OwnWriteToken) { ownWrite = token }

    func poll() async {
        let count = reader.changeCount
        if count != observedCount {
            permit?.revoke()
            observedCount = count
        }
        guard preferences.isEnabled else {
            processedCount = count
            return
        }
        guard !isProcessing, count != processedCount else { return }
        processedCount = count
        if let token = ownWrite {
            ownWrite = nil
            if token.changeCount == count, matchesOwnWrite(token) { return }
        }
        let source = sourceApp()
        guard CapturePolicy.decision(typeIdentifiers: [], sourceApp: source,
            isCaptureEnabled: true, isPaused: false,
            excludedSourceApps: Set(preferences.excludedApplications)) == .capture else {
            status = "Recording · ignored app skipped"
            return
        }
        isProcessing = true
        defer {
            isProcessing = false
            isPausing = false
            if status.hasPrefix("Pausing") { status = "Not recording" }
        }
        let admission = CapturePermit()
        permit = admission
        do {
            status = "Reading new copy…"
            let snapshot = try await reader.readAsynchronously(sourceApp: source)
            _ = try await service.capture(snapshot, permit: admission, isCurrent: { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return self.preferences.isEnabled && self.reader.changeCount == snapshot.changeCount
                        && admission.isValid
                }
            })
            if preferences.isEnabled { status = "Recording" }
            await onCapture?()
        } catch CaptureError.staleSnapshot {
            // A newer clipboard or a changed policy owns the next polling cycle.
        } catch let error as SnapshotReaderError {
            switch error {
            case .permissionDenied:
                preferences.isEnabled = false
                status = "Clipboard access denied. Allow Keeptide in System Settings, then resume recording."
            case .privacyRestricted: status = "Recording · private content skipped"
            case .unsupportedType: status = "Skipped copy with an unsupported format identifier"
            case .payloadTooLarge: status = "Skipped copy larger than 50 MiB"
            case .emptyPasteboard: status = "Recording · no readable content"
            case .changedDuringRead: status = "Recording · clipboard changed during reading"
            case .incompleteRepresentation: status = "Skipped copy with an unavailable format"
            }
        } catch {
            preferences.isEnabled = false
            status = "Recording paused because content could not be saved. Resume, then copy the content again."
        }
    }

    private func preferencesChanged() {
        permit?.revoke()
        observedCount = reader.changeCount
        processedCount = observedCount
        isPausing = isProcessing && !preferences.isEnabled
        status = isPausing ? "Pausing… finishing the current operation" : (preferences.isEnabled ? "Recording" : "Not recording")
    }
}
