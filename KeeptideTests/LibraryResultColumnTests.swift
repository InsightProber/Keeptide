import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Keeptide

/// The text recognized in an image, beside the image in the Library's detail.
@MainActor
final class LibraryResultColumnTests: XCTestCase {
    private let info = GenerationInfo(engine: "On this Mac", model: "test")

    func testExtractingTextOpensTheColumnAndRecognizesTheImageOnce() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let recorder = Recorder()
        let column = LibraryResultColumn(services: {
            self.services(coordinator, keepsLineBreaks: false, recorder: recorder)
        })
        XCTAssertNil(column.ref)
        XCTAssertNil(column.textColumn)

        column.showText(image)

        XCTAssertEqual(column.ref, image)
        XCTAssertEqual(column.textColumn, .loading)
        XCTAssertEqual(recorder.said, ["Text in Image, on this Mac"])
        let engine = try await started(recognizer, 0)
        // In the layout Settings chooses.
        XCTAssertEqual(recognizer.layouts, [false])
        guard case .recognizing = column.textColumn else { return XCTFail("\(String(describing: column.textColumn))") }
        engine.send(.started(info), .delta("Quarterly plan"), .finished(.completed))
        await waitUntil("the text is made") {
            column.textColumn == .text("Quarterly plan", keepsLineBreaks: false, status: .complete)
        }
        XCTAssertEqual(column.text, "Quarterly plan")

        // Shown again, what was made shows: nothing is recognized again, and nothing is said again.
        column.showText(image)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognizer.layouts, [false])
        XCTAssertEqual(column.textColumn, .text("Quarterly plan", keepsLineBreaks: false, status: .complete))
        XCTAssertEqual(recorder.said, ["Text in Image, on this Mac"])
    }

    func testAFailureThatLeftTextKeptFromBeforeIsTriedAgainWhenAskedAgain() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        try await keep("Kept plan", of: image, in: store)
        let column = LibraryResultColumn(services: { self.services(coordinator) })
        column.showText(image)
        await waitUntil("the kept text shows") { column.text == "Kept plan" }
        column.extractText()
        try await started(recognizer, 0).end(throwing: GenerationError(kind: .engineUnavailable,
                                                                       message: "Synthetic failure."))
        await waitUntil("it failed beside the kept text") { column.textColumn?.isFailed == true }

        // Something was kept, so only asking again makes it try again.
        column.showText(image)

        _ = try await started(recognizer, 1)
    }

    func testTextKeptFromBeforeShowsWithoutRecognizingAgain() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        try await keep("Kept plan", of: image, in: store)
        let column = LibraryResultColumn(services: { self.services(coordinator) })

        column.showText(image)

        await waitUntil("the kept text shows") {
            column.textColumn == .text("Kept plan", keepsLineBreaks: true, status: .complete)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognizer.layouts, [])
    }

    func testShowingTheColumnAgainAfterAFailureTriesAgain() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let column = LibraryResultColumn(services: { self.services(coordinator) })
        column.showText(image)
        try await started(recognizer, 0).end(throwing: GenerationError(kind: .engineUnavailable,
                                                                       message: "Synthetic failure."))
        await waitUntil("it failed") { column.textColumn?.isFailed == true }

        column.showText(image)

        try await started(recognizer, 1).end(throwing: GenerationError(kind: .engineUnavailable,
                                                                       message: "Synthetic failure."))
        await waitUntil("it failed again") { column.textColumn?.isFailed == true }
        // Try Again in the column does the same.
        column.extractText()
        _ = try await started(recognizer, 2)
    }

    func testTheColumnClosesAsTheDetailMovesOnAndTheRecognitionGoesOn() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let other = try await insertClip("Diagram", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let column = LibraryResultColumn(services: { self.services(coordinator) })
        column.showText(image)
        let engine = try await started(recognizer, 0)

        // The detail goes on showing the image: the column stays.
        column.follow(image)
        XCTAssertEqual(column.ref, image)
        column.follow(other)

        XCTAssertNil(column.ref)
        XCTAssertNil(column.textColumn)
        XCTAssertNotNil(coordinator.job(for: image, operation: .extractText), "What the person asked for goes on")
        // Coming back doesn't open the column again by itself.
        column.follow(image)
        XCTAssertNil(column.ref)
        engine.send(.started(info), .delta("Quarterly plan"), .finished(.completed))
        await waitUntil("the text is kept") { self.hasSettled(coordinator, image) }
        let kept = try await store.result(for: image, operation: .extractText)
        XCTAssertEqual(kept?.text, "Quarterly plan")
    }

    func testClosingTheColumnForgetsWhatItSaid() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer())
        try await keep("Kept plan", of: image, in: store)
        let recorder = Recorder()
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) })
        column.showText(image)
        await waitUntil("the kept text shows") { column.text == "Kept plan" }
        _ = await column.saveAsSnippet()
        XCTAssertNotNil(column.saveMessage)

        column.close()

        XCTAssertNil(column.ref)
        XCTAssertNil(column.textColumn)
        XCTAssertNil(column.saveMessage)
        // Opened again, saving the text makes it a snippet again.
        column.showText(image)
        await waitUntil("the kept text shows again") { column.text == "Kept plan" }
        let again = await column.saveAsSnippet()
        XCTAssertEqual(again, "Text saved to Snippets")
    }

    func testASaveThatEndsAfterTheColumnClosedLeavesTheNextOpeningAlone() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer())
        try await keep("Kept plan", of: image, in: store)
        let recorder = Recorder()
        recorder.holdsSaves = true
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) })
        column.showText(image)
        await waitUntil("the kept text shows") { column.text == "Kept plan" }
        defer { recorder.releaseAll() }
        let first = Task { await column.saveAsSnippet() }
        await waitUntil("the save is under way") { recorder.held.count == 1 }
        // One save at a time: one asked for meanwhile saves nothing. One made by mistake goes on, so nothing waits.
        let meanwhile = Task { await column.saveAsSnippet() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.held.count, 1, "One save at a time")
        recorder.releaseSave(1)
        let meanwhileSaid = await meanwhile.value
        XCTAssertNil(meanwhileSaid)

        column.close()
        column.showText(image)
        await waitUntil("the kept text shows again") { column.text == "Kept plan" }
        // The new opening saves on its own, and the first save then ends saying nothing in it.
        let heldBefore = recorder.held.count
        let second = Task { await column.saveAsSnippet() }
        await waitUntil("the second save is under way") { recorder.held.count == heldBefore + 1 }
        recorder.releaseSave(0)
        let firstSaid = await first.value
        XCTAssertNil(firstSaid)
        XCTAssertNil(column.saveMessage)
        recorder.releaseSave(heldBefore)
        let secondSaid = await second.value

        XCTAssertEqual(secondSaid, "Text saved to Snippets")
        XCTAssertEqual(column.saveMessage, "Text saved to Snippets")
        XCTAssertEqual(recorder.saved, ["Kept plan", "Kept plan"])
        XCTAssertEqual(recorder.said.filter { $0 == "Text saved to Snippets" }.count, 1)
    }

    func testStoppingARecognitionLeavesTheTextKeptFromBefore() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        try await keep("Kept plan", of: image, in: store)
        let column = LibraryResultColumn(services: { self.services(coordinator) })
        column.showText(image)
        // The column, and the recognition it asked for unless something was made, each read what the store kept: until
        // both have, the request still waits on the store, and there is something to stop.
        await waitUntil("the kept text shows, and nothing waits to be recognized") {
            column.text == "Kept plan" && !column.canStop
        }
        column.extractText()
        _ = try await started(recognizer, 0)
        XCTAssertTrue(column.canStop)

        column.stop()

        await waitUntil("the kept text shows again") {
            column.textColumn == .text("Kept plan", keepsLineBreaks: true, status: .complete)
        }
        XCTAssertFalse(column.canStop)
    }

    func testCopyTakesTheWholeTextOrThePartGivenAndSaysSoForAMoment() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer())
        try await keep("Kept plan", of: image, in: store)
        let recorder = Recorder()
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) })
        XCTAssertFalse(column.copy(), "Nothing to copy while the column is closed")
        column.showText(image)
        await waitUntil("the kept text shows") { column.text == "Kept plan" }

        XCTAssertTrue(column.copy())
        XCTAssertTrue(column.isCopied)
        XCTAssertTrue(column.copy("plan"))

        XCTAssertEqual(recorder.copied, ["Kept plan", "plan"])
        XCTAssertEqual(recorder.said.filter { $0 == "Copied" }.count, 2)
        await waitUntil("the note goes", timeout: .seconds(3)) { !column.isCopied }
        // A clipboard that can't be written says nothing.
        recorder.copyFails = true
        XCTAssertFalse(column.copy())
        XCTAssertFalse(column.isCopied)
        XCTAssertEqual(recorder.said.filter { $0 == "Copied" }.count, 2)
    }

    func testSavingTheTextMakesItASnippetOnceAndSaysSo() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let other = try await insertClip("Diagram", into: controller)
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer())
        try await keep("Kept plan", of: image, in: store)
        try await keep("Kept diagram", of: other, in: store)
        let recorder = Recorder()
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) })
        column.showText(image)
        await waitUntil("the kept text shows") { column.text == "Kept plan" }

        let first = await column.saveAsSnippet()
        let second = await column.saveAsSnippet()

        XCTAssertEqual(first, "Text saved to Snippets")
        XCTAssertEqual(second, "Already in Snippets")
        XCTAssertEqual(column.saveMessage, "Already in Snippets")
        XCTAssertEqual(recorder.saved, ["Kept plan"])
        XCTAssertEqual(Array(recorder.said.suffix(2)), ["Text saved to Snippets", "Already in Snippets"])

        // A save that fails says so, and saves nothing.
        recorder.saveFails = true
        column.follow(other)
        column.showText(other)
        await waitUntil("the other kept text shows") { column.text == "Kept diagram" }
        let failed = await column.saveAsSnippet()
        XCTAssertEqual(failed, "The text couldn't be saved. Try again.")
        XCTAssertEqual(recorder.saved, ["Kept plan"])
    }

    func testNothingIsCopiedOrSavedWhileTheTextIsBeingMade() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let recorder = Recorder()
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) })
        column.showText(image)
        let engine = try await started(recognizer, 0)
        engine.send(.started(info), .delta("Quarterly"))
        await waitUntil("part of it is made") {
            if case .recognizing(let snapshot) = column.textColumn { return snapshot.hasText }
            return false
        }

        XCTAssertNil(column.text)
        XCTAssertFalse(column.copy())
        let saved = await column.saveAsSnippet()

        XCTAssertNil(saved)
        XCTAssertEqual(recorder.copied, [])
        XCTAssertEqual(recorder.saved, [])
    }

    func testAnEndingWithoutTextIsSaidOnceAndWhatTheColumnOpensOnIsOnlyShown() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let column = LibraryResultColumn(services: { self.services(coordinator) })
        column.showText(image)
        XCTAssertNil(column.endingToAnnounce())
        let engine = try await started(recognizer, 0)
        XCTAssertNil(column.endingToAnnounce())

        engine.send(.started(info), .finished(.completed))
        await waitUntil("it found no text") { column.textColumn == .noText }

        XCTAssertEqual(column.endingToAnnounce(), TextColumnWords.noText)
        XCTAssertNil(column.endingToAnnounce(), "Said once")
        XCTAssertTrue(column.isJustMade)
        // Opened again on the same ending, it is only shown.
        column.close()
        column.showText(image)
        XCTAssertNil(column.endingToAnnounce())
    }

    func testWithoutTheLibraryTheColumnShowsNothing() async throws {
        let (controller, _) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let column = LibraryResultColumn(services: { nil })

        column.showText(image)

        XCTAssertNil(column.textColumn)
        XCTAssertFalse(column.copy())
        let saved = await column.saveAsSnippet()
        XCTAssertNil(saved)
    }

    func testEscapeInTheTextClosesTheColumnAndCommandPeriodOnlyStopsARecognition() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let column = LibraryResultColumn(services: { self.services(coordinator) })
        column.showText(image)
        _ = try await started(recognizer, 0)

        XCTAssertFalse(LibraryResultKeys.handle(try key("a", code: kVK_ANSI_A), column), "Text keys are the text's")
        XCTAssertTrue(LibraryResultKeys.handle(try key(".", code: kVK_ANSI_Period, modifiers: .command), column))
        await waitUntil("it stopped") { !column.canStop }
        // With nothing to stop, ⌘. does nothing: one pressed just as a recognition ends never closes the column. ⇧⌘.
        // is ⌘. where the keyboard needs Shift for the full stop.
        XCTAssertTrue(LibraryResultKeys.handle(try key(".", code: kVK_ANSI_Period, modifiers: .command), column))
        XCTAssertTrue(LibraryResultKeys.handle(try key(".", code: kVK_ANSI_Period, modifiers: [.command, .shift]),
                                               column))
        XCTAssertEqual(column.ref, image)
        // Held down, Escape has acted already; with Caps Lock on, it is Escape all the same.
        XCTAssertTrue(LibraryResultKeys.handle(try key("\u{1b}", code: kVK_Escape, isARepeat: true), column))
        XCTAssertEqual(column.ref, image)
        XCTAssertTrue(LibraryResultKeys.handle(try key("\u{1b}", code: kVK_Escape, modifiers: .capsLock), column))
        XCTAssertNil(column.ref)
    }

    // MARK: Translation

    func testTranslatingATextShowsItsTranslationInTheLanguageTranslationsAreMadeIn() async throws {
        let (controller, store) = try await makeStore()
        let note = try await insertClip("Note", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "ja-JP"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        let recorder = Recorder()
        recorder.lastUsedTarget = "fr"
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) },
                                         preferredLanguages: { ["en-US"] })
        column.languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { column.languages.known.count == 3 }

        column.showTranslation(note, isImage: false, itemText: "Synthetic note.")

        XCTAssertEqual(column.showing, .translation)
        XCTAssertNil(column.textColumn)
        XCTAssertEqual(recorder.said, ["Translation, on this Mac"])
        let engine = try await startedTranslation(translator, 0)
        XCTAssertEqual(translator.request(0)?.target, Locale.Language(identifier: "fr-FR"), "The last used one")
        engine.send(.started(info), .delta("Note synthétique."), .finished(.completed))
        await waitUntil("the translation is made") {
            column.translationColumn == .translation("Note synthétique.", into: "fr", status: .complete)
        }
        XCTAssertEqual(column.text, "Note synthétique.")
        // Shown again, what was made shows.
        column.showTranslation(note, isImage: false, itemText: "Synthetic note.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(1))
    }

    func testChoosingALanguageTranslatesIntoItAndKeepsItForQuickAccessToo() async throws {
        let (controller, store) = try await makeStore()
        let note = try await insertClip("Note", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "ja-JP"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        let recorder = Recorder()
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) },
                                         preferredLanguages: { ["en-US"] })
        column.languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { column.languages.known.count == 3 }
        column.showTranslation(note, isImage: false, itemText: "Synthetic note.")
        try await startedTranslation(translator, 0).send(.started(info), .delta("Synthetic note."),
                                                         .finished(.completed))
        await waitUntil("the first translation is made") { column.text != nil }

        column.chooseLanguage("ja")

        XCTAssertEqual(recorder.lastUsedTarget, "ja")
        _ = try await startedTranslation(translator, 1)
        XCTAssertEqual(translator.request(1)?.target, Locale.Language(identifier: "ja-JP"))
        XCTAssertEqual(column.languageMenu.others.first { $0.isChosen }?.code ?? column.languageMenu.preferred
            .first { $0.isChosen }?.code, "ja")
        // Chosen again while it is made in it, nothing more is asked for.
        column.chooseLanguage("ja")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(translator.request(2))
    }

    func testTheTextInAnImageIsRecognizedBeforeItIsTranslated() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR"])
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let recorder = Recorder()
        recorder.lastUsedTarget = "fr"
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) },
                                         preferredLanguages: { ["en-US"] })
        column.languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { column.languages.known.count == 2 }

        column.showTranslation(image, isImage: true, itemText: nil)

        try await started(recognizer, 0).send(.started(info), .delta("Quarterly plan"), .finished(.completed))
        let engine = try await startedTranslation(translator, 0)
        engine.send(.started(info), .delta("Plan trimestriel"), .finished(.completed))
        await waitUntil("the translation is made") {
            column.translationColumn == .translation("Plan trimestriel", into: "fr", status: .complete)
        }
    }

    func testOneColumnShowsAtATimeAndAJobGoesOnWhenItsColumnIsLeft() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR"])
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let column = LibraryResultColumn(services: { self.services(coordinator) }, preferredLanguages: { ["en-US"] })
        column.showText(image)
        _ = try await started(recognizer, 0)

        column.showTranslation(image, isImage: true, itemText: nil)

        XCTAssertEqual(column.showing, .translation)
        XCTAssertNil(column.textColumn)
        XCTAssertNotNil(coordinator.job(for: image, operation: .extractText), "The recognition goes on")
        column.showText(image)
        XCTAssertEqual(column.showing, .text)
        XCTAssertNil(column.translationColumn)
    }

    func testATranslationIsCopiedAndSavedAsATranslation() async throws {
        let (controller, store) = try await makeStore()
        let note = try await insertClip("Note", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Note gardée"]),
                                 for: DerivedTextRequest(source: note, operation: .translate, targetLanguage: "fr"))
        let recorder = Recorder()
        let column = LibraryResultColumn(services: { self.services(coordinator, recorder: recorder) },
                                         preferredLanguages: { ["en-US"] })
        column.showTranslation(note, isImage: false, itemText: "Synthetic note.")
        await waitUntil("the kept translation shows") { column.text == "Note gardée" }
        XCTAssertNil(translator.request(0), "What was kept isn't made again")

        XCTAssertTrue(column.copy())
        let saved = await column.saveAsSnippet()

        XCTAssertEqual(recorder.copied, ["Note gardée"])
        XCTAssertEqual(saved, "Translation saved to Snippets")
        XCTAssertEqual(recorder.saved, ["Note gardée"])
    }

    func testSwitchingBetweenAnImagesColumnsOnlyShowsWhatEachOpensOn() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR"])
        let coordinator = try await makeCoordinator(controller, store, recognizer, translator: translator)
        let column = LibraryResultColumn(services: { self.services(coordinator) }, preferredLanguages: { ["en-US"] })
        column.showTranslation(image, isImage: true, itemText: nil)
        XCTAssertNil(column.endingToAnnounce())
        try await started(recognizer, 0).send(.started(info), .finished(.completed))
        await waitUntil("it found no text to translate") {
            if case .noTextInImage? = column.translationColumn { return true }
            return false
        }
        XCTAssertNotNil(column.endingToAnnounce(), "The translation's ending is said")

        column.showText(image)

        XCTAssertEqual(column.textColumn, .noText)
        XCTAssertNil(column.endingToAnnounce(), "Opened on its ending, the text column only shows it")
    }

    func testAnEditedTextKeepsItsTranslationColumnAndOffersToTranslateItAgain() async throws {
        let (controller, store) = try await makeStore()
        let note = try await insertClip("Note", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Note gardée"]),
                                 for: DerivedTextRequest(source: note, operation: .translate, targetLanguage: "fr"))
        let column = LibraryResultColumn(services: { self.services(coordinator) }, preferredLanguages: { ["en-US"] })
        column.showTranslation(note, isImage: false, itemText: "Synthetic note.")
        await waitUntil("the kept translation shows") { column.text == "Note gardée" }

        // Saved after an edit, the same item is another version: its translation is to be made again.
        let edited = ContentRef(itemID: note.itemID, facet: note.facet, version: ContentVersion(),
                                digest: Data(repeating: 9, count: 32))
        column.follow(edited, itemText: "Synthetic note, edited.")

        XCTAssertEqual(column.ref, edited)
        XCTAssertEqual(column.showing, .translation)
        await waitUntil("it offers to translate the edited text") { column.translationColumn == .notStarted }
        XCTAssertNil(translator.request(0), "Nothing is translated until asked")
    }

    func testChoosingTheLanguageOfATranslationKeptFromBeforeShowsItWithoutTranslatingAgain() async throws {
        let (controller, store) = try await makeStore()
        let note = try await insertClip("Note", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR"])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info,
                                                    texts: [.main: "Note gardée"]),
                                 for: DerivedTextRequest(source: note, operation: .translate, targetLanguage: "fr"))
        let column = LibraryResultColumn(services: { self.services(coordinator) }, preferredLanguages: { ["en-US"] })
        column.languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { column.languages.known.count == 2 }

        column.chooseLanguage("fr", for: note, isImage: false, itemText: "Synthetic note.")

        await waitUntil("the kept translation shows") { column.text == "Note gardée" }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(translator.request(0), "A whole translation in that language was kept")
    }

    func testTheLanguageMenuMarksWhatTranslatingTheItemNeeds() async throws {
        let (controller, store) = try await makeStore()
        let note = try await insertClip("Note", into: controller)
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "fr-FR", "ja-JP"], statuses: [("fr", "ja-JP", .needsDownload)])
        let coordinator = try await makeCoordinator(controller, store, ScriptedRecognizer(), translator: translator)
        let column = LibraryResultColumn(services: { self.services(coordinator) }, preferredLanguages: { ["en-US"] })
        column.languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { column.languages.known.count == 3 }
        let french = "Le rapport trimestriel est attendu vendredi, avec les chiffres définitifs de chaque équipe."

        column.showTranslation(note, isImage: false, itemText: french)
        column.readLanguageMarks()

        await waitUntil("the marks are read") {
            column.languageMenu.others.first { $0.code == "ja" }?.note == .notDownloaded
        }
    }

    // MARK: Helpers

    private func key(_ characters: String, code: Int, modifiers: NSEvent.ModifierFlags = [],
                     isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: isARepeat,
                                       keyCode: UInt16(code)))
    }

    /// What the column's copies, saves and announcements came to. With `holdsSaves`, each save waits until the test
    /// lets it go on.
    private final class Recorder {
        var copied: [String] = []
        var saved: [String] = []
        var said: [String] = []
        var copyFails = false
        var saveFails = false
        var holdsSaves = false
        var fixedTarget: String?
        var lastUsedTarget: String?
        var held: [CheckedContinuation<Void, Never>] = []
        private var released: Set<Int> = []

        /// Lets the `index`th save go on, where it is waiting still.
        func releaseSave(_ index: Int) {
            guard held.indices.contains(index), released.insert(index).inserted else { return }
            held[index].resume()
        }

        /// Lets every save still waiting go on.
        func releaseAll() { held.indices.forEach(releaseSave) }
    }

    private struct SyntheticSaveFailure: Error {}

    private func services(_ coordinator: DerivedTextCoordinator, keepsLineBreaks: Bool = true,
                          recorder: Recorder = Recorder()) -> LibraryResultColumn.Services {
        LibraryResultColumn.Services(
            derivedText: coordinator,
            copyText: { text in
                guard !recorder.copyFails else { return false }
                recorder.copied.append(text)
                return true
            },
            saveSnippet: { text in
                if recorder.holdsSaves { await withCheckedContinuation { recorder.held.append($0) } }
                if recorder.saveFails { throw SyntheticSaveFailure() }
                recorder.saved.append(text)
            },
            keepsLineBreaks: { keepsLineBreaks },
            announce: { recorder.said.append($0) },
            translationTargets: { (recorder.fixedTarget, recorder.lastUsedTarget) },
            keepLastUsed: { recorder.lastUsedTarget = $0 }
        )
    }

    private func keep(_ text: String, of source: ContentRef, in store: DerivedTextStore) async throws {
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info, texts: [.main: text]),
                                 for: DerivedTextRequest(source: source, operation: .extractText,
                                                         keepsLineBreaks: true))
    }

    private func makeStore() async throws -> (PersistenceController, DerivedTextStore) {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, DerivedTextStore(controller: controller))
    }

    private func makeCoordinator(_ controller: PersistenceController, _ store: DerivedTextStore,
                                 _ recognizer: ScriptedRecognizer,
                                 translator: ScriptedTranslator = ScriptedTranslator()) async throws
        -> DerivedTextCoordinator {
        let identity = try await controller.identity()
        let coordinator = DerivedTextCoordinator(store: store, identity: identity, recognizer: recognizer,
                                                 translator: translator,
                                                 preferredLanguages: { ["en-US"] },
                                                 image: { _ in throw PreviewLoadError.couldNotDecodeImage },
                                                 text: { _ in "Synthetic text" })
        addTeardownBlock { await coordinator.stopAndDrain() }
        return coordinator
    }

    /// A synthetic clip copied a moment ago. The store keeps results for any current item, so a text clip stands in
    /// for an image here.
    private func insertClip(_ text: String, into controller: PersistenceController) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ItemValue(title: text, captureID: capture.id, historyEligible: true, lastCopiedAt: Date(),
                             copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// Whether the latest recognition of `source` has ended and its text, if any, has been saved.
    private func hasSettled(_ coordinator: DerivedTextCoordinator, _ source: ContentRef) -> Bool {
        switch coordinator.outcome(for: source, operation: .extractText) {
        case nil, .saving?: false
        default: true
        }
    }

    /// The recognizer's `index`th source, once its job has started reading it.
    private func started(_ recognizer: ScriptedRecognizer, _ index: Int) async throws -> ControlledSource {
        await waitUntil("source \(index) is read") { (recognizer.source(index)?.startCount ?? 0) > 0 }
        return try XCTUnwrap(recognizer.source(index))
    }
}
