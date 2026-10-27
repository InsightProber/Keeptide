import Foundation
import Observation

enum CaptureMonitorState: Equatable {
    case stopped, recording, reading, pausing
    case skipped(String), failed(String)

    var message: String {
        switch self {
        case .stopped: "Not recording"
        case .recording: "Recording"
        case .reading: "Reading new copy…"
        case .pausing: "Pausing… finishing the current operation"
        case .skipped(let message), .failed(let message): message
        }
    }
}

@MainActor @Observable
final class PasteboardMonitor {
    private(set) var state: CaptureMonitorState = .stopped
    var status: String { state.message }
    var isPausing: Bool { state == .pausing }
    var isRecording: Bool {
        guard preferences.isEnabled, !stopping else { return false }
        switch state { case .recording, .reading, .skipped: return true; default: return false }
    }
    private struct CopyObservation { let count: Int; let source: String? }
    @ObservationIgnored private let reader: any SnapshotReading
    @ObservationIgnored private let service: CaptureService
    @ObservationIgnored private let preferences: CapturePreferences
    @ObservationIgnored private let sourceApp: () -> String?
    @ObservationIgnored private let matchesOwnWrite: (OwnWriteToken) -> Bool
    @ObservationIgnored private var observedCount: Int
    @ObservationIgnored private var processedCount: Int
    @ObservationIgnored private var observedSource: String?
    @ObservationIgnored private var pending: CopyObservation?
    @ObservationIgnored private var active: CopyObservation?
    @ObservationIgnored private var permit: CapturePermit?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var enabled: Bool
    @ObservationIgnored private var ownWrite: OwnWriteToken?
    @ObservationIgnored var onCapture: (() async -> Void)?
    @ObservationIgnored var onUnavailable: (() -> Void)?

    init(reader: any SnapshotReading, service: CaptureService, preferences: CapturePreferences,
         sourceApp: @escaping () -> String?, matchesOwnWrite: @escaping (OwnWriteToken) -> Bool) {
        self.reader = reader; self.service = service; self.preferences = preferences
        self.sourceApp = sourceApp; self.matchesOwnWrite = matchesOwnWrite
        observedCount = reader.changeCount; processedCount = observedCount
        observedSource = sourceApp(); enabled = preferences.isEnabled
        state = enabled ? .recording : .stopped
        preferences.onChange = { [weak self] in self?.preferencesChanged() }
    }

    isolated deinit { pollingTask?.cancel(); captureTask?.cancel(); permit?.revoke() }

    func start() { started = true; stopping = false; updatePolling() }

    func stop() {
        started = false; stopping = true
        pollingTask?.cancel(); pollingTask = nil
        permit?.revoke(); captureTask?.cancel()
        state = captureTask == nil ? .stopped : .pausing
    }

    func stopAndDrain() async {
        stop()
        await captureTask?.value
        state = .stopped
    }

    func suppressOwnWrite(_ token: OwnWriteToken) { ownWrite = token }

    // Sample at the workspace notification boundary, before replacing the old
    // foreground identity. Attribution remains observational, never authenticated.
    func foregroundApplicationChanged(to bundleIdentifier: String?) {
        observe(count: reader.changeCount, source: observedSource)
        observedSource = bundleIdentifier
    }

    func poll() async {
        sampleAndStart()
        await captureTask?.value
    }

    private func observe(count: Int, source: String?) {
        guard count != observedCount else { return }
        observedCount = count
        pending = CopyObservation(count: count, source: source)
        if let active, active.count != count { permit?.revoke(); captureTask?.cancel() }
    }

    private func sampleAndStart() {
        guard !stopping, preferences.isEnabled else { return }
        if case .failed = state { return }
        let source = sourceApp()
        if source != observedSource { foregroundApplicationChanged(to: source) }
        observe(count: reader.changeCount, source: observedSource)
        guard captureTask == nil, let observation = pending,
              observation.count != processedCount else { return }
        pending = nil
        processedCount = observation.count
        if let token = ownWrite {
            ownWrite = nil
            if token.changeCount == observation.count, matchesOwnWrite(token) {
                state = .recording
                return
            }
        }
        guard sourceIsAllowed(observation.source) else {
            state = .skipped("Recording · ignored or unknown source skipped")
            return
        }
        let admission = CapturePermit()
        permit = admission; active = observation; state = .reading
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.process(observation, admission: admission)
            self.captureTask = nil; self.active = nil; self.permit = nil
            if self.state == .pausing || self.state == .reading {
                self.state = !self.stopping && self.preferences.isEnabled ? .recording : .stopped
            }
        }
    }

    private func sourceIsAllowed(_ source: String?) -> Bool {
        if source == nil && !preferences.excludedApplications.isEmpty { return false }
        return CapturePolicy.decision(typeIdentifiers: [], sourceApp: source,
            excludedSourceApps: Set(preferences.excludedApplications)) == .capture
    }

    private func process(_ observation: CopyObservation, admission: CapturePermit) async {
        do {
            let snapshot = try await reader.readAsynchronously(sourceApp: observation.source, expectedChangeCount: observation.count)
            guard snapshot.changeCount == observation.count else { throw CaptureError.staleSnapshot }
            _ = try await service.capture(snapshot, permit: admission, isCurrent: { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return !self.stopping && self.preferences.isEnabled && admission.isValid
                        && self.reader.changeCount == observation.count
                        && self.sourceIsAllowed(observation.source)
                }
            })
            if !stopping && preferences.isEnabled { state = .recording }
            await onCapture?()
        } catch {
            // Pause, shutdown and replacement own the final state, including when
            // a provider reports a late error after its permission was revoked.
            guard admission.isValid, !Task.isCancelled, !stopping, preferences.isEnabled else { return }
            if error is CancellationError || error as? CaptureError == .staleSnapshot {
                state = .recording
            } else if let error = error as? SnapshotReaderError {
                handle(error)
            } else if let error = error as? CaptureError,
                      [.emptySnapshot, .privacyRestricted, .oversized].contains(error) {
                state = .skipped("Recording · unsupported or private copy skipped")
            } else {
                pollingTask?.cancel(); pollingTask = nil
                state = .failed("The local library is unavailable. Reopen Keeptide to retry.")
                onUnavailable?()
            }
        }
    }

    private func handle(_ error: SnapshotReaderError) {
        switch error {
        case .permissionDenied:
            preferences.isEnabled = false
            state = .failed("Clipboard access denied. Allow Keeptide in System Settings, then resume recording.")
        case .privacyRestricted: state = .skipped("Recording · private content skipped")
        case .unsupportedType: state = .skipped("Skipped copy with an unsupported format identifier")
        case .payloadTooLarge: state = .skipped("Skipped copy larger than 50 MiB")
        case .emptyPasteboard: state = .skipped("Recording · no readable content")
        case .changedDuringRead: state = .skipped("Recording · clipboard changed during reading")
        case .incompleteRepresentation: state = .skipped("Skipped copy with an unavailable format")
        case .readerUnavailable: state = .skipped("Clipboard reader stopped. Copy the content again to retry.")
        case .readTimedOut: state = .skipped("Clipboard reader timed out. Copy the content again to retry.")
        }
    }

    private func preferencesChanged() {
        if enabled != preferences.isEnabled {
            enabled = preferences.isEnabled
            permit?.revoke(); captureTask?.cancel()
            observedCount = reader.changeCount; processedCount = observedCount; pending = nil
            observedSource = sourceApp()
            state = !enabled && captureTask != nil ? .pausing : (enabled ? .recording : .stopped)
        } else if let active, !sourceIsAllowed(active.source) {
            permit?.revoke(); captureTask?.cancel()
            state = .skipped("Recording · ignored app skipped")
        }
        updatePolling()
    }

    private func updatePolling() {
        guard started, preferences.isEnabled, !stopping else {
            pollingTask?.cancel(); pollingTask = nil
            return
        }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.sampleAndStart()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}
