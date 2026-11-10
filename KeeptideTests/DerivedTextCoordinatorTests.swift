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
                                                                 keepsLineBreaks: true)))

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
        guard case .saving("Total 12.80", _)? = coordinator.outcome(for: source, operation: .extractText) else {
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
                                                                    keepsLineBreaks: true)),
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
                                                                 keepsLineBreaks: true)),
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
        text: @escaping @Sendable (ContentRef) async throws -> String = { _ in "Synthetic text" }
    ) async throws -> DerivedTextCoordinator {
        let current = try await controller.identity()
        let coordinator = DerivedTextCoordinator(store: store, identity: identity ?? current, recognizer: recognizer,
                                                 translator: translator, image: image, text: text)
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

    /// The translator's `index`th source, once its job has started reading it.
    private func startedTranslation(_ translator: ScriptedTranslator, _ index: Int) async throws -> ControlledSource {
        await waitUntil("translation \(index) is read") { (translator.request(index)?.generation.startCount ?? 0) > 0 }
        return try XCTUnwrap(translator.request(index)?.generation)
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
