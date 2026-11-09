import CoreGraphics
import Vision

/// Recognizes text with Vision on this Mac. Recognition is always accurate, with language correction, and detects the
/// languages from the image itself, so Chinese and Japanese read as well as English: a fixed list of languages would
/// read every other script as its first one. Vision's document recognition gives the paragraphs and their lines.
struct VisionTextRecognitionEngine: TextRecognitionEngine {
    /// Which recognition a result was made with, kept with the result, so that one made by an earlier revision can be
    /// told apart.
    static let revision = "RecognizeDocumentsRequest.\(RecognizeDocumentsRequest().revision)"

    let tier = EngineTier.onThisMac

    func recognizeText(in image: @escaping @Sendable () async throws -> CGImage,
                       keepingLineBreaks: Bool) -> any GenerationSource {
        TextRecognitionSource(info: GenerationInfo(engine: "On this Mac", model: Self.revision),
                              keepingLineBreaks: keepingLineBreaks) {
            try await recognizedText(in: image())
        }
    }

    /// The text in `image`, paragraph by paragraph in reading order. Cancelling the task stops Vision part way, and
    /// this throws.
    func recognizedText(in image: CGImage) async throws -> TextInImage {
        try Task.checkCancellation()
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = false
        let documents = try await request.perform(on: image)
        return TextInImage(paragraphs: documents.flatMap { observation in
            observation.document.paragraphs.map { paragraph in
                TextInImage.Paragraph(
                    lines: paragraph.lines.compactMap { line in
                        line.topCandidates(1).first.map {
                            TextInImage.Line(text: $0.string, bounds: line.boundingBox.cgRect)
                        }
                    },
                    transcript: paragraph.transcript)
            }
        })
    }
}
