import XCTest
@testable import Keeptide

/// What a surface knows of the languages translations can be made in.
@MainActor
final class TranslationLanguageStateTests: XCTestCase {
    private static let french = "Le rapport trimestriel est attendu vendredi, avec les chiffres définitifs de chaque équipe."

    func testTranslationsAreMadeInTheFixedLanguageElseTheLastUsedElseTheFirstPreferredOffered() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "zh-Hans-CN", "fr-FR", "ja-JP"])
        let coordinator = try await makeCoordinator(translator)
        let languages = TranslationLanguageState(preferred: { ["zh-Hans-CN", "en-US"] })

        languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { languages.known.count == 4 }

        XCTAssertEqual(languages.target(fixed: nil, lastUsed: nil), Locale.Language(identifier: "zh-Hans-CN"))
        XCTAssertEqual(languages.target(fixed: nil, lastUsed: "fr"), Locale.Language(identifier: "fr-FR"))
        XCTAssertEqual(languages.target(fixed: "ja", lastUsed: "fr"), Locale.Language(identifier: "ja-JP"))
        // Where the text is in the language asked for already, the next one the person prefers that Translation
        // offers, else English: not Swedish, which it doesn't offer.
        let swedishReader = TranslationLanguageState(preferred: { ["zh-Hans-CN", "sv-SE"] })
        swedishReader.showAgain(in: coordinator)
        await waitUntil("the languages are read") { swedishReader.known.count == 4 }
        XCTAssertEqual(swedishReader.target(after: Locale.Language(identifier: "zh-Hans-CN")),
                       Locale.Language(identifier: "en-US"))
        XCTAssertEqual(languages.variant(of: Locale.Language(identifier: "fr")), Locale.Language(identifier: "fr-FR"))
    }

    func testTheMenuMarksWhatTranslatingAnItemsTextNeedsOnceItsLanguageIsTold() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "zh-Hans-CN", "fr-FR", "ja-JP"],
                          statuses: [("fr", "ja-JP", .needsDownload), ("fr", "zh-Hans-CN", .unsupported)])
        let coordinator = try await makeCoordinator(translator)
        let languages = TranslationLanguageState(preferred: { ["zh-Hans-CN", "en-US"] })
        let note = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                              digest: Data(repeating: 3, count: 32))
        languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { languages.known.count == 4 }
        func marks() -> [String: TranslationLanguageMenu.Note] {
            let menu = languages.menu(for: note, chosen: Locale.Language(identifier: "zh-Hans-CN"))
            return Dictionary((menu.preferred + menu.others).compactMap { item in item.note.map { (item.code, $0) } },
                              uniquingKeysWith: { first, _ in first })
        }
        XCTAssertEqual(marks(), [:], "Nothing is marked before the text's language is told")

        // Without text at hand, nothing is told yet.
        languages.readMarks(for: note, text: { nil }, in: coordinator)
        XCTAssertEqual(marks(), [:])
        languages.readMarks(for: note, text: { Self.french }, in: coordinator)

        await waitUntil("the marks are read") { !marks().isEmpty }
        XCTAssertEqual(marks(), ["ja": .notDownloaded, "zh-Hans": .notAvailable])
        let menu = languages.menu(for: note, chosen: Locale.Language(identifier: "zh-Hans-CN"))
        XCTAssertEqual(menu.preferred.first { $0.isChosen }?.code, "zh-Hans")
        // The marks are this item's own: another item's menu has none.
        let other = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                               digest: Data(repeating: 4, count: 32))
        XCTAssertTrue((languages.menu(for: other, chosen: Locale.Language(identifier: "en-US")).others
                        + languages.menu(for: other, chosen: Locale.Language(identifier: "en-US")).preferred)
                        .allSatisfy { $0.note == nil })
    }

    func testForgettingWhatWasShownReadsTheMarksAgainAndKeepsTheLanguagesOffered() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "zh-Hans-CN", "fr-FR", "ja-JP"],
                          statuses: [("fr", "ja-JP", .needsDownload)])
        let coordinator = try await makeCoordinator(translator)
        let languages = TranslationLanguageState(preferred: { ["zh-Hans-CN", "en-US"] })
        let note = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                              digest: Data(repeating: 5, count: 32))
        languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { languages.known.count == 4 }
        func japanese() -> TranslationLanguageMenu.Note? {
            languages.menu(for: note, chosen: Locale.Language(identifier: "zh-Hans-CN")).others
                .first { $0.code == "ja" }?.note
        }
        languages.readMarks(for: note, text: { Self.french }, in: coordinator)
        await waitUntil("the mark is read") { japanese() == .notDownloaded }

        // Changed meanwhile: shown again, the menu reads it again.
        translator.script(languages: ["en-US", "zh-Hans-CN", "fr-FR", "ja-JP"],
                          statuses: [("fr", "ja-JP", .unsupported)])
        languages.showAgain(in: coordinator)

        XCTAssertNil(japanese(), "Forgotten until read again")
        XCTAssertEqual(languages.known.count, 4, "The languages offered are kept")
        languages.readMarks(for: note, text: { Self.french }, in: coordinator)
        await waitUntil("read again") { japanese() == .notAvailable }
    }

    func testWhatTranslatingNeedsFillsInTheLanguagesOfferedBeforeTheyAreRead() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "zh-Hans-CN", "fr-FR", "ja-JP"],
                          statuses: [("fr", "ja-JP", .needsDownload)])
        let coordinator = try await makeCoordinator(translator)
        let languages = TranslationLanguageState(preferred: { ["zh-Hans-CN", "en-US"] })
        let note = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                              digest: Data(repeating: 7, count: 32))
        XCTAssertTrue(languages.known.isEmpty)

        languages.readMarks(for: note, text: { Self.french }, in: coordinator)

        await waitUntil("the languages offered are filled in") { languages.known.count == 4 }
    }

    func testReadsStopWhenCancelled() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "zh-Hans-CN", "fr-FR", "ja-JP"],
                          statuses: [("fr", "ja-JP", .needsDownload)])
        translator.holdStatuses()
        let coordinator = try await makeCoordinator(translator)
        let languages = TranslationLanguageState(preferred: { ["zh-Hans-CN", "en-US"] })
        let note = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                              digest: Data(repeating: 6, count: 32))
        languages.showAgain(in: coordinator)
        await waitUntil("the languages are read") { languages.known.count == 4 }
        languages.readMarks(for: note, text: { Self.french }, in: coordinator)
        await waitUntil("a status is asked for") { translator.waitingForStatus > 0 }

        languages.cancelReads()
        translator.releaseStatuses()

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(languages.menu(for: note, chosen: Locale.Language(identifier: "zh-Hans-CN")).others
            .allSatisfy { $0.note == nil })
    }

    // MARK: Helpers

    private func makeCoordinator(_ translator: ScriptedTranslator) async throws -> DerivedTextCoordinator {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let identity = try await controller.identity()
        let coordinator = DerivedTextCoordinator(store: DerivedTextStore(controller: controller), identity: identity,
                                                 recognizer: ScriptedRecognizer(), translator: translator,
                                                 preferredLanguages: { ["zh-Hans-CN", "en-US"] },
                                                 image: { _ in throw PreviewLoadError.couldNotDecodeImage },
                                                 text: { _ in "Synthetic text" })
        addTeardownBlock { await coordinator.stopAndDrain() }
        return coordinator
    }
}
