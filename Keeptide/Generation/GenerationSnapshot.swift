import Foundation

/// What a surface shows for one generation at one moment. `GenerationJob` publishes one at most about 30 times a
/// second.
struct GenerationSnapshot: Equatable, Sendable {
    /// Why a job was stopped. It decides whether the text received until then is worth keeping.
    enum StopReason: Equatable, Sendable {
        /// A person stopped it.
        case person
        /// A newer request for the same item and action replaced it.
        case superseded
        /// Keeptide stopped everything, as when it quits or switches libraries.
        case shutdown
    }

    enum Phase: Equatable, Sendable {
        /// Waiting for a free place in its lane.
        case queued
        /// Started; no text yet.
        case waiting
        /// Text is arriving.
        case streaming
        case finished(FinishReason)
        /// The text received until then is kept.
        case stopped(StopReason)
        /// The text received until then is kept, with the reason.
        case failed(GenerationError)

        var isActive: Bool {
            switch self {
            case .queued, .waiting, .streaming: true
            case .finished, .stopped, .failed: false
            }
        }
    }

    var phase: Phase
    var info: GenerationInfo?
    var texts: [OutputChannel: String]
    var usage: GenerationUsage?
    /// From 0 to 1 when the generation has countable parts, such as a translation's paragraphs; otherwise nil, and
    /// surfaces show progress without an amount.
    var progress: Double?
    /// True when a tagged response didn't hold its text in its tags (`StreamAccumulator.TaggedChannels`).
    var separationFailed: Bool

    init(
        phase: Phase, info: GenerationInfo? = nil, texts: [OutputChannel: String] = [:],
        usage: GenerationUsage? = nil, progress: Double? = nil, separationFailed: Bool = false
    ) {
        self.phase = phase
        self.info = info
        self.texts = texts
        self.usage = usage
        self.progress = progress
        self.separationFailed = separationFailed
    }

    func text(_ channel: OutputChannel = .main) -> String {
        texts[channel, default: ""]
    }

    var hasText: Bool { texts.values.contains { !$0.isEmpty } }

    /// What the result store does with a generation that has ended. A whole result replaces an earlier one, and one with
    /// nothing in it, as when an image has no text, leaves none. A result a person stopped, or one that was cut off, is
    /// kept only while there is no whole one. A result that a newer request replaced, that shutdown ended, that failed or
    /// that the model refused isn't saved, and leaves the earlier one.
    var saveDecision: SaveDecision {
        switch phase {
        case .finished(.completed): hasText ? .replace : .clear
        case .finished(.truncated), .stopped(.person): hasText ? .keepIfNoCompleteResult : .discard
        case .finished(.refused), .stopped(.superseded), .stopped(.shutdown), .failed, .queued, .waiting, .streaming:
            .discard
        }
    }
}

enum SaveDecision: Equatable, Sendable {
    /// A whole result: it replaces any earlier one.
    case replace
    /// A whole result with nothing in it: any earlier one goes, and nothing takes its place. A source that should
    /// have made something, and made nothing, fails instead.
    case clear
    /// Part of a result: keep it, marked Stopped, only when the item has no whole result.
    case keepIfNoCompleteResult
    /// Nothing to keep.
    case discard
}
