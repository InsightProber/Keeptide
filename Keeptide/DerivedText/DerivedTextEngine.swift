import CoreGraphics
import Foundation

/// Where an engine does its work, in the three tiers a person chooses between. The tier decides the lane its jobs run
/// in: work on this Mac goes one job at a time, and requests to cloud models up to three at once (`JobCenter`).
enum EngineTier: Equatable, Sendable {
    /// Apple's frameworks on this Mac: Vision, Translation and Natural Language.
    case onThisMac
    /// Apple Intelligence on this Mac, on a Mac that has it. No engine uses it yet.
    case appleIntelligence
    /// A cloud model a person set up with their own API key. No engine uses it yet.
    case cloud

    var lane: JobLane {
        switch self {
        case .onThisMac, .appleIntelligence: .onDevice
        case .cloud: .cloud
        }
    }
}

/// Recognizes the text in an image.
protocol TextRecognitionEngine: Sendable {
    var tier: EngineTier { get }

    /// A source that reads the image with `image` once its stream is read and recognizes the text in it, laid out line
    /// by line or as paragraphs (`TextInImage.text(keepingLineBreaks:)`).
    func recognizeText(in image: @escaping @Sendable () async throws -> CGImage,
                       keepingLineBreaks: Bool) -> any GenerationSource
}

/// Translates text.
protocol TranslationEngine: Sendable {
    var tier: EngineTier { get }

    /// The languages it translates from and into.
    func supportedLanguages() async -> [Locale.Language]
    /// What translating from one language into another needs on this Mac.
    func status(of pair: TranslationPair) async -> TranslationPairStatus
    /// A source that reads the text with `text` once its stream is read and translates it into `target`: from
    /// `source` when a person chose it, or else from the languages detected in it.
    func translate(_ text: @escaping @Sendable () async throws -> String, from source: Locale.Language?,
                   to target: Locale.Language) -> any GenerationSource
}

/// A language translations can be made in, and what translating a text into it needs on this Mac.
struct TranslationLanguage: Equatable, Sendable {
    /// The language as Translation lists it, in one of the regions it has the language in.
    let language: Locale.Language
    /// Nil where that isn't known: without the text's language, or for that language itself.
    let status: TranslationPairStatus?
}
