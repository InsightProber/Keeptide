import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class CaptureMonitorTests: XCTestCase {
    private let denied = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
    private let full = "Storage is full. Free some space to keep new copies."

    func testCopiesFromIgnoredAppsAreNeverRead() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
            // The app in front is ignored: its copies are never read, before the ignoring or after it.
            preferences.addExclusion("test.source")
            reader.changeCount = 1
            await monitor.poll()
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
            XCTAssertEqual(monitor.state, .watching)
            // No longer ignored, its next copy is kept.
            preferences.removeExclusion("test.source")
            reader.changeCount = 3
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testAMonitorMadeRecordingDoesNotImportWhatWasAlreadyCopied() async throws {
        // As on first launch: watching from the start, over a clipboard that already holds a copy.
        try await withMonitor(clipboardChangeCount: 7) { monitor, reader, _, controller in
            monitor.start()
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0, "What was copied before the monitor was made must not be imported")
            XCTAssertEqual(monitor.state, .watching)
            // The next copy is kept.
            reader.changeCount = 8
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testTheSameCopyAgainIsKeptOnceAndCountedTwice() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.changeCount = 1
            await monitor.poll()
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            reader.changeCount = 2
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
        try await withMonitor { monitor, reader, _, _ in
            reader.changeCount = 1
            monitor.suppressOwnWrite(OwnWriteToken(changeCount: 1, marker: "test"))
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 0)
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testADeniedClipboardSaysWhyAndANewCopyRecoversOnItsOwn() async throws {
        try await withMonitor { monitor, reader, _, controller in
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            reader.failure = .permissionDenied
            reader.changeCount = 1
            await monitor.poll()
            await monitor.poll()
            // The copy is tried once, and the monitor says why it could not keep it. It goes on watching.
            XCTAssertEqual(reader.readCount, 1)
            XCTAssertEqual(monitor.state, .interrupted(denied))
            XCTAssertFalse(unavailable)
            // Still denied, the next copy is tried, and the reason stays.
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 2)
            XCTAssertEqual(monitor.state, .interrupted(denied))
            // Allowed meanwhile, the next copy is kept, and the reason goes, with nothing turned back on.
            reader.failure = nil
            reader.changeCount = 3
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 3)
            XCTAssertEqual(monitor.state, .watching)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testAFullDiskSaysWhyAndTriesEachNewCopyUntilOneIsKept() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.unexpectedFailure = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
            var recoveries = 0
            var unavailable = false
            monitor.onStorageFull = { recoveries += 1 }
            monitor.onUnavailable = { unavailable = true }
            reader.changeCount = 1
            await monitor.poll()
            // The rebuildable search cache is cleared, the library stays, and the monitor says why. It goes on
            // watching.
            XCTAssertEqual(recoveries, 1)
            XCTAssertFalse(unavailable)
            XCTAssertEqual(monitor.state, .interrupted(full))
            // The same copy is not tried again and again.
            await monitor.poll()
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
            // A new copy is tried, and finds the disk still full.
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 2)
            XCTAssertEqual(recoveries, 2)
            XCTAssertEqual(monitor.state, .interrupted(full))
            // Once there is room, the next copy is kept, and the reason goes.
            reader.unexpectedFailure = nil
            reader.changeCount = 3
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 3)
            XCTAssertEqual(monitor.state, .watching)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testOnlyAKeptCopyEndsTheReason() async throws {
        try await withMonitor { monitor, reader, preferences, _ in
            reader.failure = .permissionDenied
            reader.changeCount = 1
            await monitor.poll()
            XCTAssertEqual(monitor.state, .interrupted(denied))
            // Neither a copy Keeptide does not keep, such as a private one, nor one from an ignored app, nor its own
            // copy, shows that the clipboard can be read: the reason stays until a copy is kept.
            reader.failure = .privacyRestricted
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 2)
            XCTAssertEqual(monitor.state, .interrupted(denied))
            reader.failure = nil
            preferences.addExclusion("test.source")
            reader.changeCount = 3
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 2)
            XCTAssertEqual(monitor.state, .interrupted(denied))
            preferences.removeExclusion("test.source")
            monitor.suppressOwnWrite(OwnWriteToken(changeCount: 4, marker: "test"))
            reader.changeCount = 4
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 2)
            XCTAssertEqual(monitor.state, .interrupted(denied))
        }
    }

    func testPreferencesPersistInAnIsolatedSuite() {
        let suite = "CapturePreferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CapturePreferences(defaults: defaults)
        first.addExclusion("test.source")
        first.addExclusion("test.source")
        let second = CapturePreferences(defaults: defaults)
        XCTAssertEqual(second.excludedApplications, ["test.source"])
        second.removeExclusion("test.source")
        XCTAssertTrue(CapturePreferences(defaults: defaults).excludedApplications.isEmpty)
    }

    func testNULInCopiedTextDoesNotStopNewCopies() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.body = Data("hello\u{0000}world".utf8)
            reader.changeCount = 1
            await monitor.poll()
            XCTAssertEqual(monitor.state, .watching)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
            XCTAssertFalse(rows.first?.title.utf8.contains(0) ?? true)
        }
    }

    func testUnrelatedExclusionChangeDoesNotConsumePendingCopy() async throws {
        try await withMonitor { monitor, reader, preferences, controller in
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
            XCTAssertEqual(monitor.state, .watching)
        }
    }

    func testCaptureCannotSwitchToANewerCountBetweenObservationAndRead() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.changeCount = 1
            reader.advanceCountOnRead = true
            await monitor.poll()
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty, "The snapshot must bind to the count admitted by policy")
            XCTAssertEqual(reader.readCount, 0, "Replaced copies must be rejected before reading bodies")
            XCTAssertEqual(monitor.state, .watching)
        }
    }

    func testAStopOwnsTheStateEvenWhenThePendingReadIsDenied() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.changeCount = 1
            let started = self.expectation(description: "read pending")
            reader.suspendedReadStarted = started
            reader.failureAfterRead = .permissionDenied
            let polling = Task { await monitor.poll() }
            await self.fulfillment(of: [started], timeout: 3)
            monitor.stop()
            reader.finishSuspendedRead()
            await polling.value
            // A denial that comes in after the stop says nothing, and keeps nothing.
            XCTAssertEqual(monitor.state, .stopped)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testStopAndDrainWaitsForInFlightReadBeforeStoreCanClose() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.changeCount = 1
            let started = expectation(description: "read started")
            reader.suspendedReadStarted = started
            let poll = Task { await monitor.poll() }
            await fulfillment(of: [started], timeout: 3)
            var drained = false
            let shutdown = Task { await monitor.stopAndDrain(); drained = true }
            await Task.yield()
            XCTAssertFalse(drained)
            XCTAssertEqual(monitor.state, .stopped)
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
            XCTAssertEqual(monitor.state, .watching)
        }
    }

    func testAStoppedMonitorNoLongerPolls() async throws {
        try await withMonitor { monitor, reader, _, _ in
            monitor.start()
            await Task.yield()
            monitor.stop()
            let samples = reader.sampleCount
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(reader.sampleCount, samples)
            XCTAssertEqual(monitor.state, .stopped)
        }
    }

    func testALibraryThatStopsWorkingStopsWatchingUntilKeeptideReopens() async throws {
        try await withMonitor { monitor, reader, _, controller in
            try await controller.close()
            reader.changeCount = 1
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertTrue(unavailable)
            XCTAssertEqual(monitor.state, .failed("The local library is unavailable. Reopen Keeptide to retry."))
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testUnknownMaintenanceRequiresRecoveryWithoutTransientRetry() async throws {
        try await withMonitor { monitor, reader, _, _ in
            reader.unexpectedFailure = StoreError.operationDenied
            reader.changeCount = 1
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertTrue(unavailable)
            XCTAssertEqual(monitor.state, .failed(
                "Keeping new copies requires a newer Keeptide version or library recovery. Existing content is preserved."
            ))
            reader.unexpectedFailure = nil
            reader.changeCount = 2
            await monitor.poll()
            XCTAssertEqual(reader.readCount, 1)
        }
    }

    func testMaintenanceContentionRetriesTheCurrentCopyWithoutAProblem() async throws {
        try await withMonitor { monitor, reader, _, controller in
            reader.unexpectedFailure = StoreError.maintenanceInProgress
            reader.changeCount = 1
            var unavailable = false
            monitor.onUnavailable = { unavailable = true }
            await monitor.poll()
            XCTAssertFalse(unavailable)
            XCTAssertEqual(monitor.state, .watching)
            reader.unexpectedFailure = nil
            try await Task.sleep(for: .milliseconds(300))
            await monitor.poll()
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(rows.count, 1)
        }
    }

    /// Each test watches from the start, as Keeptide does whenever it runs; the clipboard's count starts at
    /// `clipboardChangeCount`.
    private func withMonitor(clipboardChangeCount: Int = 0,
                             _ body: (PasteboardMonitor, FakeReader, CapturePreferences, PersistenceController) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Monitor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CaptureMonitor-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
