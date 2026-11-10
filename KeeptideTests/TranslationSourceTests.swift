import XCTest
@testable import Keeptide

/// The source a translation on this Mac hands a job: how it splits the text, works out each paragraph's language,
/// checks the languages are ready, sends the translation and fails. A fake stands in for Apple's Translation, and a
/// scripted judge for Natural Language, so these tests don't depend on the system's language model; one test runs the
/// real detection. The texts are synthetic.
@MainActor
final class TranslationSourceTests: XCTestCase {
    private let info = GenerationInfo(engine: "On this Mac", model: "test")
    private let english = "The quarterly report is due on Friday, and finance needs it by noon."
    private let english2 = "Please send your comments by Thursday afternoon at the latest."
    private let english3 = "Thanks for turning this around so quickly, everyone."
    private let chinese = "季度报告周五截止，财务需要在中午前拿到。"
    private let en = Locale.Language(identifier: "en")
    private let ja = Locale.Language(identifier: "ja")
    private let simplified = Locale.Language(identifier: "zh-Hans")

    func testTheMainLanguageOfATextIsToldOnlyWhileItIsWaitedFor() async {
        let text = "季度报告已经准备好了，团队将在星期四开会讨论预算和下一步的计划。\n\nThe budget is attached."
        XCTAssertEqual(TranslationSource.mainLanguage(of: text, supported: [])?.translationCode, "zh-Hans")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return TranslationSource.mainLanguage(of: text, supported: [])
        }
        let told = await cancelled.value
        XCTAssertNil(told, "Nothing is told once its task is cancelled")
    }

    func testParagraphsArriveInOrderAfterHowManyThereAre() async throws {
        let translator = FakePairTranslator()
        let source = makeSource([english, english2, english3], to: simplified, translator: translator,
                                judged: [english: sure(en), english2: sure(en), english3: sure(en)])

        let events = try await collect(source)

        XCTAssertEqual(events.prefix(2), [.started(info), .expecting(paragraphs: 3)])
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertEqual(text(of: events), ["zh: \(english)", "zh: \(english2)", "zh: \(english3)"].joined(separator: "\n\n"))
        XCTAssertEqual(translator.calls,
                       [.init(paragraphs: [english, english2, english3], source: "en", target: "zh-Hans")])
    }

    func testEachRunOfOneLanguageIsTranslatedFromIt() async throws {
        let translator = FakePairTranslator()
        let source = makeSource([english, english2, chinese, english3], to: ja, translator: translator,
                                judged: [english: sure(en), english2: sure(en), chinese: sure(simplified),
                                         english3: sure(en)])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), ["ja: \(english)", "ja: \(english2)", "ja: \(chinese)", "ja: \(english3)"]
            .joined(separator: "\n\n"))
        XCTAssertEqual(translator.calls, [
            .init(paragraphs: [english, english2], source: "en", target: "ja"),
            .init(paragraphs: [chinese], source: "zh-Hans", target: "ja"),
            .init(paragraphs: [english3], source: "en", target: "ja"),
        ])
    }

    func testNaturalLanguageTellsTheLanguagesOfAMixedText() async throws {
        let translator = FakePairTranslator()
        let source = TranslationSource(info: info, source: nil, target: ja, translator: translator) { [english, chinese] in
            [english, chinese].joined(separator: "\n\n")
        }

        _ = try await collect(source)

        XCTAssertEqual(translator.calls, [.init(paragraphs: [english], source: "en", target: "ja"),
                                          .init(paragraphs: [chinese], source: "zh-Hans", target: "ja")])
    }

    func testTextInTheTargetLanguageCodeAndLinksStayAsTheyAre() async throws {
        let translator = FakePairTranslator()
        let code = "let total = items.reduce(0) { $0 + $1.price }"
        let link = "https://example.com/reports/2026?id=42"
        let source = makeSource([english, chinese, code, link], to: simplified, translator: translator,
                                judged: [english: sure(en), chinese: sure(simplified), code: .notProse, link: .notProse])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), ["zh: \(english)", chinese, code, link].joined(separator: "\n\n"))
        XCTAssertTrue(events.contains(.expecting(paragraphs: 4)))
        XCTAssertEqual(translator.calls, [.init(paragraphs: [english], source: "en", target: "zh-Hans")])
    }

    func testAShortParagraphIsInTheTextsMainLanguage() async throws {
        let translator = FakePairTranslator()
        let source = makeSource(["Hi Tom,", english, english2], to: simplified, translator: translator,
                                judged: [english: sure(en), english2: sure(en)])

        _ = try await collect(source)

        XCTAssertEqual(translator.calls,
                       [.init(paragraphs: ["Hi Tom,", english, english2], source: "en", target: "zh-Hans")])
    }

    func testTheMainLanguageCountsACharacterOfChineseAsAWord() async throws {
        // Eighteen characters of Chinese outweigh thirty-odd letters of English.
        let translator = FakePairTranslator()
        let shortEnglish = "See the plan for this week, everyone."
        let source = makeSource([chinese, shortEnglish, "Hi Tom,"], to: ja, translator: translator,
                                judged: [chinese: sure(simplified), shortEnglish: sure(en)])

        _ = try await collect(source)

        XCTAssertEqual(translator.calls.last, .init(paragraphs: ["Hi Tom,"], source: "zh-Hans", target: "ja"))
    }

    func testAnUncertainParagraphIsInTheLikeliestLanguageThisMacKnows() async throws {
        let translator = FakePairTranslator()
        let likelyEnglish = "Okay then, see you all there."
        let likelySpanish = "Hasta luego, amigos del equipo."
        let likelyDanish = "Vi ses i morgen, venner."
        let source = makeSource([english, likelyEnglish, likelySpanish, likelyDanish], to: ja, translator: translator,
                                judged: [english: sure(en),
                                         likelyEnglish: .uncertain([Locale.Language(identifier: "nl"), en]),
                                         likelySpanish: .uncertain(["es", "pt", "it"].map(Locale.Language.init(identifier:))),
                                         likelyDanish: .uncertain(["da", "nb", "sv"].map(Locale.Language.init(identifier:)))],
                                narrowed: [likelyDanish: sure(Locale.Language(identifier: "de")),
                                           likelyEnglish: .uncertain([Locale.Language(identifier: "nl"), en]),
                                           likelySpanish: .uncertain(["es", "pt", "it"].map(Locale.Language.init(identifier:)))])

        let events = try await collect(source)

        // The main language where it is likely; else the likeliest this Mac knows. A paragraph likeliest in a
        // language it doesn't know isn't narrowed to one it does, and stays as it is.
        XCTAssertEqual(translator.calls, [.init(paragraphs: [english, likelyEnglish], source: "en", target: "ja"),
                                          .init(paragraphs: [likelySpanish], source: "es", target: "ja")])
        XCTAssertTrue(text(of: events).hasSuffix("\n\n\(likelyDanish)"))
    }

    func testAnUncertainParagraphIsNarrowedToTheLanguagesThisMacKnowsWhenTheLikeliestIsOne() async throws {
        let translator = FakePairTranslator()
        let dutch = "Tot morgen, iedereen."
        let source = makeSource([english, dutch], to: ja, translator: translator,
                                judged: [english: sure(en),
                                         dutch: .uncertain(["nl", "af"].map(Locale.Language.init(identifier:)))],
                                narrowed: [dutch: sure(Locale.Language(identifier: "nl"))])

        _ = try await collect(source)

        XCTAssertEqual(translator.calls.last, .init(paragraphs: [dutch], source: "nl", target: "ja"))
    }

    func testAChosenLanguageIsTheLanguageOfEveryParagraphNotInTheTarget() async throws {
        let translator = FakePairTranslator()
        let source = makeSource([english, chinese, "Hi Tom,"], from: Locale.Language(identifier: "fr"),
                                to: simplified, translator: translator,
                                judged: [english: sure(en), chinese: sure(simplified)])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), ["zh: \(english)", chinese, "zh: Hi Tom,"].joined(separator: "\n\n"))
        XCTAssertEqual(translator.calls, [
            .init(paragraphs: [english], source: "fr", target: "zh-Hans"),
            .init(paragraphs: ["Hi Tom,"], source: "fr", target: "zh-Hans"),
        ])
    }

    func testTextAlreadyInTheTargetLanguageSaysSo() async {
        let translator = FakePairTranslator()
        let source = makeSource([chinese], to: simplified, translator: translator, judged: [chinese: sure(simplified)])

        await assertFailure(source, kind: .alreadyInTargetLanguage,
                            message: "This text is already in Chinese (Simplified).")
        XCTAssertTrue(translator.calls.isEmpty)
    }

    func testTextWithNothingToTranslateFinishesWithoutText() async throws {
        let code = "let total = items.reduce(0) { $0 + $1.price }"
        for paragraphs in [[], [" "], [code, "https://example.com/a"]] {
            let translator = FakePairTranslator()
            let events = try await collect(makeSource(paragraphs, to: simplified, translator: translator,
                                                      judged: [code: .notProse, "https://example.com/a": .notProse]))

            XCTAssertEqual(events, [.started(info), .finished(.completed)], "\(paragraphs)")
            XCTAssertTrue(translator.calls.isEmpty, "\(paragraphs)")
        }
    }

    func testTextInNoLanguageItCanTellAsksWhichItIs() async {
        let mixed = "Hello 你好 Bonjour 안녕"
        let uncertain = LanguageJudgement.uncertain(["nl", "fr"].map(Locale.Language.init(identifier:)))
        let cases: [([String], [String: LanguageJudgement])] = [([mixed], [mixed: uncertain]), (["Hi Tom,", "Thanks!"], [:])]
        for (paragraphs, judged) in cases {
            let source = makeSource(paragraphs, to: simplified, translator: FakePairTranslator(), judged: judged)

            await assertFailure(source, kind: .sourceLanguageUnknown, message: "Choose the language this text is in.")
        }
    }

    func testLanguagesToDownloadAreNamedBeforeAnyText() async {
        let translator = FakePairTranslator()
        translator.statuses = [.init(source: en, target: ja): .needsDownload]
        let source = makeSource([chinese, english], to: ja, translator: translator,
                                judged: [chinese: sure(simplified), english: sure(en)])

        let error = await assertFailure(
            source, kind: .languageNotDownloaded,
            message: "To translate from English to Japanese on this Mac, download both languages.")
        XCTAssertEqual(error?.pair, TranslationPair(source: en, target: ja))
        XCTAssertTrue(translator.calls.isEmpty, "Nothing is translated until every language is ready")
    }

    func testTheTextsLanguageThisMacCantTranslateSaysSo() async {
        let traditional = Locale.Language(identifier: "zh-Hant")
        let translator = FakePairTranslator()
        translator.statuses = [.init(source: simplified, target: traditional): .unsupported]
        await assertFailure(makeSource([chinese], to: traditional, translator: translator,
                                       judged: [chinese: sure(simplified)]),
                            kind: .languagePairUnsupported,
                            message: "This Mac can't translate between Simplified and Traditional Chinese.")
        XCTAssertTrue(translator.calls.isEmpty)

        // A language Translation doesn't know at all is named.
        let swedish = "Rapporten ska vara klar på fredag och ekonomi behöver den före lunch."
        let other = FakePairTranslator()
        let error = await assertFailure(
            makeSource([swedish], to: simplified, translator: other,
                       judged: [swedish: sure(Locale.Language(identifier: "sv"))]),
            kind: .languagePairUnsupported, message: "This Mac can't translate from Swedish to Chinese (Simplified).")
        XCTAssertEqual(error?.pair?.source.languageCode?.identifier, "sv")
        XCTAssertTrue(other.calls.isEmpty)
    }

    func testAParagraphInALanguageThisMacCantTranslateStaysAsItIs() async throws {
        // A signature in Swedish under an English letter.
        let signature = "Med vänliga hälsningar och tack för hjälpen, Anna Svensson"
        let translator = FakePairTranslator()
        let source = makeSource([english, english2, signature], to: simplified, translator: translator,
                                judged: [english: sure(en), english2: sure(en),
                                         signature: sure(Locale.Language(identifier: "sv"))])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), ["zh: \(english)", "zh: \(english2)", signature].joined(separator: "\n\n"))
    }

    func testTextMostlyInTheTargetKeepsAParagraphThisMacCantTranslate() async throws {
        // A Chinese letter, to be read in Chinese, with a Swedish signature and a line of English.
        let letter = [chinese, chinese, chinese].joined()
        let signature = "Med vänliga hälsningar och tack för hjälpen, Anna Svensson"
        let thanks = "Thanks for the update, Tom."
        let translator = FakePairTranslator()
        let source = makeSource([letter, signature, thanks], to: simplified, translator: translator,
                                judged: [letter: sure(simplified), signature: sure(Locale.Language(identifier: "sv")),
                                         thanks: sure(en)])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), [letter, signature, "zh: \(thanks)"].joined(separator: "\n\n"))

        // Without the English line, nothing is left to translate.
        let rest = makeSource([letter, signature], to: simplified, translator: FakePairTranslator(),
                              judged: [letter: sure(simplified), signature: sure(Locale.Language(identifier: "sv"))])
        await assertFailure(rest, kind: .alreadyInTargetLanguage,
                            message: "This text is already in Chinese (Simplified).")
    }

    func testLanguagesFoundMissingWhileTranslatingAreToDownload() async {
        let translator = FakePairTranslator()
        translator.failures = [0: PairTranslationError.notDownloaded, 1: PairTranslationError.notDownloaded]
        let source = makeSource([english], to: simplified, translator: translator, judged: [english: sure(en)])

        await assertFailure(
            source, kind: .languageNotDownloaded,
            message: "To translate from English to Chinese (Simplified) on this Mac, download both languages.")
        XCTAssertEqual(translator.calls.count, 2, "Asked once more, as the status still says they are downloaded")
    }

    func testAFirstTranslationThatWronglyFindsItsLanguagesMissingIsAskedForOnceMore() async throws {
        // The system can say a downloaded language isn't, for a first translation.
        let translator = FakePairTranslator()
        translator.failures = [0: PairTranslationError.notDownloaded]
        let source = makeSource([english, english2], to: simplified, translator: translator,
                                judged: [english: sure(en), english2: sure(en)])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), ["zh: \(english)", "zh: \(english2)"].joined(separator: "\n\n"))
        XCTAssertEqual(translator.calls.count, 2)
    }

    func testLanguagesFoundUnsupportedOrUnknownWhileTranslatingSaySo() async {
        let cases: [(PairTranslationError, GenerationError.Kind, String)] = [
            (.unsupported, .languagePairUnsupported, "This Mac can't translate from English to Chinese (Simplified)."),
            (.languageUnknown, .sourceLanguageUnknown, "Choose the language this text is in."),
            (.failed, .engineUnavailable, "This text couldn't be translated on this Mac."),
        ]
        for (thrown, kind, message) in cases {
            let translator = FakePairTranslator()
            translator.failures = [0: thrown]
            await assertFailure(makeSource([english], to: simplified, translator: translator, judged: [english: sure(en)]),
                                kind: kind, message: message)
        }
    }

    func testATranslatorThatStopsShortFails() async {
        let translator = FakePairTranslator()
        translator.dropsLast = true
        let source = makeSource([english, english2], to: simplified, translator: translator,
                                judged: [english: sure(en), english2: sure(en)])

        await assertFailure(source, kind: .streamInterrupted, message: GenerationError.interrupted.message)
    }

    func testAnEmptyTranslationKeepsTheOriginalAndBlankLinesDontSplitAParagraph() async throws {
        let translator = FakePairTranslator()
        translator.outputs = [english: " \n", english2: "第一行\n\n第二行\n"]
        let source = makeSource([english, english2], to: simplified, translator: translator,
                                judged: [english: sure(en), english2: sure(en)])

        let events = try await collect(source)

        XCTAssertEqual(text(of: events), "\(english)\n\n第一行\n第二行")
    }

    func testFailuresSayWhatWentWrong() async {
        let reading: [(any Error, GenerationError.Kind, String)] = [
            (StoreError.notFound, .contentUnavailable, "This item changed or is no longer available."),
            (StoreError.staleReference, .contentUnavailable, "This item changed or is no longer available."),
            (PasteRefusal.contentUnavailable, .contentUnavailable, "This item changed or is no longer available."),
            (PasteboardWriterError.invalidRepresentationBytes(itemIndex: 0, representationIndex: 0),
             .contentUnavailable, "This item changed or is no longer available."),
            (CocoaError(.featureUnsupported), .engineUnavailable, "This text couldn't be translated on this Mac."),
        ]
        for (error, kind, message) in reading {
            let source = TranslationSource(info: info, source: nil, target: simplified,
                                           translator: FakePairTranslator()) { throw error }
            await assertFailure(source, kind: kind, message: message)
        }
        let unavailable = FakePairTranslator()
        unavailable.supported = []
        await assertFailure(makeSource([english], to: simplified, translator: unavailable, judged: [english: sure(en)]),
                            kind: .engineUnavailable, message: "Translation isn't available on this Mac.")
    }

    func testTextTooLongToTranslateOnThisMacSaysSo() async {
        let translator = FakePairTranslator()
        let long = String(repeating: "word ", count: TranslationSource.characterLimit / 5 + 1)
        let source = TranslationSource(info: info, source: nil, target: simplified, translator: translator) { long }

        await assertFailure(source, kind: .inputTooLarge, message: "This text is too long to translate on this Mac.")
        XCTAssertTrue(translator.calls.isEmpty)
    }

    func testAClipWithoutTextFinishesWithoutText() async throws {
        let source = TranslationSource(info: info, source: nil, target: simplified, translator: FakePairTranslator()) {
            throw PasteboardWriterError.noPlainText
        }

        let events = try await collect(source)

        XCTAssertEqual(events, [.started(info), .finished(.completed)])
    }

    func testStoppingTheJobStopsTheTranslation() async {
        let translator = FakePairTranslator()
        let started = expectation(description: "translation started")
        let cancelled = expectation(description: "translation cancelled")
        translator.hold = (started, cancelled)
        var options = GenerationJob.Options()
        options.publishInterval = .zero
        var final: GenerationSnapshot?
        let source = makeSource([english], to: simplified, translator: translator, judged: [english: sure(en)])
        let job = JobCenter().start(GenerationKey(item: "clip", action: "translate"), lane: .onDevice,
                                    priority: .user, options: options, source: source) { final = $0 }

        await fulfillment(of: [started], timeout: 5)
        job.stop()

        await fulfillment(of: [cancelled], timeout: 5)
        await waitUntil("the job ended") { final != nil }
        XCTAssertEqual(final?.phase, .stopped(.person))
    }

    // MARK: Helpers

    private func sure(_ language: Locale.Language) -> LanguageJudgement {
        .detected(language, confidence: 1)
    }

    /// A source for `paragraphs`, separated by blank lines, whose judge says what `judged` says of each paragraph, or
    /// that it is too short, and among Translation's languages what `narrowed` says, or else the same.
    private func makeSource(_ paragraphs: [String], from source: Locale.Language? = nil, to target: Locale.Language,
                            translator: FakePairTranslator, judged: [String: LanguageJudgement],
                            narrowed: [String: LanguageJudgement] = [:]) -> TranslationSource {
        let text = paragraphs.joined(separator: "\n\n")
        return TranslationSource(info: info, source: source, target: target, translator: translator,
                                 judge: { paragraph, constraints in
                                     (constraints == nil ? nil : narrowed[paragraph]) ?? judged[paragraph] ?? .tooShort
                                 },
                                 text: { text })
    }

    private func collect(_ source: TranslationSource) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in source.events() { events.append(event) }
        return events
    }

    private func text(of events: [GenerationEvent]) -> String {
        events.map { event in
            if case .delta(let text, _) = event { text } else { "" }
        }.joined()
    }

    @discardableResult
    private func assertFailure(_ source: TranslationSource, kind: GenerationError.Kind, message: String,
                               file: StaticString = #filePath, line: UInt = #line) async -> GenerationError? {
        do {
            _ = try await collect(source)
            XCTFail("The stream should fail with \(kind)", file: file, line: line)
        } catch let failure as GenerationError {
            XCTAssertEqual(failure.kind, kind, file: file, line: line)
            XCTAssertEqual(failure.message, message, file: file, line: line)
            return failure
        } catch {
            XCTFail("Expected a GenerationError, not \(error)", file: file, line: line)
        }
        return nil
    }
}

/// Stands in for Apple's Translation: it "translates" a paragraph by writing the target language's code before it,
/// and records each batch it is asked for.
final class FakePairTranslator: PairTranslator, @unchecked Sendable {
    struct Call: Equatable {
        var paragraphs: [String]
        var source: String
        var target: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// What each pair's status is; every other pair is downloaded.
    var statuses: [TranslationPair: TranslationPairStatus] = [:]
    var supported = ["ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru", "th", "tr",
                     "uk", "vi", "zh-Hans", "zh-Hant"].map { Locale.Language(identifier: $0) }
    /// An error the batch asked for at each index throws, before any paragraph.
    var failures: [Int: any Error] = [:]
    /// What a paragraph translates to, in place of the code before it.
    var outputs: [String: String] = [:]
    /// Leaves out the last paragraph of each batch, as a translator that stops short would.
    var dropsLast = false
    /// Makes a translation wait until it is cancelled, saying when it starts and when it is cancelled.
    var hold: (started: XCTestExpectation, cancelled: XCTestExpectation)?

    var calls: [Call] { lock.withLock { recorded } }

    func supportedLanguages() async -> [Locale.Language] { supported }

    func status(of pair: TranslationPair) async -> TranslationPairStatus {
        statuses.first { $0.key.source.isSameLanguage(as: pair.source) && $0.key.target.isSameLanguage(as: pair.target) }?
            .value ?? .installed
    }

    func translate(_ paragraphs: [String], _ pair: TranslationPair) -> AsyncThrowingStream<String, any Error> {
        let index = lock.withLock {
            recorded.append(Call(paragraphs: paragraphs, source: Self.code(pair.source), target: Self.code(pair.target)))
            return recorded.count - 1
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: (any Error).self)
        let failure = failures[index]
        let outputs = outputs
        let sent = dropsLast ? Array(paragraphs.dropLast()) : paragraphs
        let hold = hold
        let prefix = pair.target.languageCode?.identifier ?? "?"
        let work = Task {
            if let hold {
                await withTaskCancellationHandler {
                    hold.started.fulfill()
                    try? await Task.sleep(for: .seconds(60))
                } onCancel: {
                    hold.cancelled.fulfill()
                }
                continuation.finish(throwing: CancellationError())
                return
            }
            if let failure { return continuation.finish(throwing: failure) }
            for paragraph in sent { continuation.yield(outputs[paragraph] ?? "\(prefix): \(paragraph)") }
            continuation.finish()
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// "en", "zh-Hans", "ja": the language and, for Chinese, its script.
    static func code(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? "?"
        guard code == "zh" else { return code }
        return code + "-" + (Locale.Language(identifier: language.maximalIdentifier).script?.identifier ?? "?")
    }
}
