import CoreGraphics
import Foundation
import Observation

/// Makes text from items and keeps it beside them on this Mac: the text recognized in images, and translations of
/// items' text.
///
/// It starts one job per item and operation in `jobs`, so a newer request stops the one under way, and saves each
/// job's final snapshot once in the store, as the snapshot's `saveDecision` says, under the store generation the
/// library opened with: a whole result replaces the one before, even one that found nothing. Saves for one item land
/// in the order their jobs ended. It remembers what each item shows for each operation in this session, for the
/// content it was made from: how the latest job that had something to show ended. A job a person stopped, or one cut
/// off, leaves what the item showed before it; so does a job that failed after something was made of the item in this
/// session, and it says why. A surface shows a job while it runs, then its outcome, and otherwise what the store kept
/// from earlier sessions, which a failure leaves too.
@MainActor
@Observable
final class DerivedTextCoordinator {
    /// How a job for an item and operation ended, where that is something to show.
    enum Outcome: Equatable, Sendable {
        /// The job ended with this text, made as the request asked, which is being saved: whole, or as far as it got
        /// before a person stopped it or it was cut off.
        case saving(String, DerivedTextRequest, status: DerivedTextStatus)
        /// What the job made, as saved beside its item.
        case saved(DerivedText)
        /// The engine found no text: nothing is kept for the item, and what was kept before goes.
        case noText
        /// The job made this text as the request asked, whole or as far as it got, but the library couldn't keep it.
        case notSaved(String, DerivedTextRequest, status: DerivedTextStatus)
        /// Nothing was made, or what was made belongs to content that changed or went meanwhile, and nothing was made of
        /// this content earlier in this session. What the store kept from earlier sessions stays.
        case failed(GenerationError)
    }

    /// An outcome as an item shows it: with the content it was made from, and the request whose job ended so; and a
    /// later job that failed and left it, with why.
    private struct Shown {
        let request: DerivedTextRequest
        let outcome: Outcome
        let token: UUID
        var failure: (error: GenerationError, token: UUID, request: DerivedTextRequest)?

        var source: ContentRef { request.source }

        /// Something was made of the content: text, or that it has none.
        var isMade: Bool {
            if case .failed = outcome { return false }
            return true
        }
    }

    let jobs = JobCenter()
    /// What each item shows for each operation.
    private var outcomes: [GenerationKey: Shown] = [:]
    /// The request whose job ended last for each item and operation, of those whose ending decides what it shows.
    private var lastEnded: [GenerationKey: UUID] = [:]
    /// Requests waiting on what the store kept, which decides whether they start: the content each is for, and what was
    /// asked for last.
    private var waiting: [GenerationKey: (source: ContentRef, asked: Asked)] = [:]

    /// Translations of the text in images that wait for the image's recognition under way to end: for each image, the
    /// content the recognition is for and the language asked for.
    private var afterText: [GenerationKey: (source: ContentRef, target: Locale.Language)] = [:]

    /// What a request waiting on the store starts, if the store kept nothing.
    private enum Asked {
        case extractText(keepingLineBreaks: Bool)
        case translate(to: Locale.Language)
        /// A translation of the text in an image, whose text is recognized first, in this layout, when none is known.
        case translateImage(to: Locale.Language, keepingLineBreaks: Bool)
    }

    /// What this session knows of the text in an image.
    private enum TextInImage {
        case text(String)
        /// A recognition found none.
        case none
        /// A recognition is under way.
        case underWay
        /// Nothing yet, or a failure: the store may have kept text from before.
        case unknown
    }

    @ObservationIgnored private let store: DerivedTextStore
    @ObservationIgnored private let identity: StoreIdentity
    @ObservationIgnored private let recognizer: any TextRecognitionEngine
    @ObservationIgnored private let translator: any TranslationEngine
    /// The languages the person prefers, first first, as the system lists them.
    @ObservationIgnored private let preferredLanguages: @Sendable () -> [String]
    /// What Translate automatically makes for the card the translation column shows, until the card is left.
    @ObservationIgnored private var viewed: Set<GenerationKey> = []
    /// What Translate automatically is checking before it starts, one at a time for an item.
    @ObservationIgnored private var checking: [GenerationKey: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let image: @Sendable (ContentRef) async throws -> CGImage
    @ObservationIgnored private let text: @Sendable (ContentRef) async throws -> String
    /// The latest request for each item and operation, while its job runs or its result is saved. Only its ending
    /// changes what the item shows.
    @ObservationIgnored private var latest: [GenerationKey: (token: UUID, request: DerivedTextRequest)] = [:]
    /// The latest save for each item and operation, which a later save waits for. Closing the library waits for all.
    @ObservationIgnored private var saves: [GenerationKey: (token: UUID, task: Task<Void, Never>)] = [:]
    /// For each save under way, what its item shows again if the store doesn't take the text: what it showed before
    /// the job ended, as the saves before it came to.
    @ObservationIgnored private var restores: [UUID: Shown] = [:]
    @ObservationIgnored private var isClosed = false

    /// `identity` is the store generation the library opened with; results are kept only under it. `image` reads an
    /// item's image at its full size, and `text` an item's text, as plain text.
    init(store: DerivedTextStore, identity: StoreIdentity, recognizer: any TextRecognitionEngine,
         translator: any TranslationEngine,
         preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
         image: @escaping @Sendable (ContentRef) async throws -> CGImage,
         text: @escaping @Sendable (ContentRef) async throws -> String) {
        self.preferredLanguages = preferredLanguages
        self.store = store
        self.identity = identity
        self.recognizer = recognizer
        self.translator = translator
        self.image = image
        self.text = text
    }

    /// The job under way for exactly this content of an item. Nil when the job is for content it had before.
    func job(for source: ContentRef, operation: DerivedTextOperation) -> GenerationJob? {
        let key = Self.key(for: source, operation: operation)
        // Read first: whoever asks learns of the next job too, though `latest` isn't observed.
        let job = jobs.job(for: key)
        guard latest[key]?.request.source == source else { return nil }
        return job
    }

    /// What exactly this content of an item shows of the jobs that ended for it in this session. Nil when that is for
    /// content it had before.
    func outcome(for source: ContentRef, operation: DerivedTextOperation) -> Outcome? {
        guard let shown = outcomes[Self.key(for: source, operation: operation)], shown.source == source else {
            return nil
        }
        return shown.outcome
    }

    /// Whether what exactly this content shows is how its latest job ended, rather than what an earlier job made before
    /// a later one was stopped or failed.
    func showsLatestEnding(for source: ContentRef, operation: DerivedTextOperation) -> Bool {
        let key = Self.key(for: source, operation: operation)
        guard let shown = outcomes[key], shown.source == source else { return false }
        return shown.token == lastEnded[key]
    }

    /// The latest job's ending for exactly this content, while the item shows it: what the job made, or the failure that
    /// left what was made before. It tells one ending from another, so that a surface says each once; nil while the
    /// item shows something else, as text brought back by stopping a job.
    func latestEnding(for source: ContentRef, operation: DerivedTextOperation) -> UUID? {
        let key = Self.key(for: source, operation: operation)
        guard let shown = outcomes[key], shown.source == source, let ended = lastEnded[key],
              shown.token == ended || shown.failure?.token == ended else { return nil }
        return ended
    }

    /// Why the latest job for exactly this content failed, when it left what an earlier job of this session made of it,
    /// which the item still shows. Nil once a later job has ended, however it ended.
    func failure(for source: ContentRef, operation: DerivedTextOperation) -> GenerationError? {
        latestFailure(for: source, operation: operation)?.error
    }

    /// What the job that failed was asked to make, such as the language a translation was to be in: the latest job,
    /// when it failed and left what was made before, or the one whose failure exactly this content shows on its own.
    func failedRequest(for source: ContentRef, operation: DerivedTextOperation) -> DerivedTextRequest? {
        if let failure = latestFailure(for: source, operation: operation) { return failure.request }
        guard let shown = outcomes[Self.key(for: source, operation: operation)], shown.source == source,
              case .failed = shown.outcome else { return nil }
        return shown.request
    }

    /// What the job whose ending exactly this content shows was asked to make. Nil when it shows none.
    func shownRequest(for source: ContentRef, operation: DerivedTextOperation) -> DerivedTextRequest? {
        guard let shown = outcomes[Self.key(for: source, operation: operation)], shown.source == source else {
            return nil
        }
        return shown.request
    }

    /// What the job under way for exactly this content was asked to make. Nil without one.
    func runningRequest(for source: ContentRef, operation: DerivedTextOperation) -> DerivedTextRequest? {
        guard job(for: source, operation: operation) != nil else { return nil }
        return latest[Self.key(for: source, operation: operation)]?.request
    }

    private func latestFailure(for source: ContentRef, operation: DerivedTextOperation)
        -> (error: GenerationError, token: UUID, request: DerivedTextRequest)? {
        let key = Self.key(for: source, operation: operation)
        guard let shown = outcomes[key], shown.source == source, let failure = shown.failure,
              failure.token == lastEnded[key] else { return nil }
        return failure
    }

    /// What a job saved for exactly this content of an item, in this session or an earlier one; nil when there is
    /// nothing, or it can't be read.
    func savedResult(for source: ContentRef, operation: DerivedTextOperation) async -> DerivedText? {
        try? await store.result(for: source, operation: operation)
    }

    /// What earlier jobs kept of the operation for these items, for exactly their content: how whole each result is and
    /// its language. Nil when the store couldn't be read.
    func savedSummaries(of sources: [ContentRef],
                        operation: DerivedTextOperation) async -> [ContentRef: DerivedTextSummary]? {
        try? await store.summaries(of: sources, operation: operation)
    }

    /// The job under way and the outcome shown for exactly this content, as `job(for:operation:)` and
    /// `outcome(for:operation:)` give them, for an item's card.
    func cardState(for source: ContentRef, operation: DerivedTextOperation) -> (job: GenerationJob?, outcome: Outcome?) {
        let key = Self.key(for: source, operation: operation)
        let job = jobs.job(for: key)
        let shown = outcomes[key]
        return (latest[key]?.request.source == source ? job : nil, shown?.source == source ? shown?.outcome : nil)
    }

    /// Starts recognizing the text in an image item, in place of any recognition under way for it. Nil once the
    /// library has closed.
    @discardableResult
    func extractText(from source: ContentRef, keepingLineBreaks: Bool) -> GenerationJob? {
        guard !isClosed else { return nil }
        let image = image
        let generation = recognizer.recognizeText(in: { try await image(source) },
                                                  keepingLineBreaks: keepingLineBreaks)
        var options = GenerationJob.Options()
        // Recognition sends its text only once it has read the whole image, and its first run loads a model.
        options.firstTextTimeout = .seconds(90)
        // It sends three events, so each can go out as it comes rather than on a timer.
        options.publishInterval = .zero
        let request = DerivedTextRequest(source: source, operation: .extractText, keepsLineBreaks: keepingLineBreaks)
        return start(request, lane: recognizer.tier.lane, options: options, generation: generation)
    }

    /// Recognizes the text in an image item unless something was made of it: a job is under way, one in this session
    /// ended with text or with none, or the store kept text from before, which is read first. A failure is tried again,
    /// unless it left text the store kept. Asked again while the store is read, it starts nothing more, in the layout
    /// asked for last.
    func extractTextUnlessMade(from source: ContentRef, keepingLineBreaks: Bool) {
        startUnlessMade(source, operation: .extractText, asked: .extractText(keepingLineBreaks: keepingLineBreaks))
    }

    /// Translates an item's text into `target` unless something was made of it, as `extractTextUnlessMade` recognizes
    /// an image's text: a translation kept from before shows as it is, in whatever language it is in.
    func translateUnlessMade(_ source: ContentRef, to target: Locale.Language) {
        startUnlessMade(source, operation: .translate, asked: .translate(to: target))
    }

    /// Translates the text in an image into `target` unless something was made of it, as `translateUnlessMade` does a
    /// text's: a translation kept from before shows as it is. Without one, it translates the text recognized in the
    /// image, as `translateText(inImage:to:keepingLineBreaks:)` does.
    func translateImageUnlessMade(_ source: ContentRef, to target: Locale.Language, keepingLineBreaks: Bool) {
        startUnlessMade(source, operation: .translate,
                        asked: .translateImage(to: target, keepingLineBreaks: keepingLineBreaks))
    }

    /// Translates the text of an item just copied in the background, as Translate automatically does: on this Mac only,
    /// into the language fixed in Settings, else the one last used, as quick access would make one. Only text in another
    /// language, of no more than `automaticLength` characters, whose main language this Mac translates from without a
    /// download is translated, and never in place of anything asked for, made, kept from before in whatever language, or
    /// under way. It gives way to every job a person asks for, and nothing is said of it while it runs, or if it ends with
    /// nothing to keep; once made, the translation is kept as any is.
    /// `whileViewed` makes it for the card the translation column shows, until `stopTranslationWhileViewed` says the
    /// card was left.
    func translateAutomatically(_ source: ContentRef, fixed: String?, lastUsed: String?, whileViewed: Bool = false) {
        let key = Self.key(for: source, operation: .translate)
        // Copied text never leaves this Mac to be translated.
        guard !isClosed, translator.tier == .onThisMac, job(for: source, operation: .translate) == nil,
              waiting[key] == nil, checking[key] == nil, !hasMade(source, key) else { return }
        // A card whose translation a person asked for and saw fail keeps saying why.
        if whileViewed, outcomes[key]?.source == source { return }
        if whileViewed { viewed.insert(key) }
        let text = text
        let translator = translator
        let preferredLanguages = preferredLanguages
        let token = UUID()
        let check = Task { [weak self] in
            defer { if self?.checking[key]?.token == token { self?.checking[key] = nil } }
            // What was kept is read first; while the store can't say, nothing is translated.
            guard let store = self?.store else { return }
            let kept: DerivedText?
            do { kept = try await store.result(for: source, operation: .translate) } catch { return }
            guard kept == nil else { return }
            let offered = await translator.supportedLanguages()
            let target = TranslationTargets.target(fixed: fixed, lastUsed: lastUsed, preferred: preferredLanguages(),
                                                   offered: offered)
            guard let body = try? await text(source) else { return }
            // A long text is measured, and its language told, away from the main actor, and no longer once nobody waits.
            let telling = Task.detached(priority: .utility) { () -> Locale.Language? in
                guard body.count <= Self.automaticLength else { return nil }
                return TranslationSource.mainLanguage(of: body, supported: offered)
            }
            let told = await withTaskCancellationHandler { await telling.value } onCancel: { telling.cancel() }
            guard let language = told, !language.isSameLanguage(as: target),
                  await translator.status(of: TranslationPair(source: language, target: target)) == .installed,
                  let self, !Task.isCancelled, !isClosed, job(for: source, operation: .translate) == nil,
                  waiting[key] == nil, !hasMade(source, key), !whileViewed || viewed.contains(key) else { return }
            startTranslation(source, text: body, to: target, priority: .automatic)
        }
        checking[key] = (token, check)
    }

    /// Stops what Translate automatically makes for the card the translation column shows, once the card is left, the
    /// column closes or the panel does: it keeps nothing and says nothing. A translation made for a copy, or one the
    /// person asked for, goes on.
    func stopTranslationWhileViewed(_ source: ContentRef) {
        let key = Self.key(for: source, operation: .translate)
        guard viewed.remove(key) != nil else { return }
        // What is still checked stops being checked.
        checking.removeValue(forKey: key)?.task.cancel()
        guard let job = job(for: source, operation: .translate), job.priority == .automatic else { return }
        job.stop(.superseded)
    }

    /// The longest text Translate automatically translates, in characters.
    nonisolated static let automaticLength = 5_000

    /// Translates the text in an image into `target`: the text recognized in this session, or else kept from before,
    /// and otherwise the text a recognition finds first, in this layout. A recognition under way is waited for. The
    /// translation starts in place of any under way for the image. An image with no text in it, or whose recognition
    /// fails, is said to be so as how its translation ended.
    func translateText(inImage source: ContentRef, to target: Locale.Language, keepingLineBreaks: Bool) {
        guard !isClosed else { return }
        let key = Self.key(for: source, operation: .translate)
        let textKey = Self.key(for: source, operation: .extractText)
        afterText[textKey] = nil
        switch textInImage(source) {
        case .text(let text): startTranslation(source, text: text, to: target)
        case .none: endTranslationWithoutText(.noText, of: source, into: target)
        case .underWay: afterText[textKey] = (source, target)
        case .unknown:
            waiting[key] = (source, .translateImage(to: target, keepingLineBreaks: keepingLineBreaks))
            Task { [weak self] in
                let kept = await self?.savedResult(for: source, operation: .extractText)
                // Stopped meanwhile, or asked for again for other content, it starts nothing.
                guard let self, let request = waiting[key], request.source == source else { return }
                waiting[key] = nil
                // Asked for again meanwhile, it translates into the language asked for last.
                let (target, keepsLineBreaks) = switch request.asked {
                case .translateImage(let target, let keepsLineBreaks): (target, keepsLineBreaks)
                case .translate(let target): (target, keepingLineBreaks)
                case .extractText: (target, keepingLineBreaks)
                }
                guard job(for: source, operation: .translate) == nil else { return }
                switch textInImage(source) {
                case .text(let text): startTranslation(source, text: text, to: target)
                case .none: endTranslationWithoutText(.noText, of: source, into: target)
                case .underWay: afterText[textKey] = (source, target)
                case .unknown:
                    if let kept, !kept.text.isEmpty {
                        startTranslation(source, text: kept.text, to: target)
                    } else {
                        afterText[textKey] = (source, target)
                        extractText(from: source, keepingLineBreaks: keepsLineBreaks)
                    }
                }
            }
        }
    }

    /// Whether a translation of exactly this content of an image waits for its text to be recognized, and into what
    /// language; nil when none does.
    func translationWaitingForText(_ source: ContentRef) -> Locale.Language? {
        guard let waiting = afterText[Self.key(for: source, operation: .extractText)], waiting.source == source else {
            return nil
        }
        return waiting.target
    }

    private func textInImage(_ source: ContentRef) -> TextInImage {
        if job(for: source, operation: .extractText) != nil { return .underWay }
        switch outcome(for: source, operation: .extractText) {
        case .saving(let text, _, _)?, .notSaved(let text, _, _)?: return .text(text)
        case .saved(let result)?: return .text(result.text)
        case .noText?: return .none
        case .failed?, nil: return .unknown
        }
    }

    /// A recognition that a translation of the image's text waited for ended: what it found is translated. One that
    /// found nothing, or failed, says so as how the translation ended; one stopped or replaced starts no translation.
    private func follow(_ snapshot: GenerationSnapshot, of source: ContentRef, into target: Locale.Language) {
        switch snapshot.phase {
        case .finished(.completed) where !snapshot.hasText:
            endTranslationWithoutText(.noText, of: source, into: target)
        case .finished(.completed), .finished(.truncated):
            startTranslation(source, text: snapshot.text(), to: target)
        case .failed(let error):
            endTranslationWithoutText(.failed(error), of: source, into: target)
        case .finished(.refused), .stopped, .queued, .waiting, .streaming:
            break
        }
    }

    /// Ends a translation of the text in an image that didn't start, as a job's ending would: there is nothing in the
    /// image to translate, or why its text couldn't be recognized. A failure leaves what was made of this content
    /// before, and says why.
    private func endTranslationWithoutText(_ outcome: Outcome, of source: ContentRef, into target: Locale.Language) {
        let key = Self.key(for: source, operation: .translate)
        let token = UUID()
        let request = DerivedTextRequest(source: source, operation: .translate, targetLanguage: target.translationCode)
        lastEnded[key] = token
        if case .failed(let error) = outcome, hasMade(source, key) {
            outcomes[key]?.failure = (error, token, request)
        } else {
            show(outcome, for: key, request: request, token: token)
        }
    }

    private func startUnlessMade(_ source: ContentRef, operation: DerivedTextOperation, asked: Asked) {
        let key = Self.key(for: source, operation: operation)
        // A job made in the background gives way to the same one asked for, which goes ahead of it.
        guard !isClosed, Self.givesWay(job(for: source, operation: operation)) else { return }
        if waiting[key]?.source == source {
            waiting[key] = (source, asked)
            return
        }
        guard !hasMade(source, key) else { return }
        waiting[key] = (source, asked)
        Task { [weak self] in
            let kept = await self?.savedResult(for: source, operation: operation)
            // Stopped meanwhile, or asked for again for other content, it starts nothing.
            guard let self, let request = waiting[key], request.source == source else { return }
            waiting[key] = nil
            // Meanwhile a job may have been asked for, and may have made something.
            guard kept == nil, Self.givesWay(job(for: source, operation: operation)), !hasMade(source, key) else {
                return
            }
            switch request.asked {
            case .extractText(let keepsLineBreaks): extractText(from: source, keepingLineBreaks: keepsLineBreaks)
            case .translate(let target): translate(source, to: target)
            case .translateImage(let target, let keepsLineBreaks):
                translateText(inImage: source, to: target, keepingLineBreaks: keepsLineBreaks)
            }
        }
    }

    /// Starts translating an item's text into `target`, in place of any translation under way for it: from `language`
    /// when a person chose it, which the result keeps, or else from the languages detected in the text. Nil once the
    /// library has closed.
    @discardableResult
    func translate(_ source: ContentRef, from language: Locale.Language? = nil,
                   to target: Locale.Language) -> GenerationJob? {
        startTranslation(source, text: nil, from: language, to: target)
    }

    /// Starts translating `given` text of an item, or the item's own text without it.
    @discardableResult
    private func startTranslation(_ source: ContentRef, text given: String?, from language: Locale.Language? = nil,
                                  to target: Locale.Language, priority: JobPriority = .user) -> GenerationJob? {
        guard !isClosed else { return nil }
        let text = text
        let generation = translator.translate({
            if let given { return given }
            return try await text(source)
        }, from: language, to: target)
        let request = DerivedTextRequest(source: source, operation: .translate, sourceLanguage: language?.translationCode,
                                         targetLanguage: target.translationCode)
        var options = GenerationJob.Options()
        // A first translation loads its languages, and a long paragraph takes some seconds, the first or any other.
        options.firstTextTimeout = .seconds(90)
        options.idleTimeout = .seconds(90)
        let key = Self.key(for: source, operation: .translate)
        // One made in the background that gave way to what a person asked for is asked for again, behind it, unless
        // something was asked for or made of the item meanwhile, or it was for a card that was left.
        let wasViewed = viewed.contains(key)
        let again: (() -> Void)? = priority == .automatic ? { [weak self] in
            guard let self, !isClosed, job(for: source, operation: .translate) == nil, waiting[key] == nil,
                  !hasMade(source, key), !wasViewed || viewed.contains(key) else { return }
            startTranslation(source, text: given, from: language, to: target, priority: .automatic)
        } : nil
        return start(request, lane: translator.tier.lane, priority: priority, options: options, generation: generation,
                     again: again)
    }

    /// No job, or one made in the background, which the same job asked for by a person replaces.
    private static func givesWay(_ job: GenerationJob?) -> Bool {
        job.map { $0.priority == .automatic } ?? true
    }

    // MARK: Languages

    /// Every language translations can be made in, a language in each region Translation has it in, as British and US
    /// English are downloaded apart, and what translating a text in `source` into each needs on this Mac. Nothing is
    /// said without the text's language, or of that language itself; a text in a language this Mac doesn't translate
    /// from can be translated into none.
    func translationLanguages(from source: Locale.Language?) async -> [TranslationLanguage] {
        var languages: [Locale.Language] = []
        for language in await translator.supportedLanguages() where !languages.contains(language) {
            languages.append(language)
        }
        guard let source else { return languages.map { TranslationLanguage(language: $0, status: nil) } }
        let isKnown = languages.contains { $0.isSameLanguage(as: source) }
        var result: [TranslationLanguage] = []
        for language in languages where !Task.isCancelled {
            guard !language.isSameLanguage(as: source) else {
                result.append(TranslationLanguage(language: language, status: nil))
                continue
            }
            let status = isKnown ? await translator.status(of: TranslationPair(source: source, target: language))
                : .unsupported
            result.append(TranslationLanguage(language: language, status: status))
        }
        return result
    }

    /// The language most of `text` is in, as a translation of it tells, from its start, which is enough to tell: nil
    /// where it can't tell, once the library has closed, or for a reader that stopped waiting. It is told away from the
    /// main actor, in the background, as it is told before anyone may ask for it, and the telling stops once nobody
    /// waits for it.
    func language(of text: String) async -> Locale.Language? {
        guard !isClosed, !text.isEmpty, !Task.isCancelled else { return nil }
        let supported = await translator.supportedLanguages()
        let telling = Task.detached(priority: .utility) {
            TranslationSource.mainLanguage(of: String(text.prefix(Self.languageSampleLength)), supported: supported)
        }
        return await withTaskCancellationHandler { await telling.value } onCancel: { telling.cancel() }
    }

    /// How much of a text its language is told from, in characters.
    nonisolated static let languageSampleLength = 10_000

    /// The text recognized in an image in this session, whether or not the library could keep it: nil while it is
    /// recognized, where none was found, and where none was recognized yet.
    func recognizedText(in source: ContentRef) -> String? {
        guard case .text(let text) = textInImage(source) else { return nil }
        return text
    }

    /// Whether a request for exactly this content waits on what the store kept, which decides whether it starts.
    func isWaitingToStart(_ source: ContentRef, operation: DerivedTextOperation) -> Bool {
        waiting[Self.key(for: source, operation: operation)]?.source == source
    }

    /// Stops the job under way for an item, or the request still waiting on the store. A translation of the text in an
    /// image that waits for its recognition stops that recognition too.
    func stop(_ source: ContentRef, operation: DerivedTextOperation) {
        let key = Self.key(for: source, operation: operation)
        waiting[key] = nil
        jobs.stop(key)
        let textKey = Self.key(for: source, operation: .extractText)
        if operation == .translate, afterText[textKey]?.source == source {
            afterText[textKey] = nil
            jobs.stop(textKey)
        }
    }

    /// Stops every job and waits for the saves under way, as Keeptide does before it closes the library. Nothing
    /// starts or is saved after. Every caller waits until the last save has landed.
    func stopAndDrain() async {
        isClosed = true
        jobs.stopAll()
        while let (key, save) = saves.first {
            await save.task.value
            if saves[key]?.token == save.token { saves[key] = nil }
        }
    }

    /// Whether the item shows something a job of this session made of exactly this content: text, or that it has none.
    private func hasMade(_ source: ContentRef, _ key: GenerationKey) -> Bool {
        guard let shown = outcomes[key], shown.source == source else { return false }
        return shown.isMade
    }

    /// One job per item, facet and operation: a clip and the snippet saved from it are separate items.
    private static func key(for source: ContentRef, operation: DerivedTextOperation) -> GenerationKey {
        GenerationKey(item: "\(source.itemID.rawValue.uuidString)/\(source.facet.rawValue)", action: operation.rawValue)
    }

    private func start(_ request: DerivedTextRequest, lane: JobLane, priority: JobPriority = .user,
                       options: GenerationJob.Options, generation: any GenerationSource,
                       again: (() -> Void)? = nil) -> GenerationJob {
        let key = Self.key(for: request.source, operation: request.operation)
        let token = UUID()
        // Before the job starts: starting it stops the one under way, whose end this request now outranks, and it
        // stands in for a request still waiting on the store.
        latest[key] = (token, request)
        waiting[key] = nil
        return jobs.start(key, lane: lane, priority: priority, options: options, source: generation) { [weak self] in
            self?.end($0, of: request, key: key, token: token, priority: priority, again: again)
        }
    }

    private func end(_ snapshot: GenerationSnapshot, of request: DerivedTextRequest, key: GenerationKey,
                     token: UUID, priority: JobPriority, again: (() -> Void)?) {
        // A newer request, or the library closing, decides what the item shows.
        guard !isClosed, latest[key]?.token == token else { return }
        // Nobody asked for what is made in the background: one that ends with nothing to keep is said to nobody, and
        // leaves what was kept.
        if priority == .automatic, [.discard, .clear].contains(snapshot.saveDecision) {
            latest[key] = nil
            if case .stopped(.yielded) = snapshot.phase { again?() }
            return
        }
        lastEnded[key] = token
        if request.operation == .extractText, let waiting = afterText[key], waiting.source == request.source {
            afterText[key] = nil
            follow(snapshot, of: request.source, into: waiting.target)
        }
        let decision = snapshot.saveDecision
        guard decision != .discard else {
            latest[key] = nil
            switch Self.outcome(of: snapshot, saved: nil) {
            case nil:
                // A job stopped, or cut off, leaves what the item showed before it.
                break
            case .failed(let error)? where hasMade(request.source, key):
                // So does a failure, once something was made of this content in this session, and it says why.
                outcomes[key]?.failure = (error, token, request)
            case let outcome?:
                show(outcome, for: key, request: request, token: token)
            }
            return
        }
        // Until the save lands, the item shows what the job made, or that it found nothing, which the store is told
        // too: the text kept before goes.
        restores[token] = outcomes[key]
        show(decision == .clear ? .noText : .saving(snapshot.text(), request, status: Self.status(of: snapshot)),
             for: key, request: request, token: token)
        let store = store
        let identity = identity
        let earlier = saves[key]?.task
        let save = Task { [weak self] in
            await earlier?.value
            let outcome: Outcome?
            do {
                if decision == .clear {
                    // Nothing found replaces what was kept, while the store takes it: an item that went meanwhile,
                    // perhaps to come back, keeps it, and the job came to nothing it could keep.
                    let cleared = try await store.clear(request.source, operation: request.operation,
                                                        expecting: identity)
                    outcome = cleared ? .noText : .failed(.contentUnavailable)
                } else {
                    let saved = try await store.save(snapshot, for: request, expecting: identity)
                    outcome = Self.outcome(of: snapshot, saved: saved)
                }
            } catch {
                // The image has no text, whether or not the store could let go of what it kept before.
                outcome = decision == .clear ? .noText
                    : .notSaved(snapshot.text(), request, status: Self.status(of: snapshot))
            }
            self?.saved(outcome, for: key, request: request, token: token)
        }
        saves[key] = (token, save)
    }

    /// A save landed. What it came to shows while the item still shows what the job made: no later job has ended with
    /// something of its own to show meanwhile, though one may have been stopped, or have failed and said why. What the
    /// store didn't take leaves what the item showed before the job: text from a job stopped or cut off, as it was; a
    /// whole text, or finding none, as a failure does, saying why, once something was made of the content.
    private func saved(_ outcome: Outcome?, for key: GenerationKey, request: DerivedTextRequest, token: UUID) {
        let source = request.source
        if saves[key]?.token == token { saves[key] = nil }
        if latest[key]?.token == token { latest[key] = nil }
        let before = restores.removeValue(forKey: token)
        let cameTo: Shown?
        switch outcome {
        case .failed(let error)? where before.map({ $0.source == source && $0.isMade }) == true:
            cameTo = before.map { kept in
                var kept = kept
                kept.failure = (error, token, request)
                return kept
            }
        case let outcome?:
            cameTo = Shown(request: request, outcome: outcome, token: token)
        case nil:
            cameTo = before
        }
        // A later save that would bring this text back if its own isn't kept brings back what this save came to.
        for (later, shown) in restores where shown.token == token { restores[later] = Self.cameTo(cameTo, for: shown) }
        guard let shown = outcomes[key], shown.token == token else { return }
        outcomes[key] = Self.cameTo(cameTo, for: shown)
    }

    /// What a save came to, in place of the text it saved as `shown` showed it. A later failure that left that text
    /// stays with what the save came to, while that is something made; otherwise the failure is what the item shows, as
    /// the latest job's ending.
    private static func cameTo(_ cameTo: Shown?, for shown: Shown) -> Shown? {
        guard let failure = shown.failure else { return cameTo }
        guard var cameTo, cameTo.isMade else {
            return Shown(request: failure.request, outcome: .failed(failure.error), token: failure.token)
        }
        cameTo.failure = failure
        return cameTo
    }

    private func show(_ outcome: Outcome, for key: GenerationKey, request: DerivedTextRequest, token: UUID) {
        outcomes[key] = Shown(request: request, outcome: outcome, token: token)
    }

    /// How whole a snapshot's text is, as the store keeps it.
    private static func status(of snapshot: GenerationSnapshot) -> DerivedTextStatus {
        switch snapshot.phase {
        case .finished(.completed): .complete
        case .finished(.truncated): .truncated
        default: .stopped
        }
    }

    private static func outcome(of snapshot: GenerationSnapshot, saved: DerivedText?) -> Outcome? {
        if let saved { return .saved(saved) }
        switch snapshot.phase {
        // A whole result the store didn't take: its item changed or went, or the library is another one now.
        case .finished(.completed): return snapshot.hasText ? .failed(.contentUnavailable) : .noText
        case .failed(let error): return .failed(error)
        default: return nil
        }
    }
}
