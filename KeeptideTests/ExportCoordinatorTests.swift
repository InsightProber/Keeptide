import Foundation
import Observation
import Synchronization
import XCTest
@testable import Keeptide

@MainActor
final class ExportCoordinatorTests: XCTestCase {
    func testSelectedScopeUpdatesOnlyTheFlushedSameFacetAndRejectsConflictCopies() throws {
        let itemID = ItemID()
        let otherItemID = ItemID()
        let old = Self.ref(itemID: itemID, facet: .memo, byte: 1)
        let updated = Self.ref(itemID: itemID, facet: .memo, byte: 2)
        let other = Self.ref(itemID: otherItemID, facet: .memo, byte: 3)

        let resolved = try ExportSelectionResolver.selectedScope(
            requested: [old, other],
            editorRef: old,
            flushedRef: updated,
            displayed: [updated, other]
        )
        XCTAssertEqual(resolved, .selected([updated, other]))

        let conflictCopy = Self.ref(itemID: ItemID(), facet: .memo, byte: 4)
        do {
            _ = try ExportSelectionResolver.selectedScope(
                requested: [old, other],
                editorRef: old,
                flushedRef: conflictCopy,
                displayed: [conflictCopy, other]
            )
            XCTFail("A conflict copy was exported as the selected item")
        } catch {
            XCTAssertEqual(error as? ExportPreparationError, .selectionChanged)
        }

        let staleDisplayed = Self.ref(itemID: itemID, facet: .memo, byte: 5)
        do {
            _ = try ExportSelectionResolver.selectedScope(
                requested: [old],
                editorRef: old,
                flushedRef: updated,
                displayed: [staleDisplayed]
            )
            XCTFail("A changed display selection was exported")
        } catch {
            XCTAssertEqual(error as? ExportPreparationError, .selectionChanged)
        }
    }

    func testSuccessReportsVerifiedCountAndOnlyRevealsAfterExplicitAction() async throws {
        let parent = URL(fileURLWithPath: "/Synthetic/Export Parent", isDirectory: true)
        let destination = parent.appendingPathComponent("Keeptide Export Synthetic", isDirectory: true)
        let exporter = ClosureExporter { request, progress in
            guard request.destinationParent == parent,
                  case .allVisible = request.scope else {
                throw ExportPreparationError.selectionChanged
            }
            progress(.preparing)
            progress(.writing(completedEntries: 3))
            progress(.verifying)
            progress(.publishing)
            return ExportResult(destination: destination, verification: Self.verification(entryCount: 3))
        }
        var revealed: [URL] = []
        let coordinator = ExportCoordinator(
            exporter: exporter,
            chooseFolder: { parent },
            reveal: { revealed.append($0) }
        )

        coordinator.start { .allVisible }
        await waitUntil { coordinator.phase == .succeeded(ExportSuccess(destination: destination, itemCount: 3)) }
        XCTAssertTrue(revealed.isEmpty)
        coordinator.showInFinder()
        XCTAssertEqual(revealed, [destination])
        coordinator.dismissResult()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testPublishedResultRemainsSuccessWhenCancellationArrivesAfterCommit() async throws {
        let parent = URL(fileURLWithPath: "/Synthetic/Committed", isDirectory: true)
        let exporter = ExportProbe(suspendUntilReleased: true, returnsCommittedResult: true)
        let coordinator = ExportCoordinator(exporter: exporter, chooseFolder: { parent })
        coordinator.start { .allVisible }
        await exporter.waitUntilStarted()
        coordinator.cancel()
        await exporter.release()
        await waitUntil { coordinator.canStart }
        guard case .succeeded(let result) = coordinator.phase else {
            return XCTFail("A committed archive was hidden by late cancellation")
        }
        XCTAssertEqual(result.destination, parent.appendingPathComponent("Synthetic", isDirectory: true))
    }

    func testCancelWhileChoosingFolderPreventsLateSelectionFromStartingExport() async throws {
        let chooser = FolderChoiceProbe()
        let exporter = ExportProbe()
        var cancellationCount = 0
        let coordinator = ExportCoordinator(
            exporter: exporter,
            chooseFolder: { await chooser.choose() },
            cancelFolderChoice: { cancellationCount += 1 }
        )

        coordinator.start { .allVisible }
        await waitUntil { coordinator.phase == .choosingFolder }
        coordinator.cancel()
        XCTAssertEqual(cancellationCount, 1)
        chooser.finish(URL(fileURLWithPath: "/Synthetic/Late", isDirectory: true))
        await waitUntil { coordinator.canStart }
        XCTAssertEqual(coordinator.phase, .idle)
        let callsAfterCancellation = await exporter.callCount
        XCTAssertEqual(callsAfterCancellation, 0)
    }

    func testAvailabilityNotifiesObserversWhenFolderCancellationFinishes() async throws {
        let chooser = FolderChoiceProbe()
        let coordinator = ExportCoordinator(exporter: ExportProbe(), chooseFolder: { await chooser.choose() })
        let changes = Mutex(0)
        withObservationTracking {
            XCTAssertTrue(coordinator.canStart)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        coordinator.start { .allVisible }
        XCTAssertEqual(changes.withLock { $0 }, 1)
        await waitUntil { coordinator.phase == .choosingFolder }
        withObservationTracking {
            XCTAssertFalse(coordinator.canStart)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        coordinator.cancel()
        chooser.finish(nil)
        await waitUntil { coordinator.canStart }
        XCTAssertEqual(changes.withLock { $0 }, 2)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testStopAndDrainWaitsForInFlightExporterAndRejectsLaterStarts() async throws {
        let parent = URL(fileURLWithPath: "/Synthetic/Drain", isDirectory: true)
        let exporter = ExportProbe(suspendUntilReleased: true)
        let coordinator = ExportCoordinator(exporter: exporter, chooseFolder: { parent })
        coordinator.start { .allVisible }
        await exporter.waitUntilStarted()

        let completion = CompletionProbe()
        let drain = Task { @MainActor in
            await coordinator.stopAndDrain()
            await completion.markFinished()
        }
        await Task.yield()
        let finishedBeforeRelease = await completion.isFinished
        XCTAssertFalse(finishedBeforeRelease)
        await exporter.release()
        await drain.value
        let finishedAfterRelease = await completion.isFinished
        XCTAssertTrue(finishedAfterRelease)
        XCTAssertEqual(coordinator.phase, .idle)

        coordinator.start { .allVisible }
        await Task.yield()
        let callsAfterClose = await exporter.callCount
        XCTAssertEqual(callsAfterClose, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testPreparationAndUnknownFailuresUseSanitizedMessages() async throws {
        let parent = URL(fileURLWithPath: "/Synthetic/Errors", isDirectory: true)
        let exporter = ClosureExporter { _, _ in
            throw NSError(
                domain: "secret clipboard body: export TOKEN-123",
                code: 7
            )
        }
        let coordinator = ExportCoordinator(exporter: exporter, chooseFolder: { parent })

        coordinator.start { throw ExportPreparationError.compositionInProgress }
        await waitUntil {
            coordinator.phase == .failed("Finish text composition before exporting.")
        }
        coordinator.dismissResult()

        coordinator.start { .allVisible }
        await waitUntil {
            if case .failed = coordinator.phase { return true }
            return false
        }
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("Expected a sanitized failure")
        }
        XCTAssertEqual(message, "The export could not be completed. No archive was published.")
        XCTAssertFalse(message.contains("TOKEN-123"))
    }

    func testServiceCancellationReturnsToIdleWithoutAnErrorSheet() async throws {
        let exporter = ClosureExporter { _, _ in throw ExportError.cancelled }
        let coordinator = ExportCoordinator(
            exporter: exporter,
            chooseFolder: { URL(fileURLWithPath: "/Synthetic/Cancelled", isDirectory: true) }
        )
        coordinator.start { .allVisible }
        await waitUntil { coordinator.canStart }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.presentsStatus)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    nonisolated private static func verification(entryCount: Int) -> ArchiveVerification {
        ArchiveVerification(
            entryCount: entryCount,
            representationCount: entryCount,
            portablePayloadCount: entryCount,
            readableFileCount: entryCount,
            verifiedRootDigest: String(repeating: "a", count: 64)
        )
    }

    nonisolated private static func ref(itemID: ItemID, facet: ContentFacet, byte: UInt8) -> ContentRef {
        ContentRef(
            itemID: itemID,
            facet: facet,
            version: ContentVersion(),
            digest: Data(repeating: byte, count: ContentDigest.byteCount)
        )
    }
}

private struct ClosureExporter: Exporting {
    let operation: @Sendable (ExportRequest, @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult

    init(
        _ operation: @escaping @Sendable (
            ExportRequest,
            @escaping @Sendable (ExportProgress) -> Void
        ) async throws -> ExportResult
    ) {
        self.operation = operation
    }

    func export(
        _ request: ExportRequest,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        try await operation(request, progress)
    }
}

@MainActor
private final class FolderChoiceProbe {
    private var continuation: CheckedContinuation<URL?, Never>?

    func choose() async -> URL? {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ url: URL?) {
        continuation?.resume(returning: url)
        continuation = nil
    }
}

private actor ExportProbe: Exporting {
    private(set) var callCount = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private let suspendUntilReleased: Bool
    private let returnsCommittedResult: Bool

    init(suspendUntilReleased: Bool = false, returnsCommittedResult: Bool = false) {
        self.suspendUntilReleased = suspendUntilReleased
        self.returnsCommittedResult = returnsCommittedResult
    }

    func export(
        _ request: ExportRequest,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        callCount += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        progress(.preparing)
        if suspendUntilReleased {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        if !returnsCommittedResult { try Task.checkCancellation() }
        return ExportResult(
            destination: request.destinationParent.appendingPathComponent("Synthetic", isDirectory: true),
            verification: ArchiveVerification(
                entryCount: 1,
                representationCount: 1,
                portablePayloadCount: 1,
                readableFileCount: 1,
                verifiedRootDigest: String(repeating: "b", count: 64)
            )
        )
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false
    func markFinished() { isFinished = true }
}
