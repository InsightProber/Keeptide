import CoreGraphics
import Foundation
import Observation

/// Makes text from items and keeps it beside them on this Mac: for now, the text recognized in images.
///
/// It starts one job per item and operation in `jobs`, so a newer request stops the one under way, and saves each
/// job's final snapshot once in the store, as the snapshot's `saveDecision` says, under the store generation the
/// library opened with. It remembers how the latest job for each item and operation ended in this session. A surface
/// shows a job while it runs, then its outcome, and otherwise what the store kept from earlier sessions.
@MainActor
@Observable
final class DerivedTextCoordinator {
    /// How the latest job for an item and operation ended, where that is something to show. A job a person stopped,
    /// or one cut off, while an earlier whole result stays, leaves no outcome: the store has that result.
    enum Outcome: Equatable, Sendable {
        /// What the job made, as saved beside its item.
        case saved(DerivedText)
        /// The engine found no text.
        case noText
        /// The job made text, but the library couldn't keep it.
        case notSaved
        /// Nothing was made, or what was made belongs to content that changed or went meanwhile.
        case failed(GenerationError)
    }

    let jobs = JobCenter()
    private(set) var outcomes: [GenerationKey: Outcome] = [:]

    @ObservationIgnored private let store: DerivedTextStore
    @ObservationIgnored private let identity: StoreIdentity
    @ObservationIgnored private let recognizer: any TextRecognitionEngine
    @ObservationIgnored private let image: @Sendable (ContentRef) async throws -> CGImage
    /// The latest request for each item and operation. Only its ending changes what the item shows.
    @ObservationIgnored private var latest: [GenerationKey: UUID] = [:]
    /// Saves under way, which closing the library waits for.
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
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

    func job(for source: ContentRef, operation: DerivedTextOperation) -> GenerationJob? {
        jobs.job(for: Self.key(for: source, operation: operation))
    }

    func outcome(for source: ContentRef, operation: DerivedTextOperation) -> Outcome? {
        outcomes[Self.key(for: source, operation: operation)]
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
        let request = DerivedTextRequest(source: source, operation: .extractText, keepsLineBreaks: keepingLineBreaks)
        return start(request, lane: recognizer.tier.lane, options: options, generation: generation)
    }

    func stop(_ source: ContentRef, operation: DerivedTextOperation) {
        jobs.stop(Self.key(for: source, operation: operation))
    }

    /// Stops every job and waits for the saves under way, as Keeptide does before it closes the library. Nothing
    /// starts or is saved after.
    func stopAndDrain() async {
        isClosed = true
        jobs.stopAll()
        let pending = Array(saves.values)
        saves = [:]
        for save in pending { await save.value }
    }

    /// One job per item, facet and operation: a clip and the snippet saved from it are separate items.
    private static func key(for source: ContentRef, operation: DerivedTextOperation) -> GenerationKey {
        GenerationKey(item: "\(source.itemID.rawValue.uuidString)/\(source.facet.rawValue)", action: operation.rawValue)
    }

    private func start(_ request: DerivedTextRequest, lane: JobLane, options: GenerationJob.Options,
                       generation: any GenerationSource) -> GenerationJob {
        let key = Self.key(for: request.source, operation: request.operation)
        let token = UUID()
        latest[key] = token
        return jobs.start(key, lane: lane, priority: .user, options: options, source: generation) { [weak self] in
            self?.end($0, of: request, key: key, token: token)
        }
    }

    private func end(_ snapshot: GenerationSnapshot, of request: DerivedTextRequest, key: GenerationKey,
                     token: UUID) {
        // A newer request, or the library closing, decides what the item shows.
        guard !isClosed, latest[key] == token else { return }
        let store = store
        let identity = identity
        saves[token] = Task { [weak self] in
            let outcome: Outcome?
            do {
                let saved = try await store.save(snapshot, for: request, expecting: identity)
                outcome = Self.outcome(of: snapshot, saved: saved)
            } catch {
                outcome = .notSaved
            }
            guard let self else { return }
            saves[token] = nil
            guard latest[key] == token else { return }
            outcomes[key] = outcome
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
