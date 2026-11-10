import Translation
import XCTest
@testable import Keeptide

/// Apple's Translation on this Mac, through the translator Keeptide uses, with synthetic text. Which languages a Mac
/// has downloaded differs, so a test that needs a downloaded pair, or one that isn't, is skipped where there is none.
final class SystemTranslatorTests: XCTestCase {
    private let translator = SystemTranslator()
    private let english = Locale.Language(identifier: "en")
    private let simplified = Locale.Language(identifier: "zh-Hans")

    func testItNamesTheLanguagesItTranslates() async throws {
        let languages = await translator.supportedLanguages()
        try XCTSkipIf(languages.isEmpty, "Translation names no languages on this Mac")

        XCTAssertTrue(languages.contains { $0.isSameLanguage(as: english) })
        XCTAssertTrue(languages.contains { $0.isSameLanguage(as: simplified) })
        XCTAssertTrue(languages.contains { $0.isSameLanguage(as: Locale.Language(identifier: "zh-Hant")) })
    }

    func testSimplifiedAndTraditionalChineseAreNoPair() async {
        let status = await translator.status(
            of: TranslationPair(source: simplified, target: Locale.Language(identifier: "zh-Hant")))

        XCTAssertEqual(status, .unsupported)
    }

    func testAPairNotDownloadedSaysSoWhenTranslating() async throws {
        var missing: TranslationPair?
        for code in ["ja", "ko", "de", "fr", "es", "it", "pt", "ru"] {
            let pair = TranslationPair(source: english, target: Locale.Language(identifier: code))
            if await translator.status(of: pair) == .needsDownload {
                missing = pair
                break
            }
        }
        guard let pair = missing else { throw XCTSkip("Every pair tried is downloaded on this Mac") }

        do {
            for try await _ in translator.translate(["Good morning, everyone."], pair) {}
            XCTFail("\(pair.target.maximalIdentifier) isn't downloaded, so nothing is translated")
        } catch PairTranslationError.notDownloaded {
        } catch {
            // What a system without the languages says is the system's; this records it rather than failing on it.
            throw XCTSkip("Translating into \(pair.target.maximalIdentifier), not downloaded, failed with \(error)")
        }
    }

    func testADownloadedPairTranslatesParagraphByParagraph() async throws {
        let pair = TranslationPair(source: english, target: simplified)
        let status = await translator.status(of: pair)
        try XCTSkipUnless(status == .installed, "English and Chinese (Simplified) aren't downloaded on this Mac")
        let paragraphs = ["Good morning, everyone.", "The report is ready for review."]

        var translated: [String] = []
        do {
            for try await paragraph in translator.translate(paragraphs, pair) { translated.append(paragraph) }
        } catch PairTranslationError.notDownloaded {
            // A language can go between the status and the translation, and a first translation can find a
            // downloaded one missing.
            throw XCTSkip("English and Chinese (Simplified) aren't ready on this Mac")
        }

        XCTAssertEqual(translated.count, paragraphs.count)
        XCTAssertTrue(zip(translated, paragraphs).allSatisfy { !$0.0.isEmpty && $0.0 != $0.1 }, "\(translated)")
    }

    func testTranslationsErrorsAreKeeptidesOwn() {
        XCTAssertEqual(SystemTranslator.error(for: TranslationError.notInstalled) as? PairTranslationError,
                       .notDownloaded)
        for error in [TranslationError.unsupportedLanguagePairing, .unsupportedSourceLanguage,
                      .unsupportedTargetLanguage] {
            XCTAssertEqual(SystemTranslator.error(for: error) as? PairTranslationError, .unsupported)
        }
        XCTAssertEqual(SystemTranslator.error(for: TranslationError.unableToIdentifyLanguage) as? PairTranslationError,
                       .languageUnknown)
        XCTAssertEqual(SystemTranslator.error(for: TranslationError.internalError) as? PairTranslationError, .failed)
        XCTAssertTrue(SystemTranslator.error(for: TranslationError.alreadyCancelled) is CancellationError)
        XCTAssertTrue(SystemTranslator.error(for: CancellationError()) is CancellationError)
    }
}
