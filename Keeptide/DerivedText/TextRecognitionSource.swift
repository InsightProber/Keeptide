import Foundation

/// The source for an engine that recognizes the text of an image all at once, as Vision does. Once its stream is read,
/// it starts recognizing; when recognition ends, it sends the whole text in one piece, laid out as asked, and finishes.
/// An image with no text finishes without any. When the job stops reading, the recognition is cancelled.
struct TextRecognitionSource: GenerationSource {
    var info: GenerationInfo
    var keepingLineBreaks: Bool
    var recognize: @Sendable () async throws -> TextInImage

    func events() -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self,
                                                                    throwing: (any Error).self)
        let info = info
        let keepingLineBreaks = keepingLineBreaks
        let recognize = recognize
        let work = Task {
            continuation.yield(.started(info))
            do {
                let text = try await recognize().text(keepingLineBreaks: keepingLineBreaks)
                if !text.isEmpty { continuation.yield(.delta(text)) }
                continuation.yield(.finished(.completed))
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.failure(for: error))
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// What a result column says when recognition fails: the item is gone or changed, its image can't be read or is
    /// too large, or the engine failed.
    static func failure(for error: any Error) -> GenerationError {
        switch error {
        case let error as GenerationError:
            error
        case StoreError.notFound, StoreError.staleReference:
            .contentUnavailable
        case PreviewLoadError.couldNotDecodeImage, PreviewLoadError.invalidImageDimensions:
            GenerationError(kind: .contentUnavailable, message: "This image couldn't be read.")
        case PreviewLoadError.originalImageTooLarge:
            GenerationError(kind: .inputTooLarge, message: "This image is too large to recognize text in.")
        default:
            GenerationError(kind: .engineUnavailable, message: "Text couldn't be recognized in this image.")
        }
    }
}
