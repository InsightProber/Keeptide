import Foundation

/// Whether this Mac can translate between two languages now.
enum TranslationPairStatus: Equatable, Sendable {
    case installed
    /// The system can, once both languages are downloaded.
    case needsDownload
    case unsupported
}

/// Why a translator on this Mac couldn't translate, in Keeptide's terms rather than the framework's.
enum PairTranslationError: Error, Equatable {
    /// Its languages aren't downloaded.
    case notDownloaded
    /// This Mac can't translate between them.
    case unsupported
    /// It couldn't tell the language of the text.
    case languageUnknown
    /// It failed for another reason.
    case failed
}

/// Apple's Translation as a translation uses it, so that tests can stand in for it.
protocol PairTranslator: Sendable {
    /// The languages it translates from and to.
    func supportedLanguages() async -> [Locale.Language]
    func status(of pair: TranslationPair) async -> TranslationPairStatus
    /// Translates paragraphs that are all in `pair.source`, one after another: one translated paragraph for each, in
    /// order. It stops once the stream is no longer read. It throws `PairTranslationError`, or `CancellationError`
    /// once stopped.
    func translate(_ paragraphs: [String], _ pair: TranslationPair) -> AsyncThrowingStream<String, any Error>
}

/// The source for a translation on this Mac. Once its stream is read, it reads the text and splits it into paragraphs
/// at blank lines.
///
/// Each paragraph's language is detected, unless a person said which the text is in. A paragraph too short to tell is
/// in the text's main language, and one Natural Language is unsure of is in the main language where that is likely, or
/// else in the likeliest language this Mac translates. Paragraphs already in the target language, code, links and
/// numbers stay as they are, and so does a paragraph in a language this Mac can't translate from, unless most of the
/// text is in it. Before any text, it checks that every other language is downloaded. Then it says how many paragraphs
/// there are and sends each as it is translated, a run of paragraphs in one language at a time, as Translation takes
/// one language at a time. With nothing to translate, it finishes without text.
struct TranslationSource: GenerationSource {
    /// The most text one translation takes: about half a minute's work on this Mac, so that it can't hold the queue
    /// that text recognition also waits in for long.
    static let characterLimit = 100_000
    /// How long it waits before asking once more for a translation whose downloaded languages were found missing.
    static let retryDelay: Duration = .milliseconds(300)

    var info: GenerationInfo
    /// The language a person said the text is in; nil to detect it, paragraph by paragraph.
    var source: Locale.Language?
    var target: Locale.Language
    var translator: any PairTranslator
    /// Tells a paragraph's language, among the given languages when there are any.
    var judge: @Sendable (String, [Locale.Language]?) -> LanguageJudgement = {
        LanguageDetection.judge($0, constraints: $1)
    }
    var text: @Sendable () async throws -> String

    /// A paragraph, and the language it is translated from: nil to leave it as it is.
    private struct Part {
        var text: String
        var language: Locale.Language?
        /// Whether it is left as it is because it is in the target language already.
        var isInTarget = false
    }

    func events() -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self,
                                                                    throwing: (any Error).self)
        let work = Task { [self] in
            continuation.yield(.started(info))
            do {
                try await translate(into: continuation)
                continuation.yield(.finished(.completed))
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.failure(for: error, translating: nil))
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    private func translate(into continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation)
        async throws {
        let original: String
        do {
            original = try await text()
        } catch PasteboardWriterError.noPlainText {
            return
        }
        try Task.checkCancellation()
        guard original.count <= Self.characterLimit else {
            throw GenerationError(kind: .inputTooLarge, message: "This text is too long to translate on this Mac.")
        }
        let paragraphs = StreamAccumulator.paragraphs(of: original)
        guard !paragraphs.isEmpty else { return }
        let supported = await translator.supportedLanguages()
        guard !supported.isEmpty else {
            throw GenerationError(kind: .engineUnavailable, message: "Translation isn't available on this Mac.")
        }
        let parts = try await checked(try plan(paragraphs, supported: supported), supported: supported)
        guard parts.contains(where: { $0.language != nil }) else {
            guard parts.contains(where: \.isInTarget) else { return }
            throw GenerationError(kind: .alreadyInTargetLanguage,
                                  message: "This text is already in \(target.displayName).")
        }
        continuation.yield(.expecting(paragraphs: parts.count))
        // Paragraphs are separated by a blank line, so each counts as done as soon as it is sent.
        func send(_ text: String, at index: Int) {
            continuation.yield(.delta(index == parts.count - 1 ? text : text + "\n\n"))
        }
        var retried = false
        var index = 0
        while index < parts.count {
            guard let language = parts[index].language else {
                send(parts[index].text, at: index)
                index += 1
                continue
            }
            var end = index + 1
            while end < parts.count, let next = parts[end].language, next.isSameLanguage(as: language) { end += 1 }
            let pair = TranslationPair(source: language, target: target)
            while index < end {
                do {
                    for try await translated in translator.translate(parts[index..<end].map(\.text), pair)
                        where index < end {
                        send(Self.tidy(translated, original: parts[index].text), at: index)
                        index += 1
                    }
                    try Task.checkCancellation()
                    // A translator that ends before its last paragraph has failed.
                    guard index == end else { throw GenerationError.interrupted }
                } catch PairTranslationError.notDownloaded where !retried {
                    // For a first translation, the system can find a downloaded language missing: while it still says
                    // the language is downloaded, the rest is asked for once more.
                    retried = true
                    guard await translator.status(of: pair) == .installed else { throw Self.notDownloaded(pair) }
                    try await Task.sleep(for: Self.retryDelay)
                } catch {
                    throw Self.failure(for: error, translating: pair)
                }
            }
        }
    }

    // MARK: Languages

    /// Each paragraph with the language it is translated from, or none.
    private func plan(_ paragraphs: [String], supported: [Locale.Language]) throws -> [Part] {
        var judgements: [LanguageJudgement] = []
        for paragraph in paragraphs {
            try Task.checkCancellation()
            judgements.append(Self.judgement(of: paragraph, supported: supported, judge: judge))
        }
        let main = Self.mainLanguage(of: paragraphs, judged: judgements) {
            Self.judgement(of: $0, supported: supported, judge: judge)
        }
        return try zip(paragraphs, judgements).map { paragraph, judgement in
            guard let language = try language(of: judgement, main: main, supported: supported) else {
                var isInTarget = false
                if case .detected(let detected, _) = judgement { isInTarget = detected.isSameLanguage(as: target) }
                return Part(text: paragraph, language: nil, isInTarget: isInTarget)
            }
            guard !language.isSameLanguage(as: target) else {
                return Part(text: paragraph, language: nil, isInTarget: true)
            }
            return Part(text: paragraph, language: language)
        }
    }

    /// The language most of `text` is in, as a translation of it tells, paragraph by paragraph among `supported`, the
    /// languages Translation knows: nil where it can't tell, or once its task is cancelled. A language Translation
    /// doesn't know is named as itself.
    static func mainLanguage(of text: String, supported: [Locale.Language]) -> Locale.Language? {
        let judge: (String, [Locale.Language]?) -> LanguageJudgement = { LanguageDetection.judge($0, constraints: $1) }
        let paragraphs = StreamAccumulator.paragraphs(of: text)
        var judgements: [LanguageJudgement] = []
        for paragraph in paragraphs {
            guard !Task.isCancelled else { return nil }
            judgements.append(judgement(of: paragraph, supported: supported, judge: judge))
        }
        return mainLanguage(of: paragraphs, judged: judgements) {
            judgement(of: $0, supported: supported, judge: judge)
        }
    }

    /// The language most of the paragraphs judged sure are in; where none is, the language of all the prose paragraphs
    /// together, as `judging` tells it.
    private static func mainLanguage(of paragraphs: [String], judged judgements: [LanguageJudgement],
                                     judging judgement: (String) -> LanguageJudgement) -> Locale.Language? {
        if let main = mainLanguage(of: zip(paragraphs, judgements).compactMap({ paragraph, judgement in
            if case .detected(let language, _) = judgement { (paragraph, language) } else { nil }
        })) {
            return main
        }
        // Together, the prose paragraphs may say what none of them says alone.
        let prose = zip(paragraphs, judgements).filter { $0.1 != .notProse }.map(\.0)
        guard !prose.isEmpty, case .detected(let language, _) = judgement(prose.joined(separator: "\n\n")) else {
            return nil
        }
        return language
    }

    /// A paragraph's language among all languages first, so that one Translation doesn't know is named as itself.
    /// Only when that is unsure, and the likeliest is a language Translation knows, among those.
    private static func judgement(of paragraph: String, supported: [Locale.Language],
                                  judge: (String, [Locale.Language]?) -> LanguageJudgement) -> LanguageJudgement {
        let judgement = judge(paragraph, nil)
        guard case .uncertain(let candidates) = judgement, let top = candidates.first,
              supported.contains(where: { $0.isSameLanguage(as: top) }) else { return judgement }
        return judge(paragraph, supported)
    }

    /// The language a paragraph is translated from, or nil to leave it as it is.
    private func language(of judgement: LanguageJudgement, main: Locale.Language?,
                          supported: [Locale.Language]) throws -> Locale.Language? {
        switch judgement {
        case .notProse:
            return nil
        case .detected(let detected, _):
            // Already in the target, it stays; otherwise a person's choice wins.
            return detected.isSameLanguage(as: target) ? nil : source ?? detected
        case .tooShort:
            guard let known = source ?? main else { throw Self.languageUnknown }
            return known
        case .uncertain(let candidates):
            if let source { return source }
            guard let main else { throw Self.languageUnknown }
            if candidates.isEmpty || candidates.contains(where: { $0.isSameLanguage(as: main) }) { return main }
            // The likeliest language this Mac knows; when it knows none of them, the paragraph stays as it is.
            guard let top = candidates.first, supported.contains(where: { $0.isSameLanguage(as: top) }) else {
                return nil
            }
            return top
        }
    }

    /// Checks every language before any text. The language most of the text is in, counting what is in the target
    /// already, must be the target or one this Mac translates from; a paragraph in another it can't stays as it is.
    /// Every language left must be downloaded.
    private func checked(_ parts: [Part], supported: [Locale.Language]) async throws -> [Part] {
        func knows(_ language: Locale.Language) -> Bool { supported.contains { $0.isSameLanguage(as: language) } }
        var statuses: [(language: Locale.Language, status: TranslationPairStatus)] = []
        for language in parts.compactMap(\.language)
            where !statuses.contains(where: { $0.language.isSameLanguage(as: language) }) {
            try Task.checkCancellation()
            let pair = TranslationPair(source: language, target: target)
            let status = knows(language) && knows(target) ? await translator.status(of: pair) : .unsupported
            statuses.append((language, status))
        }
        func status(of language: Locale.Language) -> TranslationPairStatus {
            statuses.first { $0.language.isSameLanguage(as: language) }?.status ?? .unsupported
        }
        let main = Self.mainLanguage(of: parts.compactMap { part in
            part.language.map { (part.text, $0) } ?? (part.isInTarget ? (part.text, target) : nil)
        })
        if let main, !main.isSameLanguage(as: target), status(of: main) == .unsupported {
            throw Self.unsupported(TranslationPair(source: main, target: target))
        }
        for (language, status) in statuses where status == .needsDownload {
            throw Self.notDownloaded(TranslationPair(source: language, target: target))
        }
        return parts.map { part in
            guard let language = part.language, status(of: language) == .unsupported else { return part }
            return Part(text: part.text, language: nil)
        }
    }

    /// The language most of these paragraphs are in, weighing each by `LanguageDetection.weight(of:)`.
    private static func mainLanguage(of paragraphs: [(text: String, language: Locale.Language)]) -> Locale.Language? {
        var weights: [(language: Locale.Language, weight: Int)] = []
        for (text, language) in paragraphs {
            let weight = LanguageDetection.weight(of: text)
            if let index = weights.firstIndex(where: { $0.language.isSameLanguage(as: language) }) {
                weights[index].weight += weight
            } else {
                weights.append((language, weight))
            }
        }
        return weights.max { $0.weight < $1.weight }?.language
    }

    /// A translated paragraph as it is sent: the original where nothing came back, and without blank lines, which would
    /// split it in two.
    private static func tidy(_ translated: String, original: String) -> String {
        let lines = translated.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
        return lines.isEmpty ? original : lines.joined(separator: "\n")
    }

    // MARK: Failures

    /// What a result column says when a translation fails: the item is gone, changed or damaged, its languages need
    /// downloading or can't be translated between, or the engine failed.
    static func failure(for error: any Error, translating pair: TranslationPair?) -> GenerationError {
        switch error {
        case let error as GenerationError:
            return error
        case StoreError.notFound, StoreError.staleReference, PasteRefusal.contentUnavailable,
             PasteboardWriterError.nonActionableContent, PasteboardWriterError.invalidRepresentationBytes:
            return .contentUnavailable
        case PairTranslationError.notDownloaded:
            if let pair { return notDownloaded(pair) }
        case PairTranslationError.unsupported:
            if let pair { return unsupported(pair) }
        case PairTranslationError.languageUnknown:
            return languageUnknown
        default:
            break
        }
        return GenerationError(kind: .engineUnavailable, message: "This text couldn't be translated on this Mac.")
    }

    private static let languageUnknown = GenerationError(kind: .sourceLanguageUnknown,
                                                         message: "Choose the language this text is in.")

    private static func notDownloaded(_ pair: TranslationPair) -> GenerationError {
        GenerationError(kind: .languageNotDownloaded,
                        message: "To translate from \(pair.source.displayName) to \(pair.target.displayName) on this "
                            + "Mac, download both languages.",
                        pair: pair)
    }

    private static func unsupported(_ pair: TranslationPair) -> GenerationError {
        let bothChinese = pair.source.translationCode.hasPrefix("zh") && pair.target.translationCode.hasPrefix("zh")
        let message = bothChinese ? "This Mac can't translate between Simplified and Traditional Chinese."
            : "This Mac can't translate from \(pair.source.displayName) to \(pair.target.displayName)."
        return GenerationError(kind: .languagePairUnsupported, message: message, pair: pair)
    }
}
