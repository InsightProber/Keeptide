import Foundation

/// A named part of one generation's output. Most generations write only `main`. A request that returns two texts at
/// once, such as the text in an image and its translation, sends each to its own channel (`StreamAccumulator`).
struct OutputChannel: Hashable, Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    static let main = OutputChannel("main")
    /// Text a tagged response put outside its tags, such as "Here you go:". Surfaces don't show it.
    static let untagged = OutputChannel("untagged")
}

/// Who is producing a generation, for the result's subtitle and for VoiceOver.
struct GenerationInfo: Equatable, Sendable {
    /// The engine as people see it, such as "On this Mac" or "Claude Haiku 5.5".
    var engine: String
    /// The provider's model identifier, when there is one.
    var model: String?
    /// Identifies the request on this Mac only; it is never sent anywhere.
    var requestID: UUID

    init(engine: String, model: String? = nil, requestID: UUID = UUID()) {
        self.engine = engine
        self.model = model
        self.requestID = requestID
    }
}

/// Tokens a cloud model reports. Engines on this Mac report none.
struct GenerationUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
}

/// How a source says it ended. Only `completed` is a whole result: Claude's `message_stop` with `end_turn`, OpenAI's
/// `response.completed`, or an engine on this Mac that finished. A response that merely stops, even one that
/// returned HTTP 200, ends without one and counts as interrupted.
enum FinishReason: Equatable, Sendable {
    case completed
    /// The output reached its length limit and is cut off.
    case truncated
    /// The model declined.
    case refused
}

/// What every source reports while it generates, whatever the model, provider or feature. A source throws
/// `GenerationError` when it fails. A person stopping a generation is not an event: the job records it.
enum GenerationEvent: Equatable, Sendable {
    case started(GenerationInfo)
    /// New text at the end of a channel.
    case delta(String, channel: OutputChannel = .main)
    /// The whole text of a channel, from a source that reports snapshots and rewrote earlier text. Surfaces show it
    /// at once rather than typing it.
    case replace(String, channel: OutputChannel = .main)
    case usage(GenerationUsage)
    /// How many paragraphs the source will write, such as a translation once it has read the original. Snapshots
    /// then report progress, in place of `GenerationJob.Options.expectedParagraphs`.
    case expecting(paragraphs: Int)
    case finished(FinishReason)

    /// Whether the event carries text, which is what the first-text time limit waits for.
    var carriesText: Bool {
        switch self {
        case .delta(let text, _), .replace(let text, _): !text.isEmpty
        case .started, .usage, .expecting, .finished: false
        }
    }
}

/// The languages a translation is from and to.
struct TranslationPair: Hashable, Sendable {
    var source: Locale.Language
    var target: Locale.Language
}

/// Why a generation could not finish. Each source maps its own errors to a kind, and `message` is written for the
/// result column. A refusal and a cut-off are not errors: they end with a `FinishReason`.
struct GenerationError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyRejected
        case accessDenied
        case regionUnavailable
        case noCredit
        case rateLimited
        case overloaded
        case modelUnavailable
        case inputTooLarge
        case verificationRequired
        /// The provider turned the request away for a reason of its own, which the message gives.
        case requestRejected
        case network
        /// The response stopped before it was complete: a broken stream, or nothing within the time limits.
        case streamInterrupted
        /// An engine on this Mac can't do this right now.
        case engineUnavailable
        /// The item can't be read: it changed or went, or its content is damaged.
        case contentUnavailable
        /// A translation on this Mac needs its languages downloaded first.
        case languageNotDownloaded
        /// This Mac can't translate between these languages.
        case languagePairUnsupported
        /// The language of the text couldn't be told, so a person chooses it.
        case sourceLanguageUnknown
        /// The text is already in the language it was to be translated into.
        case alreadyInTargetLanguage
    }

    var kind: Kind
    var message: String
    /// For `rateLimited`: how long the provider asked to wait before trying again.
    var retryAfter: Duration? = nil
    /// For a translation's languages: the pair to download, or that this Mac can't translate between.
    var pair: TranslationPair? = nil

    static let interrupted = GenerationError(kind: .streamInterrupted, message: "The response ended unexpectedly.")
    /// The item changed or went before its result could be made or kept.
    static let contentUnavailable = GenerationError(kind: .contentUnavailable,
                                                    message: "This item changed or is no longer available.")
}
