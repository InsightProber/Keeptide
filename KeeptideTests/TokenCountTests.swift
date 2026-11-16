import CoreGraphics
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

/// How many tokens a request's input is before it is sent, as each provider counts them or roughly on this Mac when
/// it can't, and what a request is likely to cost. A stand-in answers in place of the network; keys and content are
/// synthetic, and no test waits.
@MainActor
final class TokenCountTests: XCTestCase {
    private let key = APIKey("synthetic-key")
    private static let jsonHeaders = ["Content-Type": "application/json"]
    private static let noWait: @Sendable (Duration) async throws -> Void = { _ in }

    override func setUp() async throws {
        StubService.reset()
    }

    override func tearDown() async throws {
        StubService.reset()
    }

    // MARK: The providers' counts

    func testClaudeCountsTheInputAsTheRequestWouldSendIt() async throws {
        StubService.answer(.respond(status: 200, headers: Self.jsonHeaders,
                                    chunks: [Data(#"{"input_tokens":1180}"#.utf8)]))

        let count = try await claude(request()).countInputTokens(waiting: Self.noWait)

        XCTAssertEqual(count, 1_180)
        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.anthropic.com/v1/messages/count_tokens")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let body = try Self.json(seen.body)
        XCTAssertEqual(Set(body.keys), ["model", "system", "messages", "thinking", "output_config"],
                       "The request as it would be sent, but for what isn't input")
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["system"] as? String, "Translate the user's text into French.")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Quarterly plan")
    }

    func testOpenAICountsTheInputAsTheRequestWouldSendIt() async throws {
        StubService.answer(.respond(status: 200, headers: Self.jsonHeaders,
                                    chunks: [Data(#"{"object":"response.input_tokens","input_tokens":11}"#.utf8)]))

        let count = try await openAI(request(model: "gpt-6-luna")).countInputTokens(waiting: Self.noWait)

        XCTAssertEqual(count, 11)
        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.openai.com/v1/responses/input_tokens")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "authorization"), "Bearer synthetic-key")
        let body = try Self.json(seen.body)
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "reasoning"],
                       "The request as it would be sent, but for what isn't input")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
    }

    func testAnImageIsCountedAsItWouldBeSent() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = request(input: .image(png, mediaType: "image/png"))
        StubService.answer(.respond(status: 200, headers: Self.jsonHeaders,
                                    chunks: [Data(#"{"input_tokens":40}"#.utf8)]))

        _ = try await claude(image).countInputTokens(waiting: Self.noWait)
        _ = try await openAI(image).countInputTokens(waiting: Self.noWait)

        let claudeBody = try Self.json(StubService.requests.first?.body)
        let block = try XCTUnwrap((claudeBody["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual((block.first?["source"] as? [String: Any])?["data"] as? String, png.base64EncodedString())
        let openAIBody = try Self.json(StubService.requests.last?.body)
        let item = try XCTUnwrap((openAIBody["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(item.first?["image_url"] as? String, "data:image/png;base64," + png.base64EncodedString())
    }

    func testACountThatFailsIsSaidAsAGenerationsFailureIsAndIsntWaitedOnLong() async throws {
        let rejected = Data(#"{"type":"error","error":{"type":"authentication_error","message":"x"}}"#.utf8)
        StubService.answer(.respond(status: 401, headers: Self.jsonHeaders, chunks: [rejected]))
        let rejection = await failure { try await self.claude(self.request()).countInputTokens(waiting: Self.noWait) }
        XCTAssertEqual(rejection, GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key."))
        XCTAssertEqual(StubService.requests.count, 1)

        StubService.reset()
        let missing = Data((#"{"error":{"message":"No such model","type":"invalid_request_error","#
            + #""code":"model_not_found"}}"#).utf8)
        StubService.answer(.respond(status: 404, headers: Self.jsonHeaders, chunks: [missing]))
        let gone = await failure {
            try await self.openAI(self.request(model: "gpt-6-luna")).countInputTokens(waiting: Self.noWait)
        }
        XCTAssertEqual(gone?.kind, .modelUnavailable)
        XCTAssertEqual(StubService.requests.count, 1)

        let busy = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#.utf8)
        StubService.reset()
        StubService.answer([
            .respond(status: 529, headers: Self.jsonHeaders, chunks: [busy]),
            .respond(status: 200, headers: Self.jsonHeaders, chunks: [Data(#"{"input_tokens":7}"#.utf8)]),
        ])
        let count = try await claude(request()).countInputTokens(waiting: Self.noWait)
        XCTAssertEqual(count, 7, "A count changes nothing and costs nothing, so it may be asked for again")
        XCTAssertEqual(StubService.requests.count, 2)

        let longPause = Self.jsonHeaders.merging(["retry-after": "30"]) { $1 }
        for (headers, requests) in [(Self.jsonHeaders, 2), (longPause, 1)] {
            StubService.reset()
            let waits = Waits()
            StubService.answer(.respond(status: 529, headers: headers, chunks: [busy]))
            let failed = await failure {
                try await self.claude(self.request()).countInputTokens(waiting: { waits.record($0) })
            }
            XCTAssertEqual(failed?.kind, .overloaded)
            XCTAssertEqual(StubService.requests.count, requests, "Once more at most, and not after a long pause")
            XCTAssertTrue(waits.all.allSatisfy { $0 <= .seconds(2) }, "\(waits.all)")
        }
    }

    func testAnAnswerWithoutACountIsntOne() async throws {
        for answer in [#"{}"#, #"{"input_tokens":-1}"#, #"{"input_tokens":"many"}"#, "<html></html>"] {
            for provider in [ProviderPreset.ID.anthropic, .openAI] {
                StubService.reset()
                StubService.answer(.respond(status: 200, headers: Self.jsonHeaders, chunks: [Data(answer.utf8)]))

                let error = await failure {
                    switch provider {
                    case .anthropic: try await self.claude(self.request()).countInputTokens(waiting: Self.noWait)
                    case .openAI: try await self.openAI(self.request()).countInputTokens(waiting: Self.noWait)
                    }
                }

                XCTAssertEqual(error, .interrupted, "\(provider) \(answer)")
                XCTAssertEqual(StubService.requests.count, 1, "Asked once, and not again: \(provider) \(answer)")
            }
        }
    }

    // MARK: A rough count on this Mac

    func testARoughCountLeansHighAndCountsTextAndImages() throws {
        XCTAssertEqual(TokenEstimate.rough("hello world"), 6, "Two characters of ASCII to a token")
        XCTAssertEqual(TokenEstimate.rough("季度报告"), 6, "A character of Chinese and half again")
        XCTAssertEqual(TokenEstimate.rough("Q3 季度"), 5)
        XCTAssertEqual(TokenEstimate.rough("👍🏽"), 4, "Two tokens for each character beyond the basic plane")
        XCTAssertEqual(TokenEstimate.rough(""), 0)
        XCTAssertEqual(TokenEstimate.rough(request(text: "hello world", instructions: "Translate.")), 11)
        let image = request(input: .image(try Self.png(width: 280, height: 57), mediaType: "image/png"),
                            instructions: "Read.")
        XCTAssertEqual(TokenEstimate.rough(image), 30 + 3, "A 28-pixel square to a token, as Claude reads images")
        let photo = request(input: .image(try Self.png(width: 2_100, height: 2_100), mediaType: "image/png"),
                            instructions: "")
        XCTAssertEqual(TokenEstimate.rough(photo), 4_784, "No more than Claude reads of any image")
        XCTAssertNil(TokenEstimate.rough(request(input: .image(Data([1, 2, 3]), mediaType: "image/png"))),
                     "An image whose size can't be read isn't guessed at")
    }

    // MARK: What it is likely to cost

    func testAnEstimateIsWhatTheInputAndTheLikelyAnswerCost() throws {
        let haiku = ModelPrice(input: 0.10, output: 0.50, longPrompt: .init(above: 100_000, input: 0.50, output: 2.50))
        let text = String(repeating: "word ", count: 800)

        let counted = CostEstimate(for: request(text: text), task: .translate, inputTokens: 1_020, counted: true,
                                   price: haiku)
        XCTAssertEqual(counted.outputTokens, 1_020, "A translation is about as long as its original, as it was counted")
        XCTAssertEqual(counted.dollars ?? 0, (1_020 * 0.10 + 1_020 * 0.50) / 1_000_000, accuracy: 1e-12)
        XCTAssertTrue(counted.counted)
        XCTAssertEqual(CostEstimate(for: request(text: text), task: .translate, inputTokens: 2_010, counted: false,
                                    price: haiku).outputTokens, 2_000, "Or as it was counted roughly")

        let unreadable = request(input: .image(Data([1]), mediaType: "image/png"))
        XCTAssertEqual(CostEstimate(for: unreadable, task: .extractText, inputTokens: 1_600, counted: false,
                                    price: haiku).outputTokens, 1_000, "About a page of text")
        XCTAssertEqual(CostEstimate(for: unreadable, task: .translate, inputTokens: 1_600, counted: false,
                                    price: haiku).outputTokens, 2_000, "The text and its translation")
        let screen = request(input: .image(try Self.png(width: 2_048, height: 1_536), mediaType: "image/png"))
        XCTAssertEqual(CostEstimate(for: screen, task: .extractText, inputTokens: 4_100, counted: true,
                                    price: haiku).outputTokens, 4_070, "As much text as the image could hold")
        XCTAssertEqual(CostEstimate(for: screen, task: .translate, inputTokens: 4_100, counted: true,
                                    price: haiku).outputTokens, 8_140)
        XCTAssertEqual(CostEstimate(for: request(text: text, maxOutputTokens: 500), task: .translate,
                                    inputTokens: 1_020, counted: true, price: haiku).outputTokens, 500,
                       "No more than the request lets the model write")
        XCTAssertNil(CostEstimate(for: request(text: text), task: .translate, inputTokens: 10, counted: true,
                                  price: nil).dollars, "A model without a price is only its tokens")
    }

    func testAModelThatThinksFirstIsLikelyToWriteMore() {
        let price = ModelPrice(input: 1, output: 5)
        let shapes: [(ModelRequest.Thinking?, ModelRequest.Effort?, Int)] = [
            (.disabled, .low, 20), (.betweenTools, .low, 20), (nil, .noReasoning, 20),
            (nil, .low, 1_020), (.adaptive, nil, 1_020), (nil, nil, 1_020),
        ]
        for (thinking, effort, output) in shapes {
            let shaped = request(text: "Quarterly plan", thinking: thinking, effort: effort)

            let estimate = CostEstimate(for: shaped, task: .translate, inputTokens: 20, counted: true, price: price)

            XCTAssertEqual(estimate.outputTokens, output,
                           "\(String(describing: thinking)) \(String(describing: effort))")
        }
    }

    func testAnEstimateIsAtTheLongPromptsPriceOnceThePromptIsLong() {
        let haiku = ModelPrice(input: 0.10, output: 0.50, longPrompt: .init(above: 100_000, input: 0.50, output: 2.50))
        let image = request(input: .image(Data([1]), mediaType: "image/png"))

        let within = CostEstimate(for: image, task: .extractText, inputTokens: 100_000, counted: true, price: haiku)
        let beyond = CostEstimate(for: image, task: .extractText, inputTokens: 100_001, counted: true, price: haiku)

        XCTAssertEqual(within.dollars ?? 0, (100_000 * 0.10 + 1_000 * 0.50) / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(beyond.dollars ?? 0, (100_001 * 0.50 + 1_000 * 2.50) / 1_000_000, accuracy: 1e-12)
    }

    func testAnEstimateIsShownBeforeSendingWhenItIsLargeOrTheInputIs() {
        let sonnet = ModelPrice(input: 2, output: 10)
        let cheap = ModelPrice(input: 0.10, output: 0.50)
        let short = request(text: "Quarterly plan")

        XCTAssertFalse(CostEstimate(for: short, task: .translate, inputTokens: 30_000, counted: true, price: cheap)
            .showsBeforeSending)
        XCTAssertTrue(CostEstimate(for: short, task: .translate, inputTokens: 30_001, counted: true, price: cheap)
            .showsBeforeSending, "More than 30,000 tokens in")
        XCTAssertTrue(CostEstimate(for: short, task: .translate, inputTokens: 30_001, counted: true, price: nil)
            .showsBeforeSending, "Whatever the price")
        XCTAssertTrue(CostEstimate(for: short, task: .translate, inputTokens: 4_167, counted: true, price: sonnet)
            .showsBeforeSending, "More than five cents, in and out")
        XCTAssertFalse(CostEstimate(for: short, task: .translate, inputTokens: 4_166, counted: true, price: sonnet)
            .showsBeforeSending)
    }

    func testACostIsSaidRoughlyAsAPersonReadsIt() {
        let said: [(Double, String)] = [
            (0, "less than $0.001"), (0.000_49, "less than $0.001"), (0.000_999, "less than $0.001"),
            (0.001, "about $0.001"), (0.001_23, "about $0.001"), (0.002_5, "about $0.003"), (0.004_7, "about $0.005"),
            (0.009_5, "about $0.01"), (0.009_99, "about $0.01"), (0.01, "about $0.01"), (0.015_8, "about $0.02"),
            (0.025, "about $0.03"), (0.333, "about $0.33"), (12.5, "about $12.50"), (1_234.5, "about $1,234.50"),
        ]
        for (dollars, text) in said {
            XCTAssertEqual(CostEstimate.describe(dollars), text, "\(dollars)")
        }
    }

    // MARK: Fixtures

    private func request(input: ModelRequest.Input? = nil, text: String = "Quarterly plan",
                         instructions: String = "Translate the user's text into French.",
                         model: String = "claude-haiku-5-5", maxOutputTokens: Int = 16_384,
                         thinking: ModelRequest.Thinking? = .disabled,
                         effort: ModelRequest.Effort? = .low) -> ModelRequest {
        ModelRequest(model: model, modelName: "Synthetic model", instructions: instructions,
                     input: input ?? .text(text), maxOutputTokens: maxOutputTokens, thinking: thinking, effort: effort)
    }

    private func claude(_ request: ModelRequest) -> AnthropicMessagesSource {
        AnthropicMessagesSource(client: ModelClient(protocolClasses: [StubService.self]), key: key, request: request)
    }

    private func openAI(_ request: ModelRequest) -> OpenAIResponsesSource {
        OpenAIResponsesSource(client: ModelClient(protocolClasses: [StubService.self]), key: key, request: request)
    }

    private func failure(_ count: () async throws -> Int) async -> GenerationError? {
        do {
            let counted = try await count()
            XCTFail("Counted \(counted) instead of failing")
            return nil
        } catch {
            return error as? GenerationError
        }
    }

    private static func json(_ body: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString,
                                                                          1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// The pauses asked for, in order, without waiting.
private final class Waits: Sendable {
    private let lock = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var all: [Duration] { lock.withLock { $0 } }

    func record(_ pause: Duration) {
        lock.withLock { $0.append(pause) }
    }
}
