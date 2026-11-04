import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class CaptureMonitorTests: XCTestCase {
    func testDisabledPausedAndExcludedSourcesNeverReadBodies() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            reader.changeCount = 1
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
            preferences.isEnabled = true
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0, "Starting must not capture the preexisting clipboard")
            reader.changeCount = 2
            preferences.addExclusion("test.source")
            reader.changeCount = 3
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
            preferences.isEnabled = false
            reader.changeCount = 4
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
        }
    }

    func testAMonitorMadeRecordingDoesNotImportWhatWasAlreadyCopied() async throws {
        // As on first launch: recording from the start, over a clipboard that already holds a copy.
        try await withMonitor(recording: true, clipboardChangeCount: 7) { monitor, reader, preferences, controller in
            XCTAssertTrue(preferences.isEnabled)
            monitor.start()
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0, "What was copied before recording started must not be imported")
            XCTAssertTrue(monitor.isRecording)
            // The next copy is recorded.
            reader.changeCount = 8
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testRecordingPersistsOnlyNewCopiesAndPauseResumeDoesNotBackfill() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.changeCount = 1
            await monitor.poll()
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            preferences.isEnabled = false
            reader.changeCount = 2
            preferences.isEnabled = true
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            reader.changeCount = 3
            await monitor.poll()
            let repository = ContentRepository(controller: controller)
            let rows = try await repository.recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
            let state = try await repository.recordState(.item(try XCTUnwrap(rows.first?.itemID)))
            guard case .item(let item) = state.value else { return XCTFail("Expected item") }
            XCTAssertEqual(item.copyCount, 2)
        }
    }

    func testOwnWriteSkipsOneCountButNextExternalCopyIsCaptured() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            preferences.isEnabled = true
            reader.changeCount = 1
            monitor.suppressOwnWrite(OwnWriteToken(changeCount: 1, marker: "test"))
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testFailedReadDoesNotTightLoopAndNextCopyCanSucceed() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            preferences.isEnabled = true
            reader.failure = .permissionDenied
            reader.changeCount = 1
            await monitor.poll()
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            XCTAssertTrue(monitor.status.contains("access"))
            XCTAssertFalse(preferences.isEnabled)
            reader.failure = nil
            preferences.isEnabled = true
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 2)
        }
    }

    func testPreferencesPersistInAnIsolatedSuite() {
        let suite = "CapturePreferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CapturePreferences(defaults: defaults)
        XCTAssertTrue(first.isEnabled)
        first.isEnabled = false
        first.addExclusion("test.source")
        first.addExclusion("test.source")
        let second = CapturePreferences(defaults: defaults)
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(second.excludedApplications, ["test.source"])
        second.isEnabled = true
        second.removeExclusion("test.source")
        XCTAssertTrue(CapturePreferences(defaults: defaults).isEnabled)
        XCTAssertTrue(CapturePreferences(defaults: defaults).excludedApplications.isEmpty)
    }

    func testPauseRemainsPendingUntilInFlightReadDrainsWithoutSaving() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.changeCount = 1
            let started = self.expectation(description: "Deferred read started")
            reader.suspendedReadStarted = started
            let polling = Task { await monitor.poll() }
            await self.fulfillment(of: [started], timeout: 3)
            preferences.isEnabled = false
            XCTAssertTrue(monitor.isPausing)
            XCTAssertTrue(monitor.status.hasPrefix("Pausing"))
            reader.finishSuspendedRead()
            await polling.value
            XCTAssertFalse(monitor.isPausing)
            XCTAssertEqual(monitor.status, "Not recording")
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testNULInCopiedTextDoesNotDisableRecording() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.body = Data("hello\u{0000}world".utf8)
            reader.changeCount = 1
            await monitor.poll()
            XCTAssertTrue(preferences.isEnabled)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
            XCTAssertFalse(rows.first?.title.utf8.contains(0) ?? true)
        }
    }

    func testUnrelatedExclusionChangeDoesNotConsumePendingCopy() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.changeCount = 1
            let started = self.expectation(description: "read pending")
            reader.suspendedReadStarted = started
            let polling = Task { await monitor.poll() }
            await self.fulfillment(of: [started], timeout: 3)
            preferences.addExclusion("unrelated.application")
            reader.finishSuspendedRead()
            await polling.value
            reader.suspendedReadStarted = nil
            await monitor.poll()
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(preferences.isEnabled)
        }
    }

    func testCaptureCannotSwitchToANewerCountBetweenObservationAndRead() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.changeCount = 1
            reader.advanceCountOnRead = true
            await monitor.poll()
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty, "The snapshot must bind to the count admitted by policy")
            XCTAssertEqual(reader.readCount, 0, "Replaced copies must be rejected before reading bodies")
            XCTAssertTrue(preferences.isEnabled)
        }
    }

    func testPauseOwnsStatusEvenWhenPendingReaderFails() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            preferences.isEnabled = true
            reader.changeCount = 1
            let started = self.expectation(description: "read pending")
            reader.suspendedReadStarted = started
            reader.failureAfterRead = .emptyPasteboard
            let polling = Task { await monitor.poll() }
            await self.fulfillment(of: [started], timeout: 3)
            preferences.isEnabled = false
            reader.finishSuspendedRead()
            await polling.value
            XCTAssertEqual(monitor.status, "Not recording")
            XCTAssertFalse(monitor.isPausing)
        }
    }

    func testStopAndDrainWaitsForInFlightReadBeforeStoreCanClose() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.changeCount = 1
            let started = expectation(description: "read started")
            reader.suspendedReadStarted = started
            let poll = Task { await monitor.poll() }
            await fulfillment(of: [started], timeout: 3)
            var drained = false
            let shutdown = Task { await monitor.stopAndDrain(); drained = true }
            await Task.yield()
            XCTAssertFalse(drained)
            XCTAssertTrue(monitor.isPausing)
            reader.finishSuspendedRead()
            await shutdown.value
            await poll.value
            XCTAssertTrue(drained)
            XCTAssertEqual(monitor.state, .stopped)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testFocusBoundaryKeepsCopyAttributedToTheIgnoredPreviousApp() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.addExclusion("  TEST.SOURCE  ")
            preferences.isEnabled = true
            reader.changeCount = 1
            reader.foregroundSource = "allowed.app"
            monitor.foregroundApplicationChanged(to: reader.foregroundSource)
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testIgnoredCopyObservedWhileBusyRevokesOldWorkAndIsNotReadLater() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.addExclusion("secret.app")
            preferences.isEnabled = true
            reader.changeCount = 1
            let started = expectation(description: "old copy pending")
            reader.suspendedReadStarted = started
            let poll = Task { await monitor.poll() }
            await fulfillment(of: [started], timeout: 3)
            reader.foregroundSource = "secret.app"
            monitor.foregroundApplicationChanged(to: reader.foregroundSource)
            reader.changeCount = 2
            reader.foregroundSource = "allowed.app"
            monitor.foregroundApplicationChanged(to: reader.foregroundSource)
            reader.finishSuspendedRead()
            await poll.value
            reader.suspendedReadStarted = nil
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertTrue(monitor.isRecording)
        }
    }

    func testPausedMonitorDoesNotKeepPolling() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            preferences.isEnabled = true
            monitor.start()
            await Task.yield()
            preferences.isEnabled = false
            let samples = reader.sampleCount
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(reader.sampleCount, samples)
            XCTAssertFalse(monitor.isRecording)
        }
    }

    func testStorageFailureStopsLiveRecordingWithoutChangingUserIntent() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            try await controller.close()
            reader.changeCount = 1
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertTrue(unavailable)
            XCTAssertFalse(monitor.isRecording)
            XCTAssertTrue(preferences.isEnabled)
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testUnknownMaintenanceRequiresRecoveryWithoutTransientRetry() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            preferences.isEnabled = true
            reader.unexpectedFailure = StoreError.operationDenied
            reader.changeCount = 1
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertTrue(unavailable)
            XCTAssertTrue(monitor.status.contains("newer Keeptide version or library recovery"))
            reader.unexpectedFailure = nil
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testDiskFullPausesWithoutDisablingTheLibraryAndRequiresANewCopyAfterResume() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.unexpectedFailure = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
            reader.changeCount = 1
            var recoveries = 0
            var unavailable = false
            monitor.onStorageFull = { recoveries += 1 }
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertEqual(recoveries, 1)
            XCTAssertFalse(unavailable)
            XCTAssertFalse(preferences.isEnabled)
            XCTAssertTrue(monitor.status.contains("storage is full"))
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            reader.unexpectedFailure = nil
            preferences.isEnabled = true
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            reader.changeCount = 3
            await monitor.poll()
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testMaintenanceContentionRetriesTheCurrentCopyWithoutDisablingRecording() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            preferences.isEnabled = true
            reader.unexpectedFailure = StoreError.maintenanceInProgress
            reader.changeCount = 1
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertFalse(unavailable)
            XCTAssertTrue(preferences.isEnabled)
            XCTAssertTrue(monitor.isRecording)
            reader.unexpectedFailure = nil
            try await Task.sleep(for: .milliseconds(300))
            await monitor.poll()
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    /// Each test starts paused, as after the user's pause, and turns recording on where it needs it, unless it starts
    /// `recording`, as a first launch does; the clipboard's count starts at `clipboardChangeCount`.
    private func withMonitor(recording: Bool = false, clipboardChangeCount: Int = 0,
                             _ body: (PasteboardMonitor, FakeReader, CapturePreferences, PersistenceController) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Monitor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CaptureMonitor-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(recording, forKey: "captureEnabled")
        let controller = try PersistenceController(directory: directory)
        let reader = FakeReader()
        reader.changeCount = clipboardChangeCount
        let preferences = CapturePreferences(defaults: defaults)
        let monitor = PasteboardMonitor(reader: reader, service: CaptureService(controller: controller),
            preferences: preferences, sourceApp: { reader.foregroundSource }, matchesOwnWrite: { _ in true })
        do { try await body(monitor, reader, preferences, controller) } catch {
            await monitor.stopAndDrain()
            try await controller.close()
            throw error
        }
        await monitor.stopAndDrain()
        try await controller.close()
    }
}

@MainActor
private final class FakeReader: SnapshotReading {
    private var count = 0
    var sampleCount = 0
    var changeCount: Int {
        get { sampleCount += 1; return count }
        set { count = newValue }
    }
    var foregroundSource: String? = "test.source"
    var readCount = 0
    var unexpectedFailure: Error?
    var failure: SnapshotReaderError?
    var failureAfterRead: SnapshotReaderError?
    var advanceCountOnRead = false
    var body = Data("synthetic".utf8)
    var suspendedReadStarted: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?

    func readAsynchronously(sourceApp: String?, expectedChangeCount: Int) async throws -> CaptureSnapshotValue {
        if advanceCountOnRead { changeCount += 1 }
        guard expectedChangeCount == changeCount else {
            throw SnapshotReaderError.changedDuringRead(expected: expectedChangeCount, actual: changeCount)
        }
        let snapshot = try read(sourceApp: sourceApp)
        if let suspendedReadStarted {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                suspendedReadStarted.fulfill()
            }
        }
        if let failureAfterRead { throw failureAfterRead }
        return snapshot
    }

    func finishSuspendedRead() { continuation?.resume(); continuation = nil }

    func read(sourceApp: String?) throws -> CaptureSnapshotValue {
        readCount += 1
        if let unexpectedFailure { throw unexpectedFailure }
        if let failure { throw failure }
        return CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: body)
        ])], changeCount: changeCount, sourceApp: sourceApp)
    }
}
