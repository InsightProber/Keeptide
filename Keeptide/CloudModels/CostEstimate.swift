import Foundation
import ImageIO

/// Tokens counted roughly on this Mac, for when a provider can't count them or may not yet be sent the content. A rough
/// count errs high, so that an estimate of what a request costs errs toward more.
enum TokenEstimate {
    /// The most tokens Claude reads of an image, which it scales down to read.
    static let imageTokenLimit = 4_784

    /// Two characters of ASCII to a token, which English and code don't go below; a character of any other script in
    /// the basic plane a token and a half, which Chinese and Japanese come close to; and two tokens for a character
    /// beyond it, such as an emoji.
    static func rough(_ text: String) -> Int {
        var ascii = 0
        var basic = 0
        var beyond = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                ascii += 1
            } else if scalar.value <= 0xFFFF {
                basic += 1
            } else {
                beyond += 1
            }
        }
        return (ascii + 1) / 2 + (3 * basic + 1) / 2 + 2 * beyond
    }

    /// A request's instructions and content, or nil for an image whose size can't be read, which isn't guessed at.
    static func rough(_ request: ModelRequest) -> Int? {
        let content: Int? = switch request.input {
        case .text(let text): rough(text)
        case .image(let data, _): imageTokens(data)
        }
        return content.map { $0 + rough(request.instructions) }
    }

    /// An image's tokens, a token for each 28-pixel square as Claude reads images and no more than it reads of any,
    /// from the image's size without decoding it; nil when the size can't be read.
    static func imageTokens(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return min(((width + 27) / 28) * ((height + 27) / 28), imageTokenLimit)
    }
}

/// What a request is likely to cost before it is sent: its input, counted by its provider or roughly on this Mac, and
/// the answer it is likely to get, at the catalog's price. An estimate, as the catalog's prices are.
struct CostEstimate: Equatable, Sendable {
    /// An estimate above this many dollars is shown before the request is sent.
    static let dollarsShownFirst = 0.05
    /// An input above this many tokens is shown before the request is sent, whatever it costs.
    static let tokensShownFirst = 30_000
    /// About a page of text, the least an image is likely to hold.
    static let pageOfText = 1_000
    /// What a model that thinks or reasons before it answers is likely to write doing so, at the least effort.
    static let thinkingAllowance = 1_000

    let inputTokens: Int
    /// The likely answer's tokens, thinking included, no more than the request lets the model write.
    let outputTokens: Int
    /// Whether the provider counted the input, rather than this Mac roughly.
    let counted: Bool
    /// Nil for a model the catalog has no price for, which is then only its tokens.
    let dollars: Double?

    init(for request: ModelRequest, task: DerivedTextOperation, inputTokens: Int, counted: Bool, price: ModelPrice?) {
        let answer = switch (task, request.input) {
        // A translation is about as long as its original, as its provider counted it or as this Mac does.
        case (.translate, .text(let text)): counted ? inputTokens : TokenEstimate.rough(text)
        // The text in the image, and its translation.
        case (.translate, .image(let data, _)): 2 * Self.text(in: data)
        case (.extractText, .image(let data, _)): Self.text(in: data)
        case (.extractText, .text): Self.pageOfText
        }
        let thinksFirst = !(request.thinking == .disabled || request.thinking == .betweenTools
            || request.effort == .noReasoning)
        self.inputTokens = inputTokens
        outputTokens = min(answer + (thinksFirst ? Self.thinkingAllowance : 0), request.maxOutputTokens)
        self.counted = counted
        dollars = price?.cost(input: inputTokens, output: outputTokens)
    }

    /// Whether the person sees the estimate before the request is sent: when it is large, or its input is.
    var showsBeforeSending: Bool {
        inputTokens > Self.tokensShownFirst || (dollars ?? 0) > Self.dollarsShownFirst
    }

    /// An amount of dollars as a person reads an estimate of it, such as "about $0.001" or "less than $0.001", rounded
    /// half up.
    static func describe(_ dollars: Double) -> String {
        guard dollars >= 0.001 else { return "less than $0.001" }
        let number = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
        let amount = dollars < 0.01
            ? dollars.formatted(number.precision(.significantDigits(1)).rounded(rule: .toNearestOrAwayFromZero))
            : dollars.formatted(number.precision(.fractionLength(2)).rounded(rule: .toNearestOrAwayFromZero))
        return "about $" + amount
    }

    /// As much text as an image could hold: as many tokens as the image is, and no less than a page.
    private static func text(in image: Data) -> Int {
        max(pageOfText, TokenEstimate.imageTokens(image) ?? 0)
    }
}
