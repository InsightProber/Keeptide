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
        XCTAssertFalse(first.isEnabled)
        first.isEnabled = true
        first.addExclusion("test.source")
        first.addExclusion("test.source")
        let second = CapturePreferences(defaults: defaults)
        XCTAssertTrue(second.isEnabled)
        XCTAssertEqual(second.excludedApplications, ["test.source"])
        second.removeExclusion("test.source")
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

    private func withMonitor(_ body: (PasteboardMonitor, FakeReader, CapturePreferences, PersistenceController) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Monitor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CaptureMonitor-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = try PersistenceController(directory: directory)
        let reader = FakeReader()
        let preferences = CapturePreferences(defaults: defaults)
        let monitor = PasteboardMonitor(reader: reader, service: CaptureService(controller: controller),
            preferences: preferences, sourceApp: { "test.source" }, matchesOwnWrite: { _ in true })
        do { try await body(monitor, reader, preferences, controller) } catch {
            monitor.stop()
            try await controller.close()
            throw error
        }
        monitor.stop()
        try await controller.close()
    }
}

@MainActor
private final class FakeReader: SnapshotReading {
    var changeCount = 0
    var readCount = 0
    var failure: SnapshotReaderError?
    var suspendedReadStarted: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?

    func readAsynchronously(sourceApp: String?) async throws -> CaptureSnapshotValue {
        let snapshot = try read(sourceApp: sourceApp)
        if let suspendedReadStarted {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                suspendedReadStarted.fulfill()
            }
        }
        return snapshot
    }

    func finishSuspendedRead() { continuation?.resume(); continuation = nil }

    func read(sourceApp: String?) throws -> CaptureSnapshotValue {
        readCount += 1
        if let failure { throw failure }
        return CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("synthetic".utf8))
        ])], changeCount: changeCount, sourceApp: sourceApp)
    }
}
