import XCTest
@testable import Keeptide

/// Claude's Messages API, streamed: what Keeptide sends, and how what comes back becomes a generation's events. A
/// stand-in answers in place of the network with synthetic events; the key and content are synthetic.
@MainActor
final class AnthropicMessagesTests: XCTestCase {
    private let key = APIKey("synthetic-anthropic-key")
    private static let stream = ["Content-Type": "text/event-stream"]

    override func setUp() async throws {
        StubService.reset()
    }

    override func tearDown() async throws {
        StubService.reset()
    }

    func testATextIsSentAsClaudeExpectsIt() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("Bonjour")]))

        _ = await collect(source(request()))

        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-api-key"), "synthetic-anthropic-key")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = try Self.json(seen.body)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "Translate the user's text into French.")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "The content in a message of its own")
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "Quarterly plan")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "stream", "system", "messages", "thinking",
                                        "output_config"], "Nothing else, such as sampling, fallbacks or metadata")
    }

    func testAnImageIsSentAsABase64BlockOfItsOwn() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("Total")]))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        _ = await collect(source(request(.image(png, mediaType: "image/png"))))

        let body = try Self.json(StubService.requests.first?.body)
        let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "image")
        let image = try XCTUnwrap(content.first?["source"] as? [String: Any])
        XCTAssertEqual(image["type"] as? String, "base64")
        XCTAssertEqual(image["media_type"] as? String, "image/png")
        XCTAssertEqual(image["data"] as? String, png.base64EncodedString())
    }

    func testThinkingAndEffortAreSentOnlyAsGiven() async throws {
        for (thinking, effort, sentThinking, sentEffort) in [
            (nil, nil, nil, nil), (.adaptive, .medium, "adaptive", "medium"),
            (.betweenTools, .high, "between_tools", "high"),
        ] as [(ModelRequest.Thinking?, ModelRequest.Effort?, String?, String?)] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("x")]))

            _ = await collect(source(request(thinking: thinking, effort: effort)))

            let body = try Self.json(StubService.requests.first?.body)
            XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, sentThinking)
            XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, sentEffort)
            if thinking == nil { XCTAssertNil(body["thinking"]) }
            if effort == nil { XCTAssertNil(body["output_config"]) }
        }
    }

    func testAStreamedAnswerBecomesTheGenerationsEvents() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("message_start", Self.start(input: 21)),
            ("content_block_start", Self.blockStart(0, "thinking")),
            ("content_block_delta", Self.delta(0, "thinking_delta", "thinking", "Hidden")),
            ("content_block_stop", Self.blockStop(0)),
            ("content_block_start", Self.blockStart(1, "text")),
            ("content_block_delta", Self.text("Bon", index: 1)),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_delta", Self.text("jour", index: 1)),
            ("content_block_stop", Self.blockStop(1)),
            ("message_delta", Self.messageDelta(stop: "end_turn", output: 3, input: 34)),
            ("message_stop", Self.messageStop),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertNil(error)
        guard case .started(let info)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(info.engine, "Claude Haiku 5.5")
        XCTAssertEqual(info.model, "claude-haiku-5-5")
        XCTAssertEqual(Array(events.dropFirst()), [
            .delta("Bon"), .delta("jour"), .usage(GenerationUsage(inputTokens: 34, outputTokens: 3)),
            .finished(.completed),
        ], "Thinking stays hidden")
    }

    func testEachWayClaudeStopsEndsTheGenerationAsItShould() async throws {
        for (reason, ending) in [("end_turn", FinishReason.completed), ("stop_sequence", .completed),
                                 ("max_tokens", .truncated), ("refusal", .refused)] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("x", stop: reason)]))

            let (events, error) = await collect(source(request()))

            XCTAssertNil(error, reason)
            XCTAssertEqual(events.last, .finished(ending), reason)
        }
        for (reason, failure) in [
            ("model_context_window_exceeded",
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            ("pause_turn", GenerationError.interrupted), ("tool_use", GenerationError.interrupted),
        ] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("x", stop: reason)]))

            let (events, error) = await collect(source(request()))

            XCTAssertEqual(error as? GenerationError, failure, reason)
            XCTAssertFalse(events.contains { if case .finished = $0 { true } else { false } }, reason)
        }
    }

    func testAnAnswerThatStopsBeforeItsEndIsInterruptedWithWhatItUsedSaid() async throws {
        for ending in [[("message_delta", Self.messageDelta(stop: nil, output: 4)), ("message_stop", Self.messageStop)],
                       []] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
                ("message_start", Self.start()),
                ("content_block_delta", Self.text("Bon")),
            ] + ending)]))

            let (events, error) = await collect(source(request()))

            XCTAssertEqual(error as? GenerationError, .interrupted)
            XCTAssertEqual(events.last, .usage(GenerationUsage(inputTokens: 5, outputTokens: ending.isEmpty ? 1 : 4)),
                           "What was used is kept, as it is paid for")
        }
    }

    func testAConnectionLostPartWayEndsTheAnswerUnexpectedly() async throws {
        StubService.answer(.fail(.networkConnectionLost, afterChunks: [Self.sse([
            ("message_start", Self.start()),
            ("content_block_delta", Self.text("Bon")),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError, .interrupted)
        XCTAssertTrue(events.contains(.delta("Bon")))
    }

    func testTheRequestEndsOnceClaudeSaysItIsDone() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream,
                                    chunks: [Self.whole("Bonjour"), Self.sse([("ping", #"{"type":"ping"}"#)])],
                                    holdsAfterFirst: true))

        let (events, error) = await collect(source(request()))

        XCTAssertNil(error)
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertFalse(StubService.releasedOnItsOwn, "The rest isn't waited for")
        await waitUntil("the request is let go") { StubService.cancellations == 1 }
    }

    func testALineCutWithinACharacterByTheClientArrivesWhole() async throws {
        // The client passes a long line on in parts; this one is cut inside the character after the filler.
        let prefix = "data: " + Self.text("")
        let filler = String(repeating: "a", count: ModelClient.chunkSize - prefix.utf8.count + 1)
        let text = filler + "季度报告"
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("message_start", Self.start()),
            ("content_block_delta", Self.text(text)),
            ("message_delta", Self.messageDelta(stop: "end_turn", output: 2)),
            ("message_stop", Self.messageStop),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertNil(error)
        XCTAssertTrue(events.contains(.delta(text)))
    }

    func testAnErrorInTheStreamSaysWhatWentWrong() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("message_start", Self.start()),
            ("content_block_delta", Self.text("Bon")),
            ("error", Self.error("overloaded_error", "Overloaded")),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError,
                       GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again."))
        XCTAssertEqual(events.last, .usage(GenerationUsage(inputTokens: 5, outputTokens: 1)))
    }

    func testEachErrorTypeInTheStreamIsSaidAsWhatItMeans() async throws {
        let cases: [(String, String?, GenerationError)] = [
            ("authentication_error", "invalid x-api-key",
             GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key.")),
            ("billing_error", "Payment required",
             GenerationError(kind: .noCredit, message: "Your Anthropic account has no remaining credit.")),
            ("permission_error", "Not allowed",
             GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to this model.")),
            ("not_found_error", "model: claude-haiku-5-5",
             GenerationError(kind: .modelUnavailable, message: "Claude Haiku 5.5 is no longer available.")),
            ("request_too_large", "Too large",
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            ("invalid_request_error", "prompt is too long: 1200000 tokens > 1000000 maximum",
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            ("rate_limit_error", "Rate limited",
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            ("overloaded_error", nil,
             GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again.")),
            ("api_error", "Internal server error",
             GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            ("invalid_request_error", "messages: text content blocks must be non-empty",
             GenerationError(kind: .requestRejected, message: "Anthropic turned the request away: "
                             + "messages: text content blocks must be non-empty")),
            ("an_error_not_known_yet", "Something new", GenerationError.interrupted),
        ]
        for (type, message, failure) in cases {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
                ("message_start", Self.start()),
                ("error", Self.error(type, message)),
            ])]))

            let (_, error) = await collect(source(request()))

            XCTAssertEqual(error as? GenerationError, failure, type)
        }
    }

    func testAStatusAloneSaysWhatWentWrongWhenItsBodyIsntClaudes() async throws {
        let cases: [(Int, GenerationError)] = [
            (401, GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key.")),
            (402, GenerationError(kind: .noCredit, message: "Your Anthropic account has no remaining credit.")),
            (403, GenerationError(kind: .requestRejected, message: "Anthropic turned the request away.")),
            (404, GenerationError(kind: .modelUnavailable, message: "Claude Haiku 5.5 is no longer available.")),
            (413, GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            (429, GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            (500, GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            (502, GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            (503, GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            (529, GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again.")),
        ]
        for (status, failure) in cases {
            StubService.reset()
            StubService.answer(.respond(status: status, headers: ["Content-Type": "text/html"],
                                        chunks: [Data("<html><body>\(status)</body></html>".utf8)]))

            let (_, error) = await collect(source(request()))

            XCTAssertEqual(error as? GenerationError, failure, "\(status)")
        }
    }

    func testAnErrorWhoseBodyIsCutOffIsSaidByItsStatus() async throws {
        StubService.answer(.fail(.networkConnectionLost, afterChunks: [Data(#"{"type":"error","error":{"ty"#.utf8)],
                                 status: 401))

        let (_, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError,
                       GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key."))
    }

    func testOnlyTheStartOfALongErrorBodyIsRead() async throws {
        let start = #"{"type":"error","error":{"type":"authentication_error","message":""#
        StubService.answer(.respond(status: 401, headers: ["Content-Type": "application/json"],
                                    chunks: [Data((start + String(repeating: "x", count: 80 * 1024)).utf8),
                                             Data(#""}}"#.utf8)],
                                    holdsAfterFirst: true))

        let (_, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError,
                       GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key."))
        XCTAssertFalse(StubService.releasedOnItsOwn, "The rest isn't waited for")
        await waitUntil("the request is let go") { StubService.cancellations == 1 }
    }

    func testAnEventThatCantBeReadEndsTheAnswerUnexpectedly() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("message_start", Self.start()),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":"#),
        ])]))

        let (_, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError, .interrupted)
    }

    func testEachHTTPErrorIsSaidAsWhatItMeans() async throws {
        let cases: [(Int, [String: String], String, String, ModelRequest.Input, GenerationError)] = [
            (401, [:], "authentication_error", "invalid x-api-key", .text("x"),
             GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key.")),
            (402, [:], "billing_error", "Payment required", .text("x"),
             GenerationError(kind: .noCredit, message: "Your Anthropic account has no remaining credit.")),
            (400, [:], "invalid_request_error",
             "Your credit balance is too low to access the Anthropic API.", .text("x"),
             GenerationError(kind: .noCredit, message: "Your Anthropic account has no remaining credit.")),
            (403, [:], "permission_error", "Not allowed", .text("x"),
             GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to this model.")),
            (403, [:], "forbidden", "Request not allowed", .text("x"),
             GenerationError(kind: .regionUnavailable, message: "Anthropic isn't available in your region.")),
            (403, [:], "verification_required", "Verify your identity in the Console to use this model.", .text("x"),
             GenerationError(kind: .requestRejected, message: "Anthropic turned the request away: "
                             + "Verify your identity in the Console to use this model.")),
            (400, [:], "invalid_request_error",
             "You have reached your specified API usage limits. You will regain access on 2026-12-01 at 00:00 UTC.",
             .text("x"), GenerationError(kind: .noCredit, message: "Your Anthropic account reached its spending limit.")),
            (429, [:], "rate_limit_error", "You have reached your specified workspace API usage limits.", .text("x"),
             GenerationError(kind: .noCredit, message: "Your Anthropic account reached its spending limit.")),
            (529, [:], "overloaded_error", "Overloaded while checking your credit balance", .text("x"),
             GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again.")),
            (500, [:], "api_error", "Internal error while checking usage limits", .text("x"),
             GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            (500, [:], "api_error", "Internal error: the prompt is too long to cache", .text("x"),
             GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            (404, [:], "not_found_error", "model: claude-haiku-5-5", .text("x"),
             GenerationError(kind: .modelUnavailable, message: "Claude Haiku 5.5 is no longer available.")),
            (413, [:], "request_too_large", "Request exceeds the maximum size", .text("x"),
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            (413, [:], "request_too_large", "Request exceeds the maximum size",
             .image(Data([1]), mediaType: "image/png"),
             GenerationError(kind: .inputTooLarge, message: "This image is too large for this model.")),
            (400, [:], "invalid_request_error", "prompt is too long: 1200000 tokens > 1000000 maximum",
             .text("x"), GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            (429, ["retry-after": "20"], "rate_limit_error", "Rate limited", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 20 seconds.",
                             retryAfter: .seconds(20))),
            (429, [:], "rate_limit_error", "Rate limited", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            (429, ["retry-after": "0"], "rate_limit_error", "Rate limited", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            (429, ["retry-after": "1"], "rate_limit_error", "Rate limited", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 1 second.",
                             retryAfter: .seconds(1))),
            (429, ["retry-after": "90"], "rate_limit_error", "Rate limited", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 2 minutes.",
                             retryAfter: .seconds(90))),
            (429, ["retry-after": "3600"], "rate_limit_error", "Rate limited", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 1 hour.",
                             retryAfter: .seconds(3600))),
            (529, [:], "overloaded_error", "Overloaded", .text("x"),
             GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again.")),
            (500, [:], "api_error", "Internal server error", .text("x"),
             GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")),
            (400, [:], "invalid_request_error", "messages: text content blocks must be non-empty", .text("x"),
             GenerationError(kind: .requestRejected, message: "Anthropic turned the request away: "
                             + "messages: text content blocks must be non-empty")),
        ]
        let long = String(repeating: "word ", count: 60)
        let capped = String(long.prefix(200)) + "…"
        let more: [(Int, [String: String], String, String, ModelRequest.Input, GenerationError)] = [
            (400, [:], "invalid_request_error", long, .text("x"),
             GenerationError(kind: .requestRejected, message: "Anthropic turned the request away: " + capped)),
            (400, [:], "invalid_request_error", "First line\\nSecond line", .text("x"),
             GenerationError(kind: .requestRejected, message: "Anthropic turned the request away: First line")),
        ]
        for (status, headers, type, message, input, failure) in cases + more {
            StubService.reset()
            let json = headers.merging(["Content-Type": "application/json"]) { $1 }
            StubService.answer(.respond(status: status, headers: json, chunks: [Data(Self.error(type, message).utf8)]))

            let (events, error) = await collect(source(request(input)))

            XCTAssertEqual(error as? GenerationError, failure, "\(status) \(message)")
            XCTAssertTrue(events.isEmpty, "\(status)")
        }
    }

    func testAHostThatCantBeReachedIsNamed() async throws {
        StubService.answer(.fail(.cannotConnectToHost))

        let (_, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError,
                       GenerationError(kind: .network, message: "Can't reach api.anthropic.com."))
    }

    func testStoppingTheGenerationStopsTheRequest() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream,
                                    chunks: [Self.sse([("message_start", Self.start())]),
                                             Self.sse([("content_block_delta", Self.text("never"))])],
                                    holdsAfterFirst: true, releasesOnItsOwn: false))
        let events = source(request()).events()
        let reading = Task {
            for try await _ in events {}
        }
        await waitUntil("it is sent") { StubService.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))

        // As a person stops the job, which stops reading the source.
        reading.cancel()

        await waitUntil("the request stops") { StubService.cancellations == 1 }
    }

    func testTheKeyIsNeverShownWhenPrinted() {
        var dumped = ""
        dump(key, to: &dumped)

        for shown in [String(describing: key), String(reflecting: key), dumped] {
            XCTAssertFalse(shown.contains("synthetic-anthropic-key"), shown)
        }
    }

    // MARK: Fixtures

    private func request(_ input: ModelRequest.Input = .text("Quarterly plan"),
                         thinking: ModelRequest.Thinking? = .disabled,
                         effort: ModelRequest.Effort? = .low) -> ModelRequest {
        ModelRequest(model: "claude-haiku-5-5", modelName: "Claude Haiku 5.5",
                     instructions: "Translate the user's text into French.", input: input, maxOutputTokens: 16_384,
                     thinking: thinking, effort: effort)
    }

    private func source(_ request: ModelRequest) -> AnthropicMessagesSource {
        AnthropicMessagesSource(client: ModelClient(protocolClasses: [StubService.self]), key: key, request: request)
    }

    private func collect(_ source: AnthropicMessagesSource) async -> (events: [GenerationEvent], error: (any Error)?) {
        var events: [GenerationEvent] = []
        do {
            for try await event in source.events() { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private static func start(input: Int = 5) -> String {
        #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","#
            + #""model":"claude-haiku-5-5","content":[],"stop_reason":null,"#
            + #""usage":{"input_tokens":\#(input),"output_tokens":1}}}"#
    }

    /// The start of a block of `type`, whose text field has the type's name, as Claude's text and thinking blocks do.
    private static func blockStart(_ index: Int, _ type: String) -> String {
        #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"\#(type)","\#(type)":""}}"#
    }

    private static func delta(_ index: Int, _ type: String, _ field: String, _ value: String) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"\#(type)","\#(field)":"\#(value)"}}"#
    }

    private static func text(_ text: String, index: Int = 0) -> String {
        delta(index, "text_delta", "text", text)
    }

    private static func blockStop(_ index: Int) -> String {
        #"{"type":"content_block_stop","index":\#(index)}"#
    }

    private static func messageDelta(stop: String?, output: Int, input: Int? = nil) -> String {
        let reason = stop.map { #""\#($0)""# } ?? "null"
        let tokens = input.map { #""input_tokens":\#($0),"# } ?? ""
        return #"{"type":"message_delta","delta":{"stop_reason":\#(reason),"stop_sequence":null},"#
            + #""usage":{\#(tokens)"output_tokens":\#(output)}}"#
    }

    private static let messageStop = #"{"type":"message_stop"}"#

    private static func error(_ type: String, _ message: String?) -> String {
        let said = message.map { #","message":"\#($0)""# } ?? ""
        return #"{"type":"error","error":{"type":"\#(type)"\#(said)},"request_id":"req_1"}"#
    }

    /// A whole answer of `text` that stops for `stop`.
    private static func whole(_ text: String, stop: String = "end_turn") -> Data {
        sse([
            ("message_start", start()),
            ("content_block_start", blockStart(0, "text")),
            ("content_block_delta", Self.text(text)),
            ("content_block_stop", blockStop(0)),
            ("message_delta", messageDelta(stop: stop, output: 2)),
            ("message_stop", messageStop),
        ])
    }

    private static func sse(_ events: [(String, String)]) -> Data {
        Data(events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
    }

    private static func json(_ body: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
    }
}
