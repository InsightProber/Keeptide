import CoreGraphics
import Foundation
import Observation

/// Makes text from items and keeps it beside them on this Mac: for now, the text recognized in images.
///
/// It starts one job per item and operation in `jobs`, so a newer request stops the one under way, and saves each
/// job's final snapshot once in the store, as the snapshot's `saveDecision` says, under the store generation the
/// library opened with. Saves for one item land in the order their jobs ended. It remembers how the latest job for
/// each item and operation ended in this session, for the content the job was made from. A surface shows a job while
/// it runs, then its outcome, and otherwise what the store kept from earlier sessions.
@MainActor
@Observable
final class DerivedTextCoordinator {
    /// How the latest job for an item and operation ended, where that is something to show. A job a person stopped,
    /// or one cut off, while an earlier whole result stays, leaves no outcome: the store has that result.
    enum Outcome: Equatable, Sendable {
        /// The job ended with this text, which is being saved.
        case saving(String)
        /// What the job made, as saved beside its item.
        case saved(DerivedText)
        /// The engine found no text.
        case noText
        /// The job made this text, but the library couldn't keep it.
        case notSaved(String)
        /// Nothing was made, or what was made belongs to content that changed or went meanwhile.
        case failed(GenerationError)
    }

    let jobs = JobCenter()
    /// Each outcome with the content it was made from.
    private var outcomes: [GenerationKey: (source: ContentRef, outcome: Outcome)] = [:]

    @ObservationIgnored private let store: DerivedTextStore
    @ObservationIgnored private let identity: StoreIdentity
    @ObservationIgnored private let recognizer: any TextRecognitionEngine
    @ObservationIgnored private let image: @Sendable (ContentRef) async throws -> CGImage
    /// The latest request for each item and operation, while its job runs or its result is saved. Only its ending
    /// changes what the item shows.
    @ObservationIgnored private var latest: [GenerationKey: (token: UUID, source: ContentRef)] = [:]
    /// The latest save for each item and operation, which a later save waits for. Closing the library waits for all.
    @ObservationIgnored private var saves: [GenerationKey: (token: UUID, task: Task<Void, Never>)] = [:]
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
        guard latest[key]?.source == source else { return nil }
        return jobs.job(for: key)
    }

    /// How the latest job ended for exactly this content of an item. Nil when that job was for content it had before.
    func outcome(for source: ContentRef, operation: DerivedTextOperation) -> Outcome? {
        guard let kept = outcomes[Self.key(for: source, operation: operation)], kept.source == source else {
            return nil
        }
        return kept.outcome
    }

    /// What a job saved for exactly this content of an item, in this session or an earlier one; nil when there is
    /// nothing, or it can't be read.
    func savedResult(for source: ContentRef, operation: DerivedTextOperation) async -> DerivedText? {
        try? await store.result(for: source, operation: operation)
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

    func stop(_ source: ContentRef, operation: DerivedTextOperation) {
        jobs.stop(Self.key(for: source, operation: operation))
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
        guard snapshot.saveDecision != .discard else {
            latest[key] = nil
            show(Self.outcome(of: snapshot, saved: nil), for: key, source: request.source)
            return
        }
        // Until the save lands, the item shows what the job made.
        show(.saving(snapshot.text()), for: key, source: request.source)
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
                outcome = .notSaved(snapshot.text())
            }
            self?.saved(outcome, for: key, source: request.source, token: token)
        }
        saves[key] = (token, save)
    }

    private func saved(_ outcome: Outcome?, for key: GenerationKey, source: ContentRef, token: UUID) {
        if saves[key]?.token == token { saves[key] = nil }
        guard latest[key]?.token == token else { return }
        latest[key] = nil
        show(outcome, for: key, source: source)
    }

    private func show(_ outcome: Outcome?, for key: GenerationKey, source: ContentRef) {
        outcomes[key] = outcome.map { (source, $0) }
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
