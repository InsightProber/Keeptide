#if DEBUG
import CoreGraphics
import Foundation

/// The text recognizer UI tests use in place of Vision, which a test can't steer: after a moment, so that the column
/// shows the recognition under way, it finds the same synthetic text in any image. Only a test session's library uses
/// it, and only when `--fake-text-recognition` asks for it.
struct FakeTextRecognitionEngine: TextRecognitionEngine {
    static let text = "Synthetic text in image"

    let tier = EngineTier.onThisMac

    func recognizeText(in image: @escaping @Sendable () async throws -> CGImage,
                       keepingLineBreaks: Bool) -> any GenerationSource {
        TextRecognitionSource(info: GenerationInfo(engine: "On this Mac", model: "synthetic"),
                              keepingLineBreaks: keepingLineBreaks) {
            try await Task.sleep(for: .milliseconds(600))
            let line = TextInImage.Line(text: Self.text, bounds: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05))
            return TextInImage(paragraphs: [TextInImage.Paragraph(lines: [line], transcript: Self.text)])
        }
    }
}
#endif
