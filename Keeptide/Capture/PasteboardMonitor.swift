import Foundation
import Observation

enum CaptureMonitorState: Equatable {
    /// Watching the clipboard, and keeping each new copy.
    case watching
    /// The last new copy could not be kept, for this reason: the system denies Keeptide the clipboard, the disk is full,
    /// or the copy could not be read whole or is too large. Watching goes on and each new copy is tried, and the reason
    /// holds until one is kept.
    case interrupted(String)
    /// The library takes no new copies until Keeptide reopens, for this reason, and the clipboard is no longer watched.
    case failed(String)
    /// No longer watching, as when the library closes.
    case stopped
}

@MainActor @Observable
final class PasteboardMonitor {
    private(set) var state: CaptureMonitorState = .watching
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
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var ownWrite: OwnWriteToken?
    @ObservationIgnored var onCapture: (() async -> Void)?
    @ObservationIgnored var onUnavailable: (() -> Void)?
    @ObservationIgnored var onStorageFull: (() async -> Void)?
    @ObservationIgnored private var retryAfter: ContinuousClock.Instant?

    /// What the clipboard already holds is never kept: only the copies made after this.
    init(reader: any SnapshotReading, service: CaptureService, preferences: CapturePreferences,
         sourceApp: @escaping () -> String?, matchesOwnWrite: @escaping (OwnWriteToken) -> Bool) {
        self.reader = reader; self.service = service; self.preferences = preferences
        self.sourceApp = sourceApp; self.matchesOwnWrite = matchesOwnWrite
        observedCount = reader.changeCount; processedCount = observedCount
        observedSource = sourceApp()
        preferences.onChange = { [weak self] in self?.preferencesChanged() }
    }

    isolated deinit { pollingTask?.cancel(); captureTask?.cancel(); permit?.revoke() }

    /// Watches the clipboard, sampling it four times a second.
    func start() {
        stopping = false
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.sampleAndStart()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    /// Stops watching, and lets go of the copy being read: nothing of it is kept.
    func stop() {
        stopping = true
        pollingTask?.cancel(); pollingTask = nil
        permit?.revoke(); captureTask?.cancel()
        state = .stopped
    }

    /// Stops, then waits for the copy being read to let go, so that the library can close after it.
    func stopAndDrain() async {
        stop()
        await captureTask?.value
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
        guard !stopping else { return }
        if case .failed = state { return }
        if let retryAfter, ContinuousClock.now < retryAfter { return }
        retryAfter = nil
        let source = sourceApp()
        if source != observedSource { foregroundApplicationChanged(to: source) }
        observe(count: reader.changeCount, source: observedSource)
        guard captureTask == nil, let observation = pending,
              observation.count != processedCount else { return }
        pending = nil
        processedCount = observation.count
        // Keeptide's own copy, from the library or quick access, is not a new copy.
        if let token = ownWrite {
            ownWrite = nil
            if token.changeCount == observation.count, matchesOwnWrite(token) { return }
        }
        // A copy from an ignored app, or from an unknown one while apps are ignored, is never read.
        guard sourceIsAllowed(observation.source) else { return }
        let admission = CapturePermit()
        permit = admission; active = observation
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.process(observation, admission: admission)
            self.captureTask = nil; self.active = nil; self.permit = nil
        }
    }

    private func sourceIsAllowed(_ source: String?) -> Bool {
        if source == nil && !preferences.excludedApplications.isEmpty { return false }
        return CapturePolicy.decision(typeIdentifiers: [], sourceApp: source,
            excludedSourceApps: Set(preferences.excludedApplications)) == .capture
    }

    /// Reads and keeps one new copy. A copy kept ends any interruption, and one that fails says why it was not kept. A
    /// copy Keeptide skips without a word, such as a private one, and one that a newer copy replaced, leave the state as
    /// it was.
    private func process(_ observation: CopyObservation, admission: CapturePermit) async {
        do {
            let snapshot = try await reader.readAsynchronously(sourceApp: observation.source, expectedChangeCount: observation.count)
            guard snapshot.changeCount == observation.count else { throw CaptureError.staleSnapshot }
            _ = try await service.capture(snapshot, permit: admission, isCurrent: { [weak self] in
                await MainActor.run {
                    guard let self else { return false }
                    return !self.stopping && admission.isValid
                        && self.reader.changeCount == observation.count
                        && self.sourceIsAllowed(observation.source)
                }
            })
            if !stopping, state != .watching { state = .watching }
            await onCapture?()
        } catch {
            // A stop and a replacement own the final state, including when a provider reports a late error after its
            // permission was revoked.
            guard admission.isValid, !Task.isCancelled, !stopping else { return }
            if error is CancellationError || error as? CaptureError == .staleSnapshot {
                // A newer copy replaced this one, and is read in its place.
            } else if error as? StoreError == .maintenanceInProgress {
                // Retry only this observed copy. A newer clipboard count, or a
                // stop, invalidates it through the existing admission path.
                pending = observation
                processedCount = observation.count &- 1
                retryAfter = ContinuousClock.now.advanced(by: .milliseconds(250))
            } else if error as? StoreError == .operationDenied {
                pollingTask?.cancel(); pollingTask = nil
                state = .failed("Keeping new copies requires a newer Keeptide version or library recovery. Existing content is preserved.")
                onUnavailable?()
            } else if DiskPressurePolicy.isOutOfSpace(error) {
                state = .interrupted("Storage is full. Free some space to keep new copies.")
                await onStorageFull?()
            } else if let reason = Self.reasonNotKept(error) {
                state = .interrupted(reason)
            } else if !Self.isSkippedQuietly(error) {
                pollingTask?.cancel(); pollingTask = nil
                state = .failed("The local library is unavailable. Reopen Keeptide to retry.")
                onUnavailable?()
            }
        }
    }

    /// Why a copy was not kept, when the system denied Keeptide the clipboard, when the copy could not be read whole,
    /// or when it is too large; nil for any other error.
    private static func reasonNotKept(_ error: any Error) -> String? {
        let tooLarge = "The last copy was not kept because it is larger than 50 MiB."
        if error as? CaptureError == .oversized { return tooLarge }
        guard let error = error as? SnapshotReaderError else { return nil }
        switch error {
        case .permissionDenied:
            return "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        case .readerUnavailable:
            return "The last copy was not kept because Keeptide could not read the clipboard. Copy it again to retry."
        case .readTimedOut:
            return "The last copy was not kept because it took too long to read. Copy it again to retry."
        case .payloadTooLarge:
            return tooLarge
        case .incompleteRepresentation:
            return "The last copy was not kept because part of it could not be read. Copy it again to retry."
        case .unsupportedType:
            return "The last copy was not kept because its format is not supported."
        case .privacyRestricted, .emptyPasteboard, .changedDuringRead:
            return nil
        }
    }

    /// A copy Keeptide skips without a word: a private or empty one, or one that changed while it was read. The next
    /// copy is tried as ever.
    private static func isSkippedQuietly(_ error: any Error) -> Bool {
        if error is SnapshotReaderError { return true }
        guard let error = error as? CaptureError else { return false }
        return [.emptySnapshot, .privacyRestricted].contains(error)
    }

    /// A copy being read from an app that has just been ignored is let go.
    private func preferencesChanged() {
        guard let active, !sourceIsAllowed(active.source) else { return }
        permit?.revoke(); captureTask?.cancel()
    }
}
