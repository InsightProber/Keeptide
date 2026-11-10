import Foundation
import Translation

/// Translates on this Mac with Apple's Translation, after Natural Language has told the text's languages.
struct OnDeviceTranslationEngine: TranslationEngine {
    let tier = EngineTier.onThisMac
    var translator: any PairTranslator = SystemTranslator()

    func translate(_ text: @escaping @Sendable () async throws -> String, from source: Locale.Language?,
                   to target: Locale.Language) -> any GenerationSource {
        TranslationSource(info: GenerationInfo(engine: "On this Mac", model: "Translation"), source: source,
                          target: target, translator: translator, text: text)
    }
}

/// Apple's Translation, for the languages downloaded on this Mac. It never downloads anything: that asks the person,
/// in the system's own sheet.
struct SystemTranslator: PairTranslator {
    func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    /// The status the system reports. A language can go between this and the translation, so a translation still
    /// handles one found missing.
    func status(of pair: TranslationPair) async -> TranslationPairStatus {
        switch await LanguageAvailability().status(from: pair.source, to: pair.target) {
        case .installed: .installed
        case .supported: .needsDownload
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    /// One session translates the paragraphs one at a time, so each goes out as soon as it is done. A paragraph with
    /// nothing in it to translate, such as one of emoji, stays as it is. A stop ends the stream at once and sends no
    /// more paragraphs; the one under way finishes in the system all the same (measured on macOS 27: neither task
    /// cancellation nor `TranslationSession.cancel()` shortens it), so a translation asked for next waits for it.
    func translate(_ paragraphs: [String], _ pair: TranslationPair) -> AsyncThrowingStream<String, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: (any Error).self)
        let work = Task {
            do {
                let session = TranslationSession(installedSource: pair.source, target: pair.target)
                for paragraph in paragraphs {
                    try Task.checkCancellation()
                    do {
                        continuation.yield(try await session.translate(paragraph).targetText)
                    } catch where TranslationError.nothingToTranslate ~= error {
                        continuation.yield(paragraph)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: Task.isCancelled ? CancellationError() : Self.error(for: error))
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// Translation's errors in Keeptide's terms.
    static func error(for error: any Error) -> any Error {
        if error is CancellationError || TranslationError.alreadyCancelled ~= error { return CancellationError() }
        if TranslationError.notInstalled ~= error { return PairTranslationError.notDownloaded }
        if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return PairTranslationError.unsupported
        }
        if TranslationError.unableToIdentifyLanguage ~= error { return PairTranslationError.languageUnknown }
        return PairTranslationError.failed
    }
}
