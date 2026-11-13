import XCTest
@testable import Keeptide

/// OpenAI's Responses API, streamed: what Keeptide sends, and how what comes back becomes a generation's events. A
/// stand-in answers in place of the network with synthetic events; the key and content are synthetic.
@MainActor
final class OpenAIResponsesTests: XCTestCase {
    private let key = APIKey("synthetic-openai-key")
    private static let stream = ["Content-Type": "text/event-stream"]

    override func setUp() async throws {
        StubService.reset()
    }

    override func tearDown() async throws {
        StubService.reset()
    }

    func testATextIsSentAsOpenAIExpectsIt() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("Bonjour")]))

        _ = await collect(source(request()))

        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "authorization"), "Bearer synthetic-openai-key")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = try Self.json(seen.body)
        XCTAssertEqual(body["model"] as? String, "gpt-5-mini")
        XCTAssertEqual(body["instructions"] as? String, "Translate the user's text into French.")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 16_384)
        XCTAssertEqual(body["store"] as? Bool, false, "OpenAI doesn't keep the response")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1, "The content in a message of its own")
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "Quarterly plan")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "max_output_tokens", "store", "stream",
                                        "reasoning"], "Nothing else, such as sampling, tools, metadata or a user")
    }

    func testAnImageIsSentAsADataURLOfItsOwn() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("Total")]))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        _ = await collect(source(request(.image(png, mediaType: "image/png"))))

        let body = try Self.json(StubService.requests.first?.body)
        let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        let image = try XCTUnwrap(content.first)
        XCTAssertEqual(image["type"] as? String, "input_image")
        XCTAssertEqual(image["image_url"] as? String, "data:image/png;base64," + png.base64EncodedString())
        XCTAssertEqual(Set(image.keys), ["type", "image_url"], "The detail is left to the model")
        let sent = try XCTUnwrap(StubService.requests.first?.body)
        XCTAssertFalse(String(decoding: sent, as: UTF8.self).contains(#"\/"#), "An escaped slash only adds bytes")
    }

    func testReasoningIsSentOnlyAsGiven() async throws {
        for (effort, sent) in [(nil, nil), (.noReasoning, "none"), (.minimal, "minimal"), (.low, "low")]
            as [(ModelRequest.Effort?, String?)] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("x")]))

            _ = await collect(source(request(effort: effort)))

            let body = try Self.json(StubService.requests.first?.body)
            XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, sent)
            if effort == nil { XCTAssertNil(body["reasoning"]) }
        }
    }

    func testAStreamedAnswerBecomesTheGenerationsEvents() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("response.created", Self.created()),
            ("response.in_progress", #"{"type":"response.in_progress","sequence_number":1}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":2}"#),
            ("response.reasoning_summary_text.delta",
             #"{"type":"response.reasoning_summary_text.delta","sequence_number":3,"delta":"Hidden"}"#),
            ("response.output_text.delta", Self.text("Bon")),
            ("response.output_text.delta", Self.text("")),
            ("response.output_text.delta", Self.text("jour")),
            ("response.output_text.done", #"{"type":"response.output_text.done","text":"Bonjour"}"#),
            ("response.completed", Self.completed(input: 21, output: 3)),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertNil(error)
        guard case .started(let info)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(info.engine, "GPT-5 mini")
        XCTAssertEqual(info.model, "gpt-5-mini")
        XCTAssertEqual(Array(events.dropFirst()), [
            .delta("Bon"), .delta("jour"), .usage(GenerationUsage(inputTokens: 21, outputTokens: 3)),
            .finished(.completed),
        ], "Reasoning stays hidden")
    }

    func testAnEventIsKnownByTheTypeInItsDataWhateverItsEventLineSays() async throws {
        let stream = "data: \(Self.created())\n\n"
            + "event: response.in_progress\ndata: \(Self.text("Bon"))\n\n"
            + "event: response.output_text.delta\ndata: \(Self.completed(input: 2, output: 1))\n\n"
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Data(stream.utf8)]))

        let (read, error) = await collect(source(request()))

        XCTAssertNil(error)
        XCTAssertEqual(Array(read.dropFirst()), [
            .delta("Bon"), .usage(GenerationUsage(inputTokens: 2, outputTokens: 1)), .finished(.completed),
        ])
    }

    func testAResponseThatSaysNothingOfWhatItUsedEndsWithoutUsage() async throws {
        let completed = #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":null}}"#
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("response.created", Self.created()),
            ("response.output_text.delta", Self.text("Bon")),
            ("response.completed", completed),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertNil(error)
        XCTAssertEqual(Array(events.dropFirst()), [.delta("Bon"), .finished(.completed)])
    }

    func testEachWayAResponseEndsFinishesTheGenerationAsItShould() async throws {
        for (ending, reason) in [(Self.completed(input: 5, output: 2), FinishReason.completed),
                                 (Self.incomplete("max_output_tokens"), .truncated),
                                 (Self.incomplete("content_filter"), .refused)] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
                ("response.created", Self.created()),
                ("response.output_text.delta", Self.text("x")),
                (Self.type(of: ending), ending),
            ])]))

            let (events, error) = await collect(source(request()))

            XCTAssertNil(error, "\(reason)")
            XCTAssertEqual(Array(events.suffix(2)), [.usage(GenerationUsage(inputTokens: 5, outputTokens: 2)),
                                                     .finished(reason)], "\(reason)")
        }
    }

    func testARefusalEndsAsDeclinedAndIsntShown() async throws {
        let delta = #"{"type":"response.refusal.delta","sequence_number":4,"delta":"I can't help with that."}"#
        let done = #"{"type":"response.refusal.done","refusal":"I can't help with that."}"#
        for refusal in [[("response.refusal.delta", delta), ("response.refusal.done", done)],
                        [("response.refusal.done", done)]] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse(
                [("response.created", Self.created())] + refusal
                    + [("response.completed", Self.completed(input: 5, output: 7))]
            )]))

            let (events, error) = await collect(source(request()))

            XCTAssertNil(error)
            XCTAssertFalse(events.contains { $0.carriesText }, "\(events)")
            XCTAssertEqual(events.last, .finished(.refused), "\(refusal.map(\.0))")
        }
    }

    func testARequestOpenAIsPoliciesBlockEndsAsDeclined() async throws {
        let used = GenerationEvent.usage(GenerationUsage(inputTokens: 5, outputTokens: 2))
        for code in ["bio_policy", "image_content_policy_violation", "misalignment_policy_violation"] {
            let flat = #"{"type":"error","code":"\#(code)","message":"Blocked"}"#
            let nested = #"{"type":"error","error":{"type":"invalid_request_error","code":"\#(code)","message":"B"}}"#
            let streamed: [(String, (String, String), [GenerationEvent])] = [
                ("failed", ("response.failed", Self.failed(code, "Blocked")), [used, .finished(.refused)]),
                ("flat error", ("error", flat), [.finished(.refused)]),
                ("nested error", ("error", nested), [.finished(.refused)]),
            ]
            for (name, ending, last) in streamed {
                StubService.reset()
                StubService.answer(.respond(status: 200, headers: Self.stream,
                                            chunks: [Self.sse([("response.created", Self.created()), ending])]))

                let (events, error) = await collect(source(request()))

                XCTAssertNil(error, "\(code) \(name)")
                XCTAssertEqual(Array(events.dropFirst()), last, "\(code) \(name)")
            }
            for status in [400, 403] {
                StubService.reset()
                StubService.answer(.respond(status: status, headers: ["Content-Type": "application/json"],
                                            chunks: [Data(Self.httpError("invalid_request_error", code, "B").utf8)]))

                let (events, error) = await collect(source(request()))

                XCTAssertNil(error, "\(code) \(status)")
                guard case .started(let info)? = events.first else {
                    XCTFail("\(code) \(status): \(events)")
                    continue
                }
                XCTAssertEqual(info.engine, "GPT-5 mini", "Who declined")
                XCTAssertEqual(Array(events.dropFirst()), [.finished(.refused)], "\(code) \(status)")
            }
        }
    }

    func testAResponseThatStopsForAnotherReasonIsInterruptedWithWhatItUsedSaid() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("response.created", Self.created()),
            ("response.output_text.delta", Self.text("Bon")),
            ("response.incomplete", Self.incomplete("max_messages")),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError, .interrupted)
        XCTAssertEqual(events.last, .usage(GenerationUsage(inputTokens: 5, outputTokens: 2)),
                       "What was used is kept, as it is paid for")
    }

    func testAnAnswerThatStopsBeforeItsEndIsInterrupted() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("response.created", Self.created()),
            ("response.output_text.delta", Self.text("Bon")),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError, .interrupted)
        XCTAssertEqual(events.last, .delta("Bon"), "OpenAI says what was used only at the end")
    }

    func testAConnectionLostPartWayEndsTheAnswerUnexpectedly() async throws {
        StubService.answer(.fail(.networkConnectionLost, afterChunks: [Self.sse([
            ("response.created", Self.created()),
            ("response.output_text.delta", Self.text("Bon")),
        ])]))

        let (events, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError, .interrupted)
        XCTAssertTrue(events.contains(.delta("Bon")))
    }

    func testTheRequestEndsOnceTheResponseHasEnded() async throws {
        let later = Self.sse([("keepalive", #"{"type":"keepalive"}"#)])
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.whole("Bonjour"), later],
                                    holdsAfterFirst: true))

        let (events, error) = await collect(source(request()))

        XCTAssertNil(error)
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertFalse(StubService.releasedOnItsOwn, "The rest isn't waited for")
        await waitUntil("the request is let go") { StubService.cancellations == 1 }
    }

    func testAFailedResponseSaysWhatWentWrongWithWhatItUsed() async throws {
        let cases: [(String, String, GenerationError)] = [
            ("server_error", "The server had an error",
             GenerationError(kind: .overloaded, message: "OpenAI couldn't answer just now. Try again.")),
            ("rate_limit_exceeded", "Rate limit reached",
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            ("image_too_large", "Image too large",
             GenerationError(kind: .inputTooLarge, message: "This image is too large for this model.")),
            ("invalid_prompt", "Invalid prompt: the input could not be read",
             GenerationError(kind: .requestRejected,
                             message: "OpenAI turned the request away: Invalid prompt: the input could not be read")),
            ("invalid_base64_image", "Invalid base64 image",
             GenerationError(kind: .requestRejected, message: "OpenAI turned the request away: Invalid base64 image")),
            ("a_failure_not_known_yet", "Something new", GenerationError.interrupted),
        ]
        for (code, message, failure) in cases {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
                ("response.created", Self.created()),
                ("response.output_text.delta", Self.text("Bon")),
                ("response.failed", Self.failed(code, message)),
            ])]))

            let (events, error) = await collect(source(request(.image(Data([1]), mediaType: "image/png"))))

            XCTAssertEqual(error as? GenerationError, failure, code)
            XCTAssertEqual(events.last, .usage(GenerationUsage(inputTokens: 5, outputTokens: 2)), code)
        }
    }

    func testAnErrorEventSaysWhatWentWrongWhetherItsFieldsAreNestedOrNot() async throws {
        let cases: [(String, String, GenerationError)] = [
            ("server_error", "Server error",
             GenerationError(kind: .overloaded, message: "OpenAI couldn't answer just now. Try again.")),
            ("insufficient_quota", "You exceeded your current quota",
             GenerationError(kind: .noCredit, message: "Your OpenAI account has no remaining credit.")),
            ("rate_limit_exceeded", "Rate limit reached",
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            ("context_length_exceeded", "Your input exceeds the context window of this model.",
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            ("invalid_prompt", "Invalid prompt",
             GenerationError(kind: .requestRejected, message: "OpenAI turned the request away: Invalid prompt")),
            ("unsupported_value", "Your organization must be verified to stream this model.",
             GenerationError(kind: .verificationRequired,
                             message: "OpenAI needs to verify your organization before you can use this model.")),
            ("an_error_not_known_yet", "Something new", GenerationError.interrupted),
        ]
        for (code, message, failure) in cases {
            let flat = #"{"type":"error","code":"\#(code)","message":"\#(message)","param":null}"#
            let nested = #"{"type":"error","error":{"type":"error","code":"\#(code)","message":"\#(message)"}}"#
            for event in [flat, nested] {
                StubService.reset()
                StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
                    ("response.created", Self.created()),
                    ("error", event),
                ])]))

                let (_, error) = await collect(source(request()))

                XCTAssertEqual(error as? GenerationError, failure, event)
            }
        }
    }

    func testAnEventThatCantBeReadEndsTheAnswerUnexpectedly() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [Self.sse([
            ("response.created", Self.created()),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"#),
        ])]))

        let (_, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError, .interrupted)
    }

    func testEachHTTPErrorIsSaidAsWhatItMeans() async throws {
        let image = ModelRequest.Input.image(Data([1]), mediaType: "image/png")
        let noCredit = GenerationError(kind: .noCredit, message: "Your OpenAI account has no remaining credit.")
        let spendingLimit = GenerationError(kind: .noCredit, message: "Your OpenAI account reached its spending limit.")
        let verify = GenerationError(kind: .verificationRequired,
                                     message: "OpenAI needs to verify your organization before you can use this model.")
        let tooLargeAMinute = "Request too large for gpt-5-mini in organization org-synthetic on tokens per min (TPM): "
            + "Limit 30000, Requested 45000. The input or output tokens must be reduced in order to run successfully."
        let cases: [(Int, [String: String], String?, String?, String, ModelRequest.Input, GenerationError)] = [
            (401, [:], "invalid_request_error", "invalid_api_key", "Incorrect API key provided", .text("x"),
             GenerationError(kind: .keyRejected, message: "OpenAI didn't accept your API key.")),
            (403, [:], "invalid_request_error", "unsupported_country_region_territory",
             "Country, region, or territory not supported", .text("x"),
             GenerationError(kind: .regionUnavailable, message: "OpenAI isn't available in your region.")),
            (403, [:], "invalid_request_error", nil, "You are not allowed to sample from this model", .text("x"),
             GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to this model.")),
            (429, [:], "insufficient_quota", "insufficient_quota", "You exceeded your current quota", .text("x"),
             noCredit),
            (429, [:], "invalid_request_error", "credit_balance_exhausted", "No prepaid credits remain", .text("x"),
             noCredit),
            (429, [:], "invalid_request_error", "organization_spend_limit_exceeded", "Spend limit reached",
             .text("x"), spendingLimit),
            (429, [:], "invalid_request_error", "project_spend_limit_exceeded", "Spend limit reached",
             .text("x"), GenerationError(kind: .noCredit, message: "Your OpenAI project reached its spending limit.")),
            (429, [:], "invalid_request_error", "organization_usage_limit_exceeded", "Usage limit reached",
             .text("x"), GenerationError(kind: .noCredit, message: "Your OpenAI account reached its usage limit.")),
            (429, ["retry-after": "20"], "requests", "rate_limit_exceeded", "Rate limit reached", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 20 seconds.",
                             retryAfter: .seconds(20))),
            (429, ["retry-after": "90"], "rate_limit_error", "slow_down", "Slow down", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 2 minutes.",
                             retryAfter: .seconds(90))),
            (429, [:], "requests", "rate_limit_exceeded", "Rate limit reached", .text("x"),
             GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            (429, ["retry-after": "20"], "tokens", "rate_limit_exceeded", tooLargeAMinute, .text("x"),
             GenerationError(kind: .inputTooLarge,
                             message: "This text is too long for your OpenAI account's per-minute limit.")),
            (429, [:], "tokens", "rate_limit_exceeded", tooLargeAMinute, image,
             GenerationError(kind: .inputTooLarge,
                             message: "This image is too large for your OpenAI account's per-minute limit.")),
            (404, [:], "invalid_request_error", "model_not_found",
             "The model `gpt-5-mini` does not exist or you do not have access to it.", .text("x"),
             GenerationError(kind: .modelUnavailable, message: "GPT-5 mini isn't available with your API key.")),
            (400, [:], "invalid_request_error", "context_length_exceeded",
             "Your input exceeds the context window of this model.", .text("x"),
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            (400, [:], "invalid_request_error", "string_above_max_length",
             "Invalid 'input[0].content[0].text': string too long.", .text("x"),
             GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            (400, [:], "invalid_request_error", "image_file_too_large", "Image too large", image,
             GenerationError(kind: .inputTooLarge, message: "This image is too large for this model.")),
            (400, [:], "invalid_request_error", "unsupported_value",
             "Your organization must be verified to stream this model.", .text("x"), verify),
            (403, [:], "invalid_request_error", nil,
             "Your organization must be verified to use the model `gpt-5-mini`.", .text("x"), verify),
            (500, [:], "server_error", nil, "The server had an error while processing your request.", .text("x"),
             GenerationError(kind: .overloaded, message: "OpenAI couldn't answer just now. Try again.")),
            (503, ["retry-after": "5"], "service_unavailable_error", "server_is_overloaded", "Overloaded", .text("x"),
             GenerationError(kind: .overloaded, message: "OpenAI is busy right now. Try again.")),
            (400, [:], "invalid_request_error", "invalid_value", "Invalid value for 'input'.", .text("x"),
             GenerationError(kind: .requestRejected,
                             message: "OpenAI turned the request away: Invalid value for 'input'.")),
        ]
        for (status, headers, type, code, message, input, failure) in cases {
            StubService.reset()
            let json = headers.merging(["Content-Type": "application/json"]) { $1 }
            StubService.answer(.respond(status: status, headers: json,
                                        chunks: [Data(Self.httpError(type, code, message).utf8)]))

            let (events, error) = await collect(source(request(input)))

            XCTAssertEqual(error as? GenerationError, failure, "\(status) \(code ?? message)")
            XCTAssertTrue(events.isEmpty, "\(status)")
        }
    }

    func testAStatusAloneSaysWhatWentWrongWhenItsBodyIsntOpenAIs() async throws {
        let cases: [(Int, GenerationError)] = [
            (401, GenerationError(kind: .keyRejected, message: "OpenAI didn't accept your API key.")),
            (403, GenerationError(kind: .requestRejected, message: "OpenAI turned the request away.")),
            (404, GenerationError(kind: .modelUnavailable, message: "GPT-5 mini isn't available with your API key.")),
            (413, GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")),
            (429, GenerationError(kind: .rateLimited, message: "Too many requests. Try again shortly.")),
            (500, GenerationError(kind: .overloaded, message: "OpenAI couldn't answer just now. Try again.")),
            (502, GenerationError(kind: .overloaded, message: "OpenAI couldn't answer just now. Try again.")),
            (503, GenerationError(kind: .overloaded, message: "OpenAI is busy right now. Try again.")),
            (400, GenerationError(kind: .requestRejected, message: "OpenAI turned the request away.")),
        ]
        for (status, failure) in cases {
            StubService.reset()
            StubService.answer(.respond(status: status, headers: ["Content-Type": "text/html"],
                                        chunks: [Data("<html><body>\(status)</body></html>".utf8)]))

            let (_, error) = await collect(source(request()))

            XCTAssertEqual(error as? GenerationError, failure, "\(status)")
        }
    }

    func testAHostThatCantBeReachedIsNamed() async throws {
        StubService.answer(.fail(.cannotConnectToHost))

        let (_, error) = await collect(source(request()))

        XCTAssertEqual(error as? GenerationError,
                       GenerationError(kind: .network, message: "Can't reach api.openai.com."))
    }

    func testStoppingTheGenerationStopsTheRequest() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream,
                                    chunks: [Self.sse([("response.created", Self.created())]),
                                             Self.sse([("response.output_text.delta", Self.text("never"))])],
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

    // MARK: Fixtures

    private func request(_ input: ModelRequest.Input = .text("Quarterly plan"),
                         effort: ModelRequest.Effort? = .noReasoning) -> ModelRequest {
        ModelRequest(model: "gpt-5-mini", modelName: "GPT-5 mini",
                     instructions: "Translate the user's text into French.", input: input, maxOutputTokens: 16_384,
                     thinking: nil, effort: effort)
    }

    private func source(_ request: ModelRequest) -> OpenAIResponsesSource {
        OpenAIResponsesSource(client: ModelClient(protocolClasses: [StubService.self]), key: key, request: request)
    }

    private func collect(_ source: OpenAIResponsesSource) async -> (events: [GenerationEvent], error: (any Error)?) {
        var events: [GenerationEvent] = []
        do {
            for try await event in source.events() { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private static func created() -> String {
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","object":"response","#
            + #""status":"in_progress","model":"gpt-5-mini","output":[],"usage":null}}"#
    }

    private static func text(_ text: String) -> String {
        #"{"type":"response.output_text.delta","sequence_number":5,"item_id":"msg_1","output_index":0,"#
            + #""content_index":0,"delta":"\#(text)"}"#
    }

    /// A response's last event, of `type`, with the response's `status`, what it used, and `extra` fields.
    private static func ended(_ type: String, _ status: String, input: Int, output: Int,
                              extra: String = "") -> String {
        #"{"type":"\#(type)","sequence_number":9,"response":{"id":"resp_1","status":"\#(status)",\#(extra)"#
            + #""usage":{"input_tokens":\#(input),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}"#
    }

    private static func completed(input: Int, output: Int) -> String {
        ended("response.completed", "completed", input: input, output: output)
    }

    private static func incomplete(_ reason: String) -> String {
        ended("response.incomplete", "incomplete", input: 5, output: 2,
              extra: #""incomplete_details":{"reason":"\#(reason)"},"#)
    }

    private static func failed(_ code: String, _ message: String) -> String {
        ended("response.failed", "failed", input: 5, output: 2,
              extra: #""error":{"code":"\#(code)","message":"\#(message)"},"#)
    }

    private static func type(of event: String) -> String {
        let data = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any]
        return data?["type"] as? String ?? "message"
    }

    private static func httpError(_ type: String?, _ code: String?, _ message: String) -> String {
        let type = type.map { #""\#($0)""# } ?? "null"
        let code = code.map { #""\#($0)""# } ?? "null"
        return #"{"error":{"message":"\#(message)","type":\#(type),"param":null,"code":\#(code)}}"#
    }

    /// A whole answer of `text` that ends completed.
    private static func whole(_ text: String) -> Data {
        sse([
            ("response.created", created()),
            ("response.output_text.delta", Self.text(text)),
            ("response.completed", completed(input: 5, output: 2)),
        ])
    }

    private static func sse(_ events: [(String, String)]) -> Data {
        Data(events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
    }

    private static func json(_ body: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
    }
}
