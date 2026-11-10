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

    /// What a request waiting on the store starts, if the store kept nothing.
    private enum Asked {
        case extractText(keepingLineBreaks: Bool)
        case translate(to: Locale.Language)
    }

    @ObservationIgnored private let store: DerivedTextStore
    @ObservationIgnored private let identity: StoreIdentity
    @ObservationIgnored private let recognizer: any TextRecognitionEngine
    @ObservationIgnored private let translator: any TranslationEngine
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
         translator: any TranslationEngine, image: @escaping @Sendable (ContentRef) async throws -> CGImage,
         text: @escaping @Sendable (ContentRef) async throws -> String) {
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

    /// Which of these items have whole results of the operation kept from earlier jobs, for exactly their content;
    /// nil when the store couldn't be read.
    func sourcesWithSavedResults(_ sources: [ContentRef], operation: DerivedTextOperation) async -> Set<ContentRef>? {
        try? await store.sourcesWithWholeResults(sources, operation: operation)
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

    private func startUnlessMade(_ source: ContentRef, operation: DerivedTextOperation, asked: Asked) {
        let key = Self.key(for: source, operation: operation)
        guard !isClosed, job(for: source, operation: operation) == nil else { return }
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
            guard kept == nil, job(for: source, operation: operation) == nil, !hasMade(source, key) else { return }
            switch request.asked {
            case .extractText(let keepsLineBreaks): extractText(from: source, keepingLineBreaks: keepsLineBreaks)
            case .translate(let target): translate(source, to: target)
            }
        }
    }

    /// Starts translating an item's text into `target`, in place of any translation under way for it: from `language`
    /// when a person chose it, which the result keeps, or else from the languages detected in the text. Nil once the
    /// library has closed.
    @discardableResult
    func translate(_ source: ContentRef, from language: Locale.Language? = nil,
                   to target: Locale.Language) -> GenerationJob? {
        guard !isClosed else { return nil }
        let text = text
        let generation = translator.translate({ try await text(source) }, from: language, to: target)
        let request = DerivedTextRequest(source: source, operation: .translate, sourceLanguage: language?.translationCode,
                                         targetLanguage: target.translationCode)
        var options = GenerationJob.Options()
        // A first translation loads its languages, and a long paragraph takes some seconds, the first or any other.
        options.firstTextTimeout = .seconds(90)
        options.idleTimeout = .seconds(90)
        return start(request, lane: translator.tier.lane, options: options, generation: generation)
    }

    /// Whether a request for exactly this content waits on what the store kept, which decides whether it starts.
    func isWaitingToStart(_ source: ContentRef, operation: DerivedTextOperation) -> Bool {
        waiting[Self.key(for: source, operation: operation)]?.source == source
    }

    /// Stops the job under way for an item, or the request still waiting on the store.
    func stop(_ source: ContentRef, operation: DerivedTextOperation) {
        let key = Self.key(for: source, operation: operation)
        waiting[key] = nil
        jobs.stop(key)
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

    private func start(_ request: DerivedTextRequest, lane: JobLane, options: GenerationJob.Options,
                       generation: any GenerationSource) -> GenerationJob {
        let key = Self.key(for: request.source, operation: request.operation)
        let token = UUID()
        // Before the job starts: starting it stops the one under way, whose end this request now outranks, and it
        // stands in for a request still waiting on the store.
        latest[key] = (token, request)
        waiting[key] = nil
        return jobs.start(key, lane: lane, priority: .user, options: options, source: generation) { [weak self] in
            self?.end($0, of: request, key: key, token: token)
        }
    }

    private func end(_ snapshot: GenerationSnapshot, of request: DerivedTextRequest, key: GenerationKey,
                     token: UUID) {
        // A newer request, or the library closing, decides what the item shows.
        guard !isClosed, latest[key]?.token == token else { return }
        lastEnded[key] = token
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
