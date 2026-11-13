import CoreGraphics
import XCTest
@testable import Keeptide

/// Derived text made for items and kept beside them: one job per item and operation, saved once when it ends, against
/// a real temporary store and a recognizer the test drives.
@MainActor
final class DerivedTextCoordinatorTests: XCTestCase {
    private let info = GenerationInfo(engine: "On this Mac", model: "test")

    func testRecognizedTextIsSavedBesideItsItemWhenTheJobFinishes() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        let job = try XCTUnwrap(coordinator.extractText(from: source, keepingLineBreaks: false))

        XCTAssertEqual(job.lane, .onDevice)
        XCTAssertEqual(job.priority, .user)
        XCTAssertTrue(coordinator.job(for: source, operation: .extractText) === job)
        XCTAssertNil(coordinator.job(for: source, operation: .translate))
        let engine = try await started(recognizer, 0)
        engine.send(.started(info), .delta("Quarterly plan"), .finished(.completed))
        await waitUntil("the result is saved") { hasSettled(coordinator, source) }
        guard case .saved(let saved)? = coordinator.outcome(for: source, operation: .extractText) else {
            return XCTFail("\(String(describing: coordinator.outcome(for: source, operation: .extractText)))")
        }
        XCTAssertEqual(saved.text, "Quarterly plan")
        XCTAssertEqual(saved.operation, .extractText)
        XCTAssertFalse(saved.keepsLineBreaks)
        XCTAssertEqual(recognizer.layouts, [false])
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read, saved)
        XCTAssertNil(coordinator.job(for: source, operation: .extractText), "The job leaves when it ends")
    }

    func testWhatAnEarlierJobSavedIsReadForExactlyItsContent() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Earlier", into: controller)
        let other = try await insertClip("Other", into: controller)
        var changed = source
        changed.digest = Data(repeating: 9, count: 32)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Saved before"), .finished(.completed))
        await waitUntil("the result is saved") { hasSettled(coordinator, source) }

        let saved = await coordinator.savedResult(for: source, operation: .extractText)
        let none = await coordinator.savedResult(for: other, operation: .extractText)
        let stale = await coordinator.savedResult(for: changed, operation: .extractText)

        XCTAssertEqual(saved?.text, "Saved before")
        XCTAssertNil(none)
        XCTAssertNil(stale, "The item's content has changed since")
    }

    func testAnImageWithoutTextIsRememberedAndNothingIsSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Blank", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .finished(.completed))

        await waitUntil("the job ended") { hasSettled(coordinator, source) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .noText)
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testAFailureIsRememberedAndNothingIsSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Damaged", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")

        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info))
        engine.end(throwing: failure)

        await waitUntil("the job ended") { hasSettled(coordinator, source) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .failed(failure))
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testStoppingAJobLeavesWhatTheEarlierOneMade() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first result is saved") { hasSettled(coordinator, source) }
        let earlier = try XCTUnwrap(coordinator.outcome(for: source, operation: .extractText))
        XCTAssertTrue(coordinator.showsLatestEnding(for: source, operation: .extractText))

        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        second.send(.started(info))
        coordinator.stop(source, operation: .extractText)

        await waitUntil("the second job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertTrue(second.wasCancelled)
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), earlier,
                       "What the item showed before the stopped job, it shows again")
        XCTAssertFalse(coordinator.showsLatestEnding(for: source, operation: .extractText),
                       "It is not how the latest job ended")
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Total 12.80")
        XCTAssertEqual(read?.keepsLineBreaks, true)
    }

    func testAJobStoppedBeforeTheEarlierOneWasSavedLeavesWhatThatSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let first = try await started(recognizer, 0)
        let busy = try await occupyWriter(of: controller)
        first.send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first job ended") { coordinator.job(for: source, operation: .extractText) == nil }

        // While the first job's text waits for the store, a second job starts and is stopped.
        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        coordinator.stop(source, operation: .extractText)
        await waitUntil("the second job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertTrue(second.wasCancelled)
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText),
                       .saving("Total 12.80", DerivedTextRequest(source: source, operation: .extractText,
                                                                 keepsLineBreaks: true), status: .complete))

        try await busy.value
        await waitUntil("the first job's text is saved") {
            if case .saved(let saved)? = coordinator.outcome(for: source, operation: .extractText) {
                return saved.text == "Total 12.80"
            }
            return false
        }
    }

    func testTextIsRecognizedWhenAskedForOnlyIfNothingWasMadeOfIt() async throws {
        let (controller, store) = try await makeStore()
        let kept = try await insertClip("Kept", into: controller)
        let fresh = try await insertClip("Fresh", into: controller)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Kept from before"]),
                                 for: DerivedTextRequest(source: kept, operation: .extractText, keepsLineBreaks: true))
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractTextUnlessMade(from: kept, keepingLineBreaks: true)
        coordinator.extractTextUnlessMade(from: fresh, keepingLineBreaks: false)
        coordinator.extractTextUnlessMade(from: fresh, keepingLineBreaks: false)

        XCTAssertTrue(coordinator.isWaitingToStart(fresh, operation: .extractText), "What was kept is read first")
        let engine = try await started(recognizer, 0)
        XCTAssertFalse(coordinator.isWaitingToStart(fresh, operation: .extractText))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognizer.layouts, [false], "Once, and only for the item nothing was kept of")
        XCTAssertNil(coordinator.job(for: kept, operation: .extractText))
        XCTAssertFalse(coordinator.isWaitingToStart(kept, operation: .extractText))

        // Text made in this session counts as made too; only a failure is tried again.
        engine.send(.started(info), .delta("Fresh text"), .finished(.completed))
        await waitUntil("the result is saved") { hasSettled(coordinator, fresh) }
        coordinator.extractTextUnlessMade(from: fresh, keepingLineBreaks: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognizer.layouts, [false])
    }

    func testStoppingARequestWaitingOnTheStoreStartsNothing() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Fresh", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractTextUnlessMade(from: source, keepingLineBreaks: true)
        coordinator.stop(source, operation: .extractText)

        XCTAssertFalse(coordinator.isWaitingToStart(source, operation: .extractText))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recognizer.layouts, [])
    }

    func testAskingAgainWhileTheStoreIsReadTakesTheLatestLayout() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Fresh", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractTextUnlessMade(from: source, keepingLineBreaks: true)
        coordinator.extractTextUnlessMade(from: source, keepingLineBreaks: false)

        _ = try await started(recognizer, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognizer.layouts, [false], "Once, in the layout asked for last")
    }

    func testAStoppedJobsTextTheStoreDidntTakeLeavesWhatTheEarlierSaveCameTo() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let first = try await started(recognizer, 0)
        let busy = try await occupyWriter(of: controller)
        first.send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first job ended") { coordinator.job(for: source, operation: .extractText) == nil }

        // While the first job's text waits for the store, a second job catches part of a text and is stopped. The
        // store keeps the first, whole text, and not the second's part of one.
        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        second.send(.started(info), .delta("Total"))
        await waitUntil("the second job has text") {
            coordinator.job(for: source, operation: .extractText)?.snapshot.hasText == true
        }
        coordinator.stop(source, operation: .extractText)
        await waitUntil("the second job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        try await busy.value

        await waitUntil("the item shows what the first save came to") {
            if case .saved(let saved)? = coordinator.outcome(for: source, operation: .extractText) {
                return saved.text == "Total 12.80"
            }
            return false
        }
    }

    func testAskingAgainForTextThatFailedTriesAgain() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Damaged", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info))
        engine.end(throwing: failure)
        await waitUntil("the job failed") { hasSettled(coordinator, source) }

        coordinator.extractTextUnlessMade(from: source, keepingLineBreaks: true)

        _ = try await started(recognizer, 1)
    }

    func testAskingAgainAfterAFailureStartsNothingWhenTheStoreKeptText() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Kept", into: controller)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Kept from before"]),
                                 for: DerivedTextRequest(source: source, operation: .extractText, keepsLineBreaks: true))
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        coordinator.extractText(from: source, keepingLineBreaks: false)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info))
        engine.end(throwing: failure)
        await waitUntil("the job failed") { hasSettled(coordinator, source) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .failed(failure),
                       "Nothing was made of it in this session")

        coordinator.extractTextUnlessMade(from: source, keepingLineBreaks: false)

        XCTAssertTrue(coordinator.isWaitingToStart(source, operation: .extractText), "What was kept is read first")
        await waitUntil("the store was read") { !coordinator.isWaitingToStart(source, operation: .extractText) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognizer.layouts, [false], "The text kept from before stands")
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Kept from before")
    }

    func testAFailureLeavesTheTextMadeBeforeAndSaysWhyWhileItIsTheLatestEnding() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first result is saved") { hasSettled(coordinator, source) }
        let made = try XCTUnwrap(coordinator.outcome(for: source, operation: .extractText))
        XCTAssertNil(coordinator.failure(for: source, operation: .extractText))
        let madeEnding = try XCTUnwrap(coordinator.latestEnding(for: source, operation: .extractText))

        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        second.send(.started(info))
        second.end(throwing: failure)

        await waitUntil("the second job failed") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertEqual(coordinator.failure(for: source, operation: .extractText), failure)
        let failedEnding = try XCTUnwrap(coordinator.latestEnding(for: source, operation: .extractText))
        XCTAssertNotEqual(failedEnding, madeEnding, "The failure is an ending of its own")
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), made, "The text made before stays")
        XCTAssertEqual(coordinator.cardState(for: source, operation: .extractText).outcome, made)
        XCTAssertFalse(coordinator.showsLatestEnding(for: source, operation: .extractText),
                       "The latest job didn't make the text")
        var read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Total 12.80")

        // A job stopped since leaves the text, and the failure is no longer how the latest job ended.
        coordinator.extractText(from: source, keepingLineBreaks: false)
        _ = try await started(recognizer, 2)
        coordinator.stop(source, operation: .extractText)
        await waitUntil("the third job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), made)
        XCTAssertNil(coordinator.failure(for: source, operation: .extractText))
        XCTAssertNil(coordinator.latestEnding(for: source, operation: .extractText), "What it shows isn't the latest")

        // Failed again, then made: the new text, and no failure.
        coordinator.extractText(from: source, keepingLineBreaks: false)
        let fourth = try await started(recognizer, 3)
        fourth.end(throwing: failure)
        await waitUntil("the fourth job failed") {
            coordinator.failure(for: source, operation: .extractText) == failure
        }
        coordinator.extractText(from: source, keepingLineBreaks: false)
        try await started(recognizer, 4).send(.started(info), .delta("Total 12.80 EUR"), .finished(.completed))
        await waitUntil("the new text is saved") {
            if case .saved(let saved)? = coordinator.outcome(for: source, operation: .extractText) {
                return saved.text == "Total 12.80 EUR"
            }
            return false
        }
        XCTAssertNil(coordinator.failure(for: source, operation: .extractText))
        read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Total 12.80 EUR")
    }

    func testAFailureWhileTheTextMadeBeforeIsSavedLeavesWhatThatSaveCameTo() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        let busy = try await occupyWriter(of: controller)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first job ended") { coordinator.job(for: source, operation: .extractText) == nil }

        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        second.send(.started(info))
        second.end(throwing: failure)
        await waitUntil("the second job failed") { coordinator.failure(for: source, operation: .extractText) != nil }
        guard case .saving("Total 12.80", _, _)? = coordinator.outcome(for: source, operation: .extractText) else {
            return XCTFail("The text being saved stays: \(String(describing: coordinator.outcome(for: source, operation: .extractText)))")
        }
        try await busy.value

        await waitUntil("the first save landed") {
            if case .saved(let saved)? = coordinator.outcome(for: source, operation: .extractText) {
                return saved.text == "Total 12.80"
            }
            return false
        }
        XCTAssertEqual(coordinator.failure(for: source, operation: .extractText), failure,
                       "It still says why the latest job made nothing")
    }

    func testAFailureOverTextTheStoreThenRefusesIsWhatTheItemShows() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let current = try await controller.identity()
        let recognizer = ScriptedRecognizer()
        // The library is another one now: nothing this coordinator makes is kept.
        let coordinator = try await makeCoordinator(controller, store, recognizer,
                                                    identity: StoreIdentity(storeID: current.storeID, generation: UUID()))
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        let busy = try await occupyWriter(of: controller)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        coordinator.extractText(from: source, keepingLineBreaks: false)
        try await started(recognizer, 1).end(throwing: failure)
        await waitUntil("the second job failed") { coordinator.failure(for: source, operation: .extractText) != nil }
        let failedEnding = try XCTUnwrap(coordinator.latestEnding(for: source, operation: .extractText))
        try await busy.value

        // The store didn't take the text the failure left: the failure is what the item shows, as its latest ending.
        await waitUntil("the first save was refused") {
            coordinator.outcome(for: source, operation: .extractText) == .failed(failure)
        }
        XCTAssertEqual(coordinator.latestEnding(for: source, operation: .extractText), failedEnding)
        XCTAssertNil(coordinator.failure(for: source, operation: .extractText), "Nothing made is left to say it over")
    }

    func testAWholeTextTheStoreDidntTakeLeavesWhatWasMadeBeforeAndSaysWhy() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first result is saved") { hasSettled(coordinator, source) }
        let made = try XCTUnwrap(coordinator.outcome(for: source, operation: .extractText))
        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        // Meanwhile the item goes, so the store doesn't take what the second job makes; it may yet come back.
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        _ = try await LifecycleService(controller: controller).remove(ref: source, at: Date(), expecting: identity,
                                                                      permit: permit)

        second.send(.started(info), .delta("Total 12.80 EUR"), .finished(.completed))

        await waitUntil("the second save was refused") {
            coordinator.failure(for: source, operation: .extractText) != nil
        }
        XCTAssertEqual(coordinator.failure(for: source, operation: .extractText), .contentUnavailable)
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), made, "What was made before stays")
        XCTAssertNotNil(coordinator.latestEnding(for: source, operation: .extractText))
    }

    func testFindingNoTextForAnItemThatWentMeanwhileLeavesWhatWasMadeBeforeAndSaysWhy() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Total 12.80"), .finished(.completed))
        await waitUntil("the first result is saved") { hasSettled(coordinator, source) }
        let made = try XCTUnwrap(coordinator.outcome(for: source, operation: .extractText))
        coordinator.extractText(from: source, keepingLineBreaks: false)
        let second = try await started(recognizer, 1)
        // Meanwhile the item goes to Recently Deleted, so the store can't let go of what it kept, which comes back with
        // the item.
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        _ = try await LifecycleService(controller: controller).remove(ref: source, at: Date(), expecting: identity,
                                                                      permit: permit)

        second.send(.started(info), .finished(.completed))

        await waitUntil("the clear was refused") { coordinator.failure(for: source, operation: .extractText) != nil }
        XCTAssertEqual(coordinator.failure(for: source, operation: .extractText), .contentUnavailable)
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), made, "What was made before stays")
    }

    func testAJobStartedWhileARequestWaitsOnTheStoreStandsInForIt() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Damaged", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        let busy = try await occupyWriter(of: controller)
        coordinator.extractTextUnlessMade(from: source, keepingLineBreaks: true)
        XCTAssertTrue(coordinator.isWaitingToStart(source, operation: .extractText))

        coordinator.extractText(from: source, keepingLineBreaks: true)

        XCTAssertFalse(coordinator.isWaitingToStart(source, operation: .extractText), "The job stands in for it")
        try await started(recognizer, 0).end(throwing: failure)
        await waitUntil("the job failed") { hasSettled(coordinator, source) }
        try await busy.value
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recognizer.layouts, [true], "Recognized once, not again once the store had answered")
    }

    func testAFailureAfterNoTextWasFoundLeavesThatFinding() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Blank", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .finished(.completed))
        await waitUntil("nothing was found") { coordinator.outcome(for: source, operation: .extractText) == .noText }

        coordinator.extractText(from: source, keepingLineBreaks: false)
        try await started(recognizer, 1).end(throwing: failure)

        await waitUntil("the second job failed") { coordinator.failure(for: source, operation: .extractText) != nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .noText)
    }

    func testFindingNoTextReplacesTheTextMadeBefore() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Made before"), .finished(.completed))
        await waitUntil("the first result is saved") { hasSettled(coordinator, source) }

        // Recognized again, it finds nothing: that is what the image has now, here and in the store.
        coordinator.extractText(from: source, keepingLineBreaks: false)
        try await started(recognizer, 1).send(.started(info), .finished(.completed))

        await waitUntil("the second job ended") { coordinator.outcome(for: source, operation: .extractText) == .noText }
        XCTAssertTrue(coordinator.showsLatestEnding(for: source, operation: .extractText))
        await coordinator.stopAndDrain()
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read, "Nothing found replaces the text made before")
    }

    func testFindingNoTextWhileTheTextMadeBeforeIsSavedLeavesNoText() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let busy = try await occupyWriter(of: controller)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Made before"), .finished(.completed))
        await waitUntil("the first job ended") { coordinator.job(for: source, operation: .extractText) == nil }

        coordinator.extractText(from: source, keepingLineBreaks: false)
        try await started(recognizer, 1).send(.started(info), .finished(.completed))
        await waitUntil("the second job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .noText,
                       "It says so at once, while the store is still busy")
        try await busy.value
        await coordinator.stopAndDrain()

        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .noText)
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read, "The text saved after its job ended doesn't outlast what a later job found")
    }

    func testANewerRequestReplacesTheOneUnderWay() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Poster", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractText(from: source, keepingLineBreaks: true)
        let first = try await started(recognizer, 0)
        first.send(.started(info))
        coordinator.extractText(from: source, keepingLineBreaks: false)

        let second = try await started(recognizer, 1)
        await waitUntil("the first job is stopped") { first.wasCancelled }
        second.send(.started(info), .delta("Newer"), .finished(.completed))
        await waitUntil("the newer result is saved") {
            if case .saved? = coordinator.outcome(for: source, operation: .extractText) { return true }
            return false
        }
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(read?.text, "Newer")
        XCTAssertEqual(read?.keepsLineBreaks, false)
    }

    func testAResultForAnotherStoreGenerationIsNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Generation", into: controller)
        let current = try await controller.identity()
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(
            controller, store, recognizer, identity: StoreIdentity(storeID: current.storeID, generation: UUID()))

        coordinator.extractText(from: source, keepingLineBreaks: true)
        try await started(recognizer, 0).send(.started(info), .delta("Late"), .finished(.completed))

        await waitUntil("the job ended") { hasSettled(coordinator, source) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText), .failed(.contentUnavailable))
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testTextTheLibraryCouldNotKeepIsSaidToBeNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Unwritable", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)

        try await controller.close()
        engine.send(.started(info), .delta("Kept nowhere"), .finished(.completed))

        await waitUntil("the job ended") { hasSettled(coordinator, source) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText),
                       .notSaved("Kept nowhere", DerivedTextRequest(source: source, operation: .extractText,
                                                                    keepsLineBreaks: true), status: .complete),
                       "The text is still there to show and copy, in the layout it was made in")
    }

    func testAnEndedJobsTextShowsWhileItIsBeingSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Receipt", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        let busy = try await occupyWriter(of: controller)

        engine.send(.started(info), .delta("Total 12.80"), .finished(.completed))

        await waitUntil("the job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .extractText),
                       .saving("Total 12.80", DerivedTextRequest(source: source, operation: .extractText,
                                                                 keepsLineBreaks: true), status: .complete),
                       "Between the job's end and the save, the item shows what the job made")
        try await busy.value
        await waitUntil("the result is saved") {
            if case .saved? = coordinator.outcome(for: source, operation: .extractText) { return true }
            return false
        }
    }

    func testAnOutcomeAndAJobBelongToTheContentTheyWereMadeFrom() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Memo", into: controller)
        var changed = source
        changed.version = ContentVersion()
        changed.digest = Data(repeating: 7, count: 32)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)

        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)

        XCTAssertNotNil(coordinator.job(for: source, operation: .extractText))
        XCTAssertNil(coordinator.job(for: changed, operation: .extractText), "The item's content has changed since")
        engine.send(.started(info), .delta("Before the edit"), .finished(.completed))
        await waitUntil("the result is saved") {
            if case .saved? = coordinator.outcome(for: source, operation: .extractText) { return true }
            return false
        }
        XCTAssertNil(coordinator.outcome(for: changed, operation: .extractText))
    }

    func testEveryCallerOfStopAndDrainWaitsForTheSavesUnderWay() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Drained", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        let busy = try await occupyWriter(of: controller)
        engine.send(.started(info), .delta("Written before closing"), .finished(.completed))
        await waitUntil("the job ended") { coordinator.job(for: source, operation: .extractText) == nil }

        async let first: Void = coordinator.stopAndDrain()
        async let second: Void = coordinator.stopAndDrain()
        await second

        guard case .saved? = coordinator.outcome(for: source, operation: .extractText) else {
            await first
            return XCTFail("The second caller went on while the save was under way")
        }
        await first
        try await busy.value
    }

    func testAJobThatEndsAsTheLibraryClosesIsNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Closing", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info), .delta("Whole"), .finished(.completed))

        // Hold the main actor while the job reads its source to the end, so that its end comes once the library has
        // closed.
        holdMainThread(for: 0.3)
        await coordinator.stopAndDrain()

        await waitUntil("the job ended") { coordinator.jobs.jobs.isEmpty }
        try await assertNoResultAppears(for: source, in: store)
    }

    func testAJobThatEndsAsANewerRequestStartsIsNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Superseded", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let older = try await started(recognizer, 0)
        older.send(.started(info), .delta("Older"), .finished(.completed))

        // As above: the older job's end comes after the newer request.
        holdMainThread(for: 0.3)
        coordinator.extractText(from: source, keepingLineBreaks: false)

        try await started(recognizer, 1).send(.started(info))
        try await assertNoResultAppears(for: source, in: store)
        XCTAssertNil(coordinator.outcome(for: source, operation: .extractText))
    }

    func testNothingIsSavedOrStartedOnceTheLibraryCloses() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Closing", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        coordinator.extractText(from: source, keepingLineBreaks: true)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info), .delta("Half"))

        await coordinator.stopAndDrain()

        await waitUntil("the job is stopped") { engine.wasCancelled }
        await waitUntil("the job ended") { coordinator.job(for: source, operation: .extractText) == nil }
        XCTAssertNil(coordinator.extractText(from: source, keepingLineBreaks: true))
        XCTAssertEqual(recognizer.layouts.count, 1, "No new recognition starts")
        XCTAssertNil(coordinator.outcome(for: source, operation: .extractText))
        let read = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(read)
    }

    func testTheRecognizerReadsTheItemsImage() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Photo", into: controller)
        let recognizer = ScriptedRecognizer()
        let reads = ReadLog()
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let coordinator = try await makeCoordinator(controller, store, recognizer) { ref in
            reads.record(ref)
            return image
        }

        coordinator.extractText(from: source, keepingLineBreaks: true)
        _ = try await started(recognizer, 0)
        let read = try await recognizer.image(0)()

        XCTAssertEqual(reads.refs, [source])
        XCTAssertEqual(read.width, 4)
    }

    func testTheEnginesTierDecidesTheLane() async throws {
        XCTAssertEqual(EngineTier.onThisMac.lane, .onDevice)
        XCTAssertEqual(EngineTier.appleIntelligence.lane, .onDevice)
        XCTAssertEqual(EngineTier.cloud.lane, .cloud)
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Cloud", into: controller)
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(tier: .cloud))

        let job = coordinator.extractText(from: source, keepingLineBreaks: true)

        XCTAssertEqual(job?.lane, .cloud)
    }

    // MARK: Translation

    func testATranslationOfTheItemsTextIsSavedBesideItWithItsTarget() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Quarterly plan", into: controller)
        let translator = ScriptedTranslator()
        let reads = ReadLog()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { ref in
                                                        reads.record(ref)
                                                        return "Quarterly plan"
                                                    })

        let job = try XCTUnwrap(coordinator.translate(source, to: Locale.Language(identifier: "zh-Hans")))

        XCTAssertEqual(job.lane, .onDevice)
        XCTAssertEqual(job.priority, .user)
        XCTAssertTrue(coordinator.job(for: source, operation: .translate) === job)
        XCTAssertNil(coordinator.job(for: source, operation: .extractText))
        let engine = try await startedTranslation(translator, 0)
        let request = try XCTUnwrap(translator.request(0))
        XCTAssertNil(request.source, "The text's languages are detected")
        XCTAssertEqual(request.target, Locale.Language(identifier: "zh-Hans"))
        let text = try await request.text()
        XCTAssertEqual(text, "Quarterly plan", "It translates the item's own text")
        XCTAssertEqual(reads.refs, [source])
        engine.send(.started(info), .expecting(paragraphs: 1), .delta("季度计划"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, source, .translate) }
        guard case .saved(let saved)? = coordinator.outcome(for: source, operation: .translate) else {
            return XCTFail("\(String(describing: coordinator.outcome(for: source, operation: .translate)))")
        }
        XCTAssertEqual(saved.text, "季度计划")
        XCTAssertEqual(saved.operation, .translate)
        XCTAssertEqual(saved.targetLanguage, "zh-Hans")
        XCTAssertNil(saved.sourceLanguage, "A detected language isn't kept as if a person had chosen it")
        let read = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(read, saved)
        XCTAssertNil(coordinator.outcome(for: source, operation: .extractText))
    }

    func testALanguageAPersonChoseIsKeptWithTheTranslation() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Bonjour", into: controller)
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)

        coordinator.translate(source, from: Locale.Language(identifier: "fr-FR"), to: Locale.Language(identifier: "en"))
        try await startedTranslation(translator, 0).send(.started(info), .delta("Hello"), .finished(.completed))

        await waitUntil("the translation is saved") { hasSettled(coordinator, source, .translate) }
        XCTAssertEqual(translator.request(0)?.source, Locale.Language(identifier: "fr-FR"))
        let saved = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(saved?.sourceLanguage, "fr")
        XCTAssertEqual(saved?.targetLanguage, "en")
    }

    func testTranslatingIntoAnotherLanguageReplacesTheTranslationUnderWay() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Quarterly plan", into: controller)
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        coordinator.translate(source, to: Locale.Language(identifier: "ja"))
        let first = try await startedTranslation(translator, 0)
        first.send(.started(info), .delta("四半期"))

        coordinator.translate(source, to: Locale.Language(identifier: "zh-Hant"))
        let second = try await startedTranslation(translator, 1)

        await waitUntil("the first translation stops") { first.wasCancelled }
        second.send(.started(info), .delta("季度計劃"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, source, .translate) }
        let saved = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(saved?.text, "季度計劃")
        XCTAssertEqual(saved?.targetLanguage, "zh-Hant")
    }

    func testATranslationIntoAnotherLanguageThatFailsLeavesTheOneMadeBeforeAndSaysWhy() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Quarterly plan", into: controller)
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        coordinator.translate(source, to: Locale.Language(identifier: "zh-Hans"))
        try await startedTranslation(translator, 0).send(.started(info), .delta("季度计划"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, source, .translate) }
        let made = try XCTUnwrap(coordinator.outcome(for: source, operation: .translate))
        let failure = GenerationError(kind: .languageNotDownloaded,
                                      message: "To translate from English to Japanese on this Mac, download both languages.")

        coordinator.translate(source, to: Locale.Language(identifier: "ja"))
        try await startedTranslation(translator, 1).end(throwing: failure)

        await waitUntil("the second translation failed") {
            coordinator.failure(for: source, operation: .translate) != nil
        }
        XCTAssertEqual(coordinator.failure(for: source, operation: .translate), failure)
        XCTAssertEqual(coordinator.outcome(for: source, operation: .translate), made, "The Chinese translation stays")
        let saved = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(saved?.text, "季度计划")
        XCTAssertEqual(saved?.targetLanguage, "zh-Hans")
    }

    func testATranslationIsMadeWhenAskedForOnlyIfNoneWasKept() async throws {
        let (controller, store) = try await makeStore()
        let kept = try await insertClip("Kept", into: controller)
        let fresh = try await insertClip("Fresh", into: controller)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Gardé d'avant"]),
                                 for: DerivedTextRequest(source: kept, operation: .translate, targetLanguage: "fr"))
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)

        // A translation kept from before shows as it is, whatever language it is in.
        coordinator.translateUnlessMade(kept, to: Locale.Language(identifier: "ja"))
        coordinator.translateUnlessMade(fresh, to: Locale.Language(identifier: "de"))
        coordinator.translateUnlessMade(fresh, to: Locale.Language(identifier: "ja"))

        XCTAssertTrue(coordinator.isWaitingToStart(fresh, operation: .translate), "What was kept is read first")
        let engine = try await startedTranslation(translator, 0)
        XCTAssertEqual(translator.request(0)?.target, Locale.Language(identifier: "ja"), "In the language asked last")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(1), "Once, and only for the item nothing was kept of")
        XCTAssertNil(coordinator.job(for: kept, operation: .translate))

        // Made in this session, it counts as made too.
        engine.send(.started(info), .delta("Frisch"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, fresh, .translate) }
        coordinator.translateUnlessMade(fresh, to: Locale.Language(identifier: "ja"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(1))
    }

    func testAStoppedTranslationShowsAsPartOfOneWhileItIsSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Quarterly plan", into: controller)
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        coordinator.translate(source, to: Locale.Language(identifier: "zh-Hans"))
        let engine = try await startedTranslation(translator, 0)
        engine.send(.started(info), .delta("季度"))
        await waitUntil("text arrives") { coordinator.job(for: source, operation: .translate)?.snapshot.hasText == true }
        let busy = try await occupyWriter(of: controller)

        coordinator.stop(source, operation: .translate)

        await waitUntil("the job ended") { coordinator.job(for: source, operation: .translate) == nil }
        guard case .saving("季度", _, let status)? = coordinator.outcome(for: source, operation: .translate) else {
            return XCTFail("\(String(describing: coordinator.outcome(for: source, operation: .translate)))")
        }
        XCTAssertEqual(status, .stopped, "Part of a translation, not a whole one")
        try await busy.value
        await waitUntil("the part is saved") { hasSettled(coordinator, source, .translate) }
        let saved = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(saved?.status, .stopped)
    }

    func testAStoppedTranslationTheLibraryCouldNotKeepIsSaidToBePartOfOne() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Unwritable", into: controller)
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        coordinator.translate(source, to: Locale.Language(identifier: "zh-Hans"))
        let engine = try await startedTranslation(translator, 0)
        engine.send(.started(info), .delta("季度"))
        await waitUntil("text arrives") { coordinator.job(for: source, operation: .translate)?.snapshot.hasText == true }
        try await controller.close()

        coordinator.stop(source, operation: .translate)

        await waitUntil("the job ended") { hasSettled(coordinator, source, .translate) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .translate),
                       .notSaved("季度", DerivedTextRequest(source: source, operation: .translate,
                                                           targetLanguage: "zh-Hans"), status: .stopped),
                       "Part of a translation, not a whole one")
    }

    func testAFailedTranslationSaysWhatItWasAskedFor() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Quarterly plan", into: controller)
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        coordinator.translate(source, to: Locale.Language(identifier: "zh-Hans"))
        try await startedTranslation(translator, 0).send(.started(info), .delta("季度计划"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, source, .translate) }
        let failure = GenerationError(kind: .languageNotDownloaded,
                                      message: "To translate from English to Japanese on this Mac, download both languages.")

        coordinator.translate(source, to: Locale.Language(identifier: "ja"))
        try await startedTranslation(translator, 1).end(throwing: failure)

        await waitUntil("the translation failed") { coordinator.failure(for: source, operation: .translate) != nil }
        XCTAssertEqual(coordinator.failedRequest(for: source, operation: .translate)?.targetLanguage, "ja")
        XCTAssertNil(coordinator.failedRequest(for: source, operation: .extractText))
    }

    func testAClipWithoutTextEndsWithNoTextAndNothingIsKept() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Picture", into: controller)
        let coordinator = try await makeCoordinator(
            controller, store, ScriptedRecognizer(),
            translator: OnDeviceTranslationEngine(translator: FakePairTranslator()),
            text: { _ in throw PasteboardWriterError.noPlainText })

        coordinator.translate(source, to: Locale.Language(identifier: "ja"))

        await waitUntil("the translation ends") { hasSettled(coordinator, source, .translate) }
        XCTAssertEqual(coordinator.outcome(for: source, operation: .translate), .noText)
        let saved = try await store.result(for: source, operation: .translate)
        XCTAssertNil(saved)
    }

    // MARK: Translating the text in an image

    func testTranslatingAnImageRecognizesItsTextFirstThenTranslatesThatText() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)

        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)

        let recognition = try await startedSource(recognizer, 0)
        XCTAssertEqual(recognizer.layouts, [true], "In the layout asked for")
        XCTAssertNil(translator.request(0), "Not before the text is known")
        recognition.send(.started(info), .delta("Open daily"), .finished(.completed))
        let translation = try await startedTranslation(translator, 0)
        let text = try await XCTUnwrap(translator.request(0)).text()
        XCTAssertEqual(text, "Open daily", "The text recognized in the image")
        translation.send(.started(info), .delta("Ouvert tous les jours"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, source, .translate) }
        // Both are kept beside the image.
        let recognized = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(recognized?.text, "Open daily")
        let translated = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(translated?.text, "Ouvert tous les jours")
        XCTAssertEqual(translated?.targetLanguage, "fr")
    }

    func testTextRecognizedBeforeIsTranslatedWithoutRecognizingAgain() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Poster", into: controller)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Kept text"]),
                                 for: DerivedTextRequest(source: source, operation: .extractText,
                                                         keepsLineBreaks: true))
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)

        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: false)

        _ = try await startedTranslation(translator, 0)
        let text = try await XCTUnwrap(translator.request(0)).text()
        XCTAssertEqual(text, "Kept text")
        XCTAssertNil(recognizer.source(0), "The text kept from before, in whatever layout it is in")
    }

    func testAnImageWithNoTextHasNothingToTranslate() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Blank", into: controller)

        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        try await startedSource(recognizer, 0).send(.started(info), .finished(.completed))

        await waitUntil("the translation says there is nothing to translate") {
            coordinator.outcome(for: source, operation: .translate) == .noText
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(0), "Nothing to translate")
    }

    func testARecognitionThatFailsLeavesNoTranslationAndSaysWhy() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)
        let failure = GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")

        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        try await startedSource(recognizer, 0).end(throwing: failure)

        await waitUntil("the translation says why") {
            coordinator.outcome(for: source, operation: .translate) == .failed(failure)
        }
        XCTAssertNil(translator.request(0))
    }

    func testStoppingWhileTheTextIsRecognizedStartsNoTranslation() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)

        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        let recognition = try await startedSource(recognizer, 0)
        recognition.send(.started(info))
        coordinator.stop(source, operation: .translate)

        await waitUntil("the recognition is stopped") { recognition.wasCancelled }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(0), "No translation follows a stopped recognition")
        XCTAssertNil(coordinator.job(for: source, operation: .extractText))
    }

    func testATranslationAskedForWhileTheTextIsRecognizedFollowsThatRecognition() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)

        coordinator.extractText(from: source, keepingLineBreaks: false)
        let recognition = try await startedSource(recognizer, 0)
        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(recognizer.source(1), "The recognition under way is the one translated")
        recognition.send(.started(info), .delta("Open daily"), .finished(.completed))

        _ = try await startedTranslation(translator, 0)
        let text = try await XCTUnwrap(translator.request(0)).text()
        XCTAssertEqual(text, "Open daily")
    }

    func testATranslationWaitingForTheTextFollowsTheRecognitionThatReplacesTheOneItWaitedFor() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)
        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        _ = try await startedSource(recognizer, 0)

        // Recognized again in the other layout, as Keep Line Breaks does.
        coordinator.extractText(from: source, keepingLineBreaks: false)
        try await startedSource(recognizer, 1).send(.started(info), .delta("Open daily"), .finished(.completed))

        _ = try await startedTranslation(translator, 0)
        let request = try XCTUnwrap(translator.request(0))
        let text = try await request.text()
        XCTAssertEqual(text, "Open daily", "The text of the recognition that ended")
    }

    func testStoppingTheRecognitionATranslationWaitsForStartsNoTranslation() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)
        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        let recognition = try await startedSource(recognizer, 0)
        XCTAssertNotNil(coordinator.translationWaitingForText(source))

        // Stopped where the text is shown, as ⌘. does in its column.
        coordinator.stop(source, operation: .extractText)

        await waitUntil("the recognition is stopped") { recognition.wasCancelled }
        await waitUntil("no translation waits") { coordinator.translationWaitingForText(source) == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(0))
    }

    func testStoppingATranslationOfAnImageBeforeItsTextIsReadStartsNothing() async throws {
        let (controller, store) = try await makeStore()
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let source = try await insertClip("Poster", into: controller)

        coordinator.translateImageUnlessMade(source, to: Locale.Language(identifier: "fr"), keepingLineBreaks: true)
        XCTAssertTrue(coordinator.isWaitingToStart(source, operation: .translate), "What was kept is read first")
        coordinator.stop(source, operation: .translate)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(recognizer.source(0), "Nothing is recognized")
        XCTAssertNil(translator.request(0), "Nothing is translated")
        XCTAssertNil(coordinator.translationWaitingForText(source))
    }

    // MARK: Languages to translate into

    func testTheLanguagesToTranslateIntoSayWhatEachNeedsFromTheTextsLanguage() async throws {
        let (controller, store) = try await makeStore()
        let translator = ScriptedTranslator()
        // Translation names languages with their regions, and English in two, which are downloaded apart.
        translator.script(languages: ["en-US", "zh-Hans-CN", "ja-JP", "en-GB", "fr-FR", "ja-JP"],
                          statuses: [("en", "ja-JP", .needsDownload), ("en", "fr-FR", .unsupported)])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)

        let fromEnglish = await coordinator.translationLanguages(from: Locale.Language(identifier: "en"))

        // Each language in each of its regions, once, asked about as Translation names it.
        XCTAssertEqual(fromEnglish.map(\.language),
                       ["en-US", "zh-Hans-CN", "ja-JP", "en-GB", "fr-FR"].map(Locale.Language.init(identifier:)))
        XCTAssertEqual(fromEnglish.map(\.status), [nil, .installed, .needsDownload, nil, .unsupported],
                       "Nothing is said of the text's own language, in either region")
        // Without the text's language, what each needs isn't known.
        let unknown = await coordinator.translationLanguages(from: nil)
        XCTAssertEqual(unknown.count, 5)
        XCTAssertEqual(unknown.map(\.status), [nil, nil, nil, nil, nil])
        // A text in a language this Mac doesn't translate from can be translated into none.
        let fromSwedish = await coordinator.translationLanguages(from: Locale.Language(identifier: "sv"))
        XCTAssertEqual(fromSwedish.map(\.status), Array(repeating: .unsupported, count: 5))
    }

    func testTheLanguageOfATextIsTheOneMostOfItIsIn() async throws {
        let (controller, store) = try await makeStore()
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer())

        let inEnglish = await coordinator.language(
            of: "The quarterly report is ready for review, and the team will meet on Thursday to discuss it.")
        XCTAssertEqual(inEnglish?.translationCode, "en")
        let mostlyChinese = await coordinator.language(
            of: "季度报告已经准备好了，团队将在星期四开会讨论预算和下一步的计划。\n\nThe budget is attached.")
        XCTAssertEqual(mostlyChinese?.translationCode, "zh-Hans", "The language most of it is in")
        let ofCode = await coordinator.language(of: "let total = items.reduce(0) { $0 + $1.price }\nprint(total)")
        XCTAssertNil(ofCode, "Code is in no language to tell")
        let ofNothing = await coordinator.language(of: "")
        XCTAssertNil(ofNothing)
        // A reader that stopped waiting is told nothing.
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.language(
                of: "The quarterly report is ready for review, and the team will meet on Thursday to discuss it.")
        }
        let toldNothing = await stopped.value
        XCTAssertNil(toldNothing)
    }

    func testTheTextRecognizedInAnImageIsKnownOnceItIsRecognized() async throws {
        let (controller, store) = try await makeStore()
        let sign = try await insertClip("Sign", into: controller)
        let blank = try await insertClip("Blank", into: controller)
        let kept = try await insertClip("Poster", into: controller)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info, texts: [.main: "Kept"]),
                                 for: DerivedTextRequest(source: kept, operation: .extractText, keepsLineBreaks: true))
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        XCTAssertNil(coordinator.recognizedText(in: sign), "Nothing was recognized yet")

        coordinator.extractText(from: sign, keepingLineBreaks: true)
        let recognition = try await startedSource(recognizer, 0)
        recognition.send(.started(info), .delta("Open daily"))
        XCTAssertNil(coordinator.recognizedText(in: sign), "Not while it is recognized")
        recognition.send(.finished(.completed))
        await waitUntil("the text is recognized") { hasSettled(coordinator, sign) }

        XCTAssertEqual(coordinator.recognizedText(in: sign), "Open daily")
        coordinator.extractText(from: blank, keepingLineBreaks: true)
        try await startedSource(recognizer, 1).send(.started(info), .finished(.completed))
        await waitUntil("no text is found") { hasSettled(coordinator, blank) }
        XCTAssertNil(coordinator.recognizedText(in: blank), "None was found")
        XCTAssertNil(coordinator.recognizedText(in: kept), "What the library kept is read apart, with the preview")
    }

    // MARK: Translating automatically

    nonisolated private static let french = "Le rapport trimestriel est attendu vendredi, avec les chiffres définitifs de chaque équipe."

    func testNewTextInAnotherLanguageIsTranslatedInTheBackgroundBehindWhatThePersonAskedFor() async throws {
        let (controller, store) = try await makeStore()
        let asked = try await insertClip("Asked", into: controller)
        let new = try await insertClip("New", into: controller)
        let later = try await insertClip("Later", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        let target = Locale.Language(identifier: "zh-Hans-CN")
        coordinator.translate(asked, to: target)
        let first = try await startedTranslation(translator, 0)

        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")
        await waitUntil("the background translation waits") { coordinator.job(for: new, operation: .translate) != nil }
        XCTAssertEqual(coordinator.job(for: new, operation: .translate)?.priority, .automatic)
        coordinator.translate(later, to: target)

        // What the person asks for after it goes ahead of it. Each request is made as its job is queued: the one in
        // the background first, then the later one.
        first.send(.started(info), .delta("报告"), .finished(.completed))
        let second = try await startedTranslation(translator, 2)
        XCTAssertEqual(coordinator.job(for: later, operation: .translate)?.hasStarted, true)
        XCTAssertEqual(coordinator.job(for: new, operation: .translate)?.hasStarted, false)
        second.send(.started(info), .delta("报告"), .finished(.completed))
        let third = try await startedTranslation(translator, 1)
        XCTAssertEqual(translator.request(1)?.target, target, "Into the language translations are made in")
        let text = try await translator.request(1)?.text()
        XCTAssertEqual(text, Self.french)
        // Made, it is kept as any translation is.
        third.send(.started(info), .delta("季度报告将于周五提交。"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, new, .translate) }
        let saved = try await store.result(for: new, operation: .translate)
        XCTAssertEqual(saved?.text, "季度报告将于周五提交。")
        XCTAssertEqual(saved?.targetLanguage, "zh-Hans")
    }

    func testAutomaticTranslationPassesOverTextItShouldntTranslate() async throws {
        let (controller, store) = try await makeStore()
        let texts: [(String, String)] = [
            ("in the target language", "季度报告将于周五提交，财务部门需要在中午之前拿到所有的数字和表格。"),
            ("code", "let total = items.map { $0.price }.reduce(0, +)\nprint(total)"),
            ("too short", "Bonjour"),
            ("too long", String(repeating: "Le rapport trimestriel est attendu vendredi. ", count: 120)),
            ("not downloaded", "Der Quartalsbericht ist am Freitag fällig, mit allen endgültigen Zahlen jedes Teams."),
            ("French", Self.french),
        ]
        var refs: [String: ContentRef] = [:]
        for (name, _) in texts { refs[name] = try await insertClip(name, into: controller) }
        let bodies = Dictionary(uniqueKeysWithValues: texts.map { (refs[$0.0]!, $0.1) })
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "de-DE", "zh-Hans-CN"],
                          statuses: [("de", "zh-Hans-CN", .needsDownload)])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { bodies[$0] ?? "" })

        for (name, _) in texts { coordinator.translateAutomatically(try XCTUnwrap(refs[name]), fixed: nil, lastUsed: "zh-Hans") }

        // Only text in another language, of no more than 5,000 characters, that this Mac translates from without a
        // download.
        _ = try await startedTranslation(translator, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(translator.request(1))
        for (name, _) in texts where name != "French" {
            XCTAssertNil(coordinator.job(for: try XCTUnwrap(refs[name]), operation: .translate), name)
        }
        XCTAssertNotNil(coordinator.job(for: try XCTUnwrap(refs["French"]), operation: .translate))
    }

    func testAnAutomaticTranslationThatFailsSaysNothingAndKeepsNothing() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })

        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")
        try await startedTranslation(translator, 0).end(throwing: GenerationError(
            kind: .languageNotDownloaded, message: "To translate from French to Chinese on this Mac, download both languages."))

        await waitUntil("the job ends") { coordinator.job(for: new, operation: .translate) == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(coordinator.outcome(for: new, operation: .translate), "Nobody asked, so nothing is said")
        XCTAssertNil(coordinator.failure(for: new, operation: .translate))
        let saved = try await store.result(for: new, operation: .translate)
        XCTAssertNil(saved)
    }

    func testATranslationThePersonAsksForGoesAheadOfTheSameOneWaitingInTheBackground() async throws {
        let (controller, store) = try await makeStore()
        let asked = try await insertClip("Asked", into: controller)
        let new = try await insertClip("New", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        let target = Locale.Language(identifier: "zh-Hans-CN")
        coordinator.translate(asked, to: target)
        let first = try await startedTranslation(translator, 0)
        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")
        await waitUntil("the background translation waits") { coordinator.job(for: new, operation: .translate) != nil }

        // Asked for by the person, as ⌘T asks, it is the person's: shown, and ahead of anything in the background.
        coordinator.translateUnlessMade(new, to: target)

        await waitUntil("it is the person's") { coordinator.job(for: new, operation: .translate)?.priority == .user }
        first.send(.started(info), .delta("报告"), .finished(.completed))
        // The person's request, made after the one in the background, is the one that runs, once.
        _ = try await startedTranslation(translator, 2)
        XCTAssertEqual(coordinator.job(for: new, operation: .translate)?.hasStarted, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(3), "Once")
    }

    func testAutomaticTranslationNeverReplacesWhatThePersonAskedForOrWhatWasMadeOrKept() async throws {
        let (controller, store) = try await makeStore()
        let asked = try await insertClip("Asked", into: controller)
        let kept = try await insertClip("Kept", into: controller)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Rapport gardé"]),
                                 for: DerivedTextRequest(source: kept, operation: .translate, targetLanguage: "ja"))
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        let job = try XCTUnwrap(coordinator.translate(asked, to: Locale.Language(identifier: "ja")))
        let engine = try await startedTranslation(translator, 0)

        coordinator.translateAutomatically(asked, fixed: nil, lastUsed: "zh-Hans")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(coordinator.job(for: asked, operation: .translate) === job)
        // Nor, once made, is it made again.
        engine.send(.started(info), .delta("四半期報告"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, asked, .translate) }
        coordinator.translateAutomatically(asked, fixed: nil, lastUsed: "zh-Hans")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(translator.request(1))
        // Nor is one kept from before, in whatever language it is in.
        coordinator.translateAutomatically(kept, fixed: nil, lastUsed: "zh-Hans")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(translator.request(1))
        XCTAssertNil(coordinator.job(for: kept, operation: .translate))
    }

    func testABackgroundTranslationGivesWayToWhatThePersonAsksForAndIsAskedAgainAfter() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let asked = try await insertClip("Asked", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")
        let background = try await startedTranslation(translator, 0)

        // What the person asks for doesn't wait for it: it stops, and the person's runs.
        coordinator.translate(asked, to: Locale.Language(identifier: "zh-Hans-CN"))

        let personal = try await startedTranslation(translator, 1)
        XCTAssertTrue(background.wasCancelled)
        XCTAssertEqual(coordinator.job(for: asked, operation: .translate)?.hasStarted, true)
        // It is asked for again, behind it, and nothing is said of it meanwhile.
        await waitUntil("it waits again") { coordinator.job(for: new, operation: .translate)?.priority == .automatic }
        XCTAssertNil(coordinator.outcome(for: new, operation: .translate))
        personal.send(.started(info), .delta("报告"), .finished(.completed))
        let again = try await startedTranslation(translator, 2)
        let text = try await translator.request(2)?.text()
        XCTAssertEqual(text, Self.french)
        again.send(.started(info), .delta("季度报告将于周五提交。"), .finished(.completed))
        await waitUntil("the translation is saved") { hasSettled(coordinator, new, .translate) }
        let saved = try await store.result(for: new, operation: .translate)
        XCTAssertEqual(saved?.text, "季度报告将于周五提交。")
    }

    func testWhatThePersonAsksForWhileABackgroundTranslationIsCheckedComesFirst() async throws {
        let (controller, store) = try await makeStore()
        let translated = try await insertClip("Translated", into: controller)
        let shown = try await insertClip("Shown", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        let target = Locale.Language(identifier: "zh-Hans-CN")
        translator.holdStatuses()
        coordinator.translateAutomatically(translated, fixed: nil, lastUsed: "zh-Hans")
        coordinator.translateAutomatically(shown, fixed: nil, lastUsed: "zh-Hans")
        await waitUntil("both are checked") { translator.waitingForStatus == 2 }

        // Meanwhile the person translates one, and asks to see the other's translation, as ⌘T does.
        let job = try XCTUnwrap(coordinator.translate(translated, to: target))
        coordinator.translateUnlessMade(shown, to: target)
        await waitUntil("the person's is asked for") { coordinator.job(for: shown, operation: .translate) != nil }
        translator.releaseStatuses()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(coordinator.job(for: translated, operation: .translate) === job, "The person's stays")
        XCTAssertEqual(coordinator.job(for: shown, operation: .translate)?.priority, .user)
        XCTAssertNil(translator.request(2), "Nothing starts in the background in their place")
    }

    func testNothingIsTranslatedInTheBackgroundOnceTheLibraryCloses() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        translator.holdStatuses()
        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")
        await waitUntil("it is checked") { translator.waitingForStatus == 1 }

        await coordinator.stopAndDrain()
        translator.releaseStatuses()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(translator.request(0))
    }

    func testNothingIsTranslatedInTheBackgroundByAnEngineThatIsntThisMacs() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let translator = ScriptedTranslator(tier: .cloud)
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })

        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(translator.request(0), "Copied text never leaves this Mac to be translated")
    }

    func testABackgroundTranslationIsMadeInTheFirstLanguageThePersonPrefersWithoutAChoice() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "ja-JP", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french }, preferredLanguages: { ["ja-JP", "en-US"] })

        coordinator.translateAutomatically(new, fixed: nil, lastUsed: nil)

        _ = try await startedTranslation(translator, 0)
        XCTAssertEqual(translator.request(0)?.target, Locale.Language(identifier: "ja-JP"))
    }

    func testABackgroundTranslationOfUpTo5000CharactersThatFindsNothingSaysNothing() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let longest = String(String(repeating: "Le rapport trimestriel est attendu vendredi. ", count: 120).prefix(5_000))
        XCTAssertEqual(longest.count, 5_000)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in longest })

        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")

        // 5,000 characters are translated; a translation that comes to nothing is said to nobody.
        try await startedTranslation(translator, 0).send(.started(info), .finished(.completed))
        await waitUntil("the job ends") { coordinator.job(for: new, operation: .translate) == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(coordinator.outcome(for: new, operation: .translate))
    }

    func testAskingForATranslationTheBackgroundIsMakingMakesItThePersons() async throws {
        let (controller, store) = try await makeStore()
        let new = try await insertClip("New", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "zh-Hans-CN"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator,
                                                    text: { _ in Self.french })
        coordinator.translateAutomatically(new, fixed: nil, lastUsed: "zh-Hans")
        _ = try await startedTranslation(translator, 0)

        coordinator.translateUnlessMade(new, to: Locale.Language(identifier: "zh-Hans-CN"))

        await waitUntil("it is the person's") { coordinator.job(for: new, operation: .translate)?.priority == .user }
        _ = try await startedTranslation(translator, 1)
    }

    // MARK: Helpers

    private func makeStore() async throws -> (PersistenceController, DerivedTextStore) {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, DerivedTextStore(controller: controller))
    }

    private func makeCoordinator(
        _ controller: PersistenceController, _ store: DerivedTextStore, _ recognizer: ScriptedRecognizer,
        translator: any TranslationEngine = ScriptedTranslator(),
        identity: StoreIdentity? = nil,
        image: @escaping @Sendable (ContentRef) async throws -> CGImage = { _ in
            throw PreviewLoadError.couldNotDecodeImage
        },
        text: @escaping @Sendable (ContentRef) async throws -> String = { _ in "Synthetic text" },
        preferredLanguages: @escaping @Sendable () -> [String] = { ["zh-Hans-CN", "en-US"] }
    ) async throws -> DerivedTextCoordinator {
        let current = try await controller.identity()
        let coordinator = DerivedTextCoordinator(store: store, identity: identity ?? current, recognizer: recognizer,
                                                 translator: translator, preferredLanguages: preferredLanguages,
                                                 image: image, text: text)
        addTeardownBlock { await coordinator.stopAndDrain() }
        return coordinator
    }

    /// A synthetic text clip copied a moment ago. The store keeps results for any current item, so a text clip stands
    /// in for an image here.
    private func insertClip(_ text: String, into controller: PersistenceController) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ItemValue(title: text, captureID: capture.id, historyEligible: true, lastCopiedAt: Date(),
                             copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// Whether the latest job for `source` has ended and its result, if any, has been saved.
    private func hasSettled(_ coordinator: DerivedTextCoordinator, _ source: ContentRef,
                            _ operation: DerivedTextOperation = .extractText) -> Bool {
        switch coordinator.outcome(for: source, operation: operation) {
        case nil, .saving?: false
        default: true
        }
    }

    /// Holds the main thread, so that what the main actor would do meanwhile waits behind it.
    private func holdMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Keeps the store's one writer busy for half a second, so that a save made meanwhile waits. Returns once the
    /// work holds the writer.
    private func occupyWriter(of controller: PersistenceController) async throws -> Task<Void, any Error> {
        let holding = expectation(description: "the writer is busy")
        let busy = Task.detached {
            try await controller.perform { _ in
                holding.fulfill()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        await fulfillment(of: [holding], timeout: 5)
        return busy
    }

    /// Fails if a result for `source` is saved within the next 300 milliseconds.
    private func assertNoResultAppears(for source: ContentRef, in store: DerivedTextStore,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<15 {
            if let saved = try await store.result(for: source, operation: .extractText) {
                return XCTFail("\(saved.text) was saved", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The recognizer's `index`th source, once its job has started reading it.
    private func started(_ recognizer: ScriptedRecognizer, _ index: Int) async throws -> ControlledSource {
        await waitUntil("source \(index) is read") { (recognizer.source(index)?.startCount ?? 0) > 0 }
        return try XCTUnwrap(recognizer.source(index))
    }
}

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [ContentRef] = []

    var refs: [ContentRef] { lock.withLock { read } }

    func record(_ ref: ContentRef) {
        lock.withLock { read.append(ref) }
    }
}
