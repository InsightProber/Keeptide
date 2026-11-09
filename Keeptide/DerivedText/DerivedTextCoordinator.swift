import CoreGraphics
import Foundation
import Observation

/// Makes text from items and keeps it beside them on this Mac: for now, the text recognized in images.
///
/// It starts one job per item and operation in `jobs`, so a newer request stops the one under way, and saves each
/// job's final snapshot once in the store, as the snapshot's `saveDecision` says, under the store generation the
/// library opened with. Saves for one item land in the order their jobs ended. It remembers what each item shows for
/// each operation in this session, for the content it was made from: how the latest job that had something to show
/// ended. A job a person stopped, or one cut off, leaves what the item showed before it. A surface shows a job while it
/// runs, then its outcome, and otherwise what the store kept from earlier sessions.
@MainActor
@Observable
final class DerivedTextCoordinator {
    /// How a job for an item and operation ended, where that is something to show.
    enum Outcome: Equatable, Sendable {
        /// The job ended with this text, made as the request asked, which is being saved.
        case saving(String, DerivedTextRequest)
        /// What the job made, as saved beside its item.
        case saved(DerivedText)
        /// The engine found no text.
        case noText
        /// The job made this text as the request asked, but the library couldn't keep it.
        case notSaved(String, DerivedTextRequest)
        /// Nothing was made, or what was made belongs to content that changed or went meanwhile.
        case failed(GenerationError)
    }

    /// An outcome as an item shows it: with the content it was made from, and the request whose job ended so.
    private struct Shown {
        let source: ContentRef
        let outcome: Outcome
        let token: UUID
    }

    let jobs = JobCenter()
    /// What each item shows for each operation.
    private var outcomes: [GenerationKey: Shown] = [:]
    /// The request whose job ended last for each item and operation, of those whose ending decides what it shows.
    private var lastEnded: [GenerationKey: UUID] = [:]
    /// Requests waiting on what the store kept, which decides whether they start: the content each is for, and the
    /// layout asked for last.
    private var waiting: [GenerationKey: (source: ContentRef, keepsLineBreaks: Bool)] = [:]

    @ObservationIgnored private let store: DerivedTextStore
    @ObservationIgnored private let identity: StoreIdentity
    @ObservationIgnored private let recognizer: any TextRecognitionEngine
    @ObservationIgnored private let image: @Sendable (ContentRef) async throws -> CGImage
    /// The latest request for each item and operation, while its job runs or its result is saved. Only its ending
    /// changes what the item shows.
    @ObservationIgnored private var latest: [GenerationKey: (token: UUID, source: ContentRef)] = [:]
    /// The latest save for each item and operation, which a later save waits for. Closing the library waits for all.
    @ObservationIgnored private var saves: [GenerationKey: (token: UUID, task: Task<Void, Never>)] = [:]
    /// For each save under way, what its item shows again if the store doesn't take the text: what it showed before
    /// the job ended, as the saves before it came to.
    @ObservationIgnored private var restores: [UUID: Shown] = [:]
    @ObservationIgnored private var isClosed = false

    /// `identity` is the store generation the library opened with; results are kept only under it. `image` reads an
    /// item's image at its full size.
    init(store: DerivedTextStore, identity: StoreIdentity, recognizer: any TextRecognitionEngine,
         image: @escaping @Sendable (ContentRef) async throws -> CGImage) {
        self.store = store
        self.identity = identity
        self.recognizer = recognizer
        self.image = image
    }

    /// The job under way for exactly this content of an item. Nil when the job is for content it had before.
    func job(for source: ContentRef, operation: DerivedTextOperation) -> GenerationJob? {
        let key = Self.key(for: source, operation: operation)
        // Read first: whoever asks learns of the next job too, though `latest` isn't observed.
        let job = jobs.job(for: key)
        guard latest[key]?.source == source else { return nil }
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
    /// a later one was stopped.
    func showsLatestEnding(for source: ContentRef, operation: DerivedTextOperation) -> Bool {
        let key = Self.key(for: source, operation: operation)
        guard let shown = outcomes[key], shown.source == source else { return false }
        return shown.token == lastEnded[key]
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
        return (latest[key]?.source == source ? job : nil, shown?.source == source ? shown?.outcome : nil)
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
    /// ended with text or with none, or the store kept text from before, which is read first. A failure is tried again.
    /// Asked again while the store is read, it starts nothing more, in the layout asked for last.
    func extractTextUnlessMade(from source: ContentRef, keepingLineBreaks: Bool) {
        let key = Self.key(for: source, operation: .extractText)
        guard !isClosed, job(for: source, operation: .extractText) == nil else { return }
        if waiting[key]?.source == source {
            waiting[key] = (source, keepingLineBreaks)
            return
        }
        switch outcome(for: source, operation: .extractText) {
        case .failed?:
            extractText(from: source, keepingLineBreaks: keepingLineBreaks)
        case nil:
            waiting[key] = (source, keepingLineBreaks)
            Task { [weak self] in
                let kept = await self?.savedResult(for: source, operation: .extractText)
                // Stopped meanwhile, or asked for again for other content, it starts nothing.
                guard let self, let request = waiting[key], request.source == source else { return }
                waiting[key] = nil
                // Meanwhile a job may have been asked for, and may have ended.
                guard kept == nil, job(for: source, operation: .extractText) == nil,
                      outcome(for: source, operation: .extractText) == nil else { return }
                extractText(from: source, keepingLineBreaks: request.keepsLineBreaks)
            }
        case .saving?, .saved?, .noText?, .notSaved?:
            break
        }
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

    /// One job per item, facet and operation: a clip and the snippet saved from it are separate items.
    private static func key(for source: ContentRef, operation: DerivedTextOperation) -> GenerationKey {
        GenerationKey(item: "\(source.itemID.rawValue.uuidString)/\(source.facet.rawValue)", action: operation.rawValue)
    }

    private func start(_ request: DerivedTextRequest, lane: JobLane, options: GenerationJob.Options,
                       generation: any GenerationSource) -> GenerationJob {
        let key = Self.key(for: request.source, operation: request.operation)
        let token = UUID()
        // Before the job starts: starting it stops the one under way, whose end this request now outranks.
        latest[key] = (token, request.source)
        return jobs.start(key, lane: lane, priority: .user, options: options, source: generation) { [weak self] in
            self?.end($0, of: request, key: key, token: token)
        }
    }

    private func end(_ snapshot: GenerationSnapshot, of request: DerivedTextRequest, key: GenerationKey,
                     token: UUID) {
        // A newer request, or the library closing, decides what the item shows.
        guard !isClosed, latest[key]?.token == token else { return }
        lastEnded[key] = token
        guard snapshot.saveDecision != .discard else {
            latest[key] = nil
            // A job stopped, or cut off, leaves what the item showed before it.
            if let outcome = Self.outcome(of: snapshot, saved: nil) {
                show(outcome, for: key, source: request.source, token: token)
            }
            return
        }
        // Until the save lands, the item shows what the job made.
        restores[token] = outcomes[key]
        show(.saving(snapshot.text(), request), for: key, source: request.source, token: token)
        let store = store
        let identity = identity
        let earlier = saves[key]?.task
        let save = Task { [weak self] in
            await earlier?.value
            let outcome: Outcome?
            do {
                let saved = try await store.save(snapshot, for: request, expecting: identity)
                outcome = Self.outcome(of: snapshot, saved: saved)
            } catch {
                outcome = .notSaved(snapshot.text(), request)
            }
            self?.saved(outcome, for: key, source: request.source, token: token)
        }
        saves[key] = (token, save)
    }

    /// A save landed. What it came to shows while the item still shows the text being saved: no later job has ended
    /// with something of its own to show meanwhile, though one may have been stopped. Text the store didn't take, from
    /// a job stopped or cut off, leaves what the item showed before the job.
    private func saved(_ outcome: Outcome?, for key: GenerationKey, source: ContentRef, token: UUID) {
        if saves[key]?.token == token { saves[key] = nil }
        if latest[key]?.token == token { latest[key] = nil }
        let before = restores.removeValue(forKey: token)
        let cameTo = outcome.map { Shown(source: source, outcome: $0, token: token) } ?? before
        // A later save that would bring this text back if its own isn't kept brings back what this save came to.
        for (later, shown) in restores where shown.token == token { restores[later] = cameTo }
        guard outcomes[key]?.token == token else { return }
        outcomes[key] = cameTo
    }

    private func show(_ outcome: Outcome, for key: GenerationKey, source: ContentRef, token: UUID) {
        outcomes[key] = Shown(source: source, outcome: outcome, token: token)
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
