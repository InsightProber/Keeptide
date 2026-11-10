import CoreGraphics
import Vision

/// Recognizes text with Vision on this Mac. Recognition is always accurate, with language correction, and detects the
/// languages from the image itself, so Chinese and Japanese read as well as English: a fixed list of languages would
/// read every other script as its first one. Vision's document recognition gives the paragraphs and their lines, and
/// a tall image, such as a long screenshot, is read in strips (`StripReading`).
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
    /// this throws `CancellationError`.
    func recognizedText(in image: CGImage) async throws -> TextInImage {
        try Task.checkCancellation()
        guard let fraction = StripReading.stripFraction(width: image.width, height: image.height) else {
            return TextInImage(paragraphs: try await Self.paragraphs(in: image, from: 0, to: 1))
        }
        return TextInImage(paragraphs: try await StripReading.read(stripFraction: fraction) { bottom, top in
            try await Self.paragraphs(in: image, from: bottom, to: top)
        })
    }

    /// The paragraphs Vision finds between two heights of `image`, in its normalized coordinates with the origin at
    /// the lower left.
    private static func paragraphs(in image: CGImage, from bottom: CGFloat,
                                   to top: CGFloat) async throws -> [TextInImage.Paragraph] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.maximumCandidateCount = 1
        request.barcodeDetectionOptions.enabled = false
        let height = top - bottom
        if height < 1 { request.regionOfInterest = NormalizedRect(x: 0, y: bottom, width: 1, height: height) }
        let documents: [DocumentObservation]
        do {
            documents = try await request.perform(on: image)
        } catch where Task.isCancelled {
            throw CancellationError()
        }
        // What Vision returns as it is cancelled is not the image's text either.
        try Task.checkCancellation()
        return documents.flatMap { observation in
            observation.document.paragraphs.map { paragraph in
                TextInImage.Paragraph(
                    lines: paragraph.lines.compactMap { line in
                        line.topCandidates(1).first.map { candidate in
                            // Vision places a line within the region it read.
                            let box = line.boundingBox.cgRect
                            return TextInImage.Line(text: candidate.string,
                                                    bounds: CGRect(x: box.minX, y: bottom + box.minY * height,
                                                                   width: box.width, height: box.height * height))
                        }
                    },
                    transcript: paragraph.transcript)
            }
        }
    }
}
