import os
import XCTest
@testable import Keeptide

/// Each provider's list of models, read whole and as the provider describes each model, and tried again when a
/// failure may pass. A stand-in answers in place of the network with synthetic lists; the key is synthetic, and no
/// test waits.
@MainActor
final class ModelListTests: XCTestCase {
    private let key = APIKey("synthetic-key")
    private static let json = ["Content-Type": "application/json"]
    private static let html = ["Content-Type": "text/html"]

    override func setUp() async throws {
        StubService.reset()
    }

    override func tearDown() async throws {
        StubService.reset()
    }

    // MARK: Claude

    func testClaudesModelsAreListedAsClaudeDescribesThem() async throws {
        StubService.answer(.respond(status: 200, headers: Self.json,
                                    chunks: [Self.page([Self.haiku, Self.sonnet, Self.bare("claude-new-model")])]))

        let models = try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait)

        XCTAssertEqual(models, [
            RemoteModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
                        created: Date(timeIntervalSince1970: 1_785_542_400), maxInputTokens: 1_000_000,
                        maxOutputTokens: 128_000, readsImages: true, thinkingTypes: [.adaptive, .disabled],
                        efforts: [.low, .medium, .high, .xhigh, .max], lifecycle: .active),
            RemoteModel(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", readsImages: true,
                        thinkingTypes: [.adaptive, .betweenTools], efforts: [.low, .high], lifecycle: .deprecated,
                        shutDown: Date(timeIntervalSince1970: 1_795_996_800)),
            RemoteModel(id: "claude-new-model"),
        ], "What a model doesn't say stays unknown, and a level given as null isn't supported")
        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.httpMethod, "GET")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertTrue(seen.body?.isEmpty ?? true, "A list is asked for with nothing in the body")
    }

    func testEveryPageIsReadBeforeTheListIsGivenAndAModelListedTwiceIsKeptOnce() async throws {
        StubService.answer([
            .respond(status: 200, headers: Self.json,
                     chunks: [Self.page([Self.bare("claude-a"), Self.bare("claude-b")], more: "claude-b")]),
            .respond(status: 200, headers: Self.json,
                     chunks: [Self.page([Self.bare("claude-b"), Self.bare("claude-c")])]),
        ])

        let models = try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait)

        XCTAssertEqual(models.map(\.id), ["claude-a", "claude-b", "claude-c"])
        XCTAssertEqual(StubService.requests.map { $0.request.url?.absoluteString }, [
            "https://api.anthropic.com/v1/models?limit=1000",
            "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-b",
        ])
    }

    func testAPageThatFailsFailsTheWholeList() async throws {
        StubService.answer([
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-a")], more: "claude-a")]),
            .respond(status: 401, headers: Self.json,
                     chunks: [Data(Self.claudeError("authentication_error", "invalid x-api-key").utf8)]),
        ])

        let error = await failure { try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait) }

        XCTAssertEqual(error, Self.claudeKeyRejected, "A part of the list isn't the list")
    }

    func testAListThatNeverEndsIsRefused() async throws {
        let noLast = Data(#"{"data":[{"type":"model","id":"claude-a"}],"has_more":true,"last_id":null}"#.utf8)
        for (page, requests) in [(Self.page([Self.bare("claude-a")], more: "claude-a"), 2), (noLast, 1)] {
            StubService.reset()
            // More, it says, after the same model again and again, or after none.
            StubService.answer(.respond(status: 200, headers: Self.json, chunks: [page]))

            let error = await failure { try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait) }

            XCTAssertEqual(error, .interrupted)
            XCTAssertEqual(StubService.requests.count, requests, "It stops as soon as the list can't go on")
        }
    }

    func testAListThatComesBackToWhereItWasIsRefused() async throws {
        StubService.answer([
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-a")], more: "claude-a")]),
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-b")], more: "claude-b")]),
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-a")], more: "claude-a")]),
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-b")])]),
        ])

        let error = await failure { try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait) }

        XCTAssertEqual(error, .interrupted)
        XCTAssertEqual(StubService.requests.count, 3)
    }

    func testAListLongerThanAnyCatalogIsRefused() async throws {
        StubService.answer((1...11).map { page in
            .respond(status: 200, headers: Self.json,
                     chunks: [Self.page([Self.bare("claude-\(page)")], more: "claude-\(page)")])
        } + [.respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-last")])])])

        let error = await failure { try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait) }

        XCTAssertEqual(error, .interrupted)
        XCTAssertEqual(StubService.requests.count, 10, "Ten thousand models is more than any provider offers")
    }

    func testOnlyAModelWithoutAnIDIsLeftOutAndWhatCantBeReadOfTheRestIsUnknown() async throws {
        let models = [
            #"{"type":"model","id":7}"#, #"{"type":"model","id":""}"#,
            #"{"type":"model","id":"claude-odd","max_tokens":"many","created_at":1785542400,"#
                + #""capabilities":{"image_input":true}}"#,
            #"{"type":"model","id":"claude-levels","capabilities":{"effort":{"supported":true,"low":true},"#
                + #""thinking":{"types":{"adaptive":{"supported":"yes"}}}}}"#,
            #"{"type":"model","id":"claude-epoch","created_at":"1970-01-01T00:00:00Z","max_input_tokens":0,"#
                + #""max_tokens":0}"#,
        ]
        StubService.answer(.respond(status: 200, headers: Self.json, chunks: [Self.page(models)]))

        let listed = try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait)

        XCTAssertEqual(listed, [RemoteModel(id: "claude-odd"), RemoteModel(id: "claude-levels"),
                                RemoteModel(id: "claude-epoch")])
    }

    func testAListInWhichNoModelCanBeReadIsntAList() async throws {
        StubService.answer(.respond(status: 200, headers: Self.json,
                                    chunks: [Self.page([#"{"type":"model","id":7}"#, #"{"type":"model"}"#])]))

        let error = await failure { try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait) }

        XCTAssertEqual(error, .interrupted, "An empty catalog would take the place of a good one")
    }

    func testEachFailureToListClaudesModelsIsSaidAsWhatItMeans() async throws {
        let cases: [(Int, String?, GenerationError)] = [
            (401, "authentication_error", Self.claudeKeyRejected),
            (403, "permission_error",
             GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to Anthropic's models.")),
            (403, "forbidden",
             GenerationError(kind: .regionUnavailable, message: "Anthropic isn't available in your region.")),
            (404, nil, GenerationError(kind: .requestRejected, message: "Anthropic turned the request away.")),
            (400, "invalid_request_error",
             GenerationError(kind: .requestRejected, message: "Anthropic turned the request away: Not this way")),
        ]
        for (status, type, expected) in cases {
            StubService.reset()
            let body = type.map { Self.claudeError($0, "Not this way") } ?? "<html>\(status)</html>"
            StubService.answer(.respond(status: status, headers: type == nil ? Self.html : Self.json,
                                        chunks: [Data(body.utf8)]))

            let error = await failure { try await AnthropicModels.list(by: client(), key: key, waiting: Self.noWait) }

            XCTAssertEqual(error, expected, "\(status) \(type ?? "")")
        }
    }

    // MARK: Trying again

    func testAFailureThatMayPassIsTriedTwiceMoreAfterAPause() async throws {
        let waits = Waits()
        StubService.answer([
            .respond(status: 529, headers: Self.json, chunks: [Data(Self.claudeError("overloaded_error", "x").utf8)]),
            .respond(status: 500, headers: Self.json, chunks: [Data(Self.claudeError("api_error", "x").utf8)]),
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-a")])]),
        ])

        let models = try await AnthropicModels.list(by: client(), key: key, waiting: { waits.record($0) })

        XCTAssertEqual(models.map(\.id), ["claude-a"])
        XCTAssertEqual(waits.all, [.seconds(1), .seconds(2)])
        XCTAssertEqual(StubService.requests.count, 3)
    }

    func testAFailureThatStaysIsSaidAfterTwoMoreTries() async throws {
        let waits = Waits()
        StubService.answer(.respond(status: 500, headers: Self.json,
                                    chunks: [Data(Self.claudeError("api_error", "Internal").utf8)]))

        let error = await failure {
            try await AnthropicModels.list(by: client(), key: key, waiting: { waits.record($0) })
        }

        XCTAssertEqual(error,
                       GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again."))
        XCTAssertEqual(StubService.requests.count, 3)
        XCTAssertEqual(waits.all, [.seconds(1), .seconds(2)])
    }

    func testAPauseTheProviderAsksForIsKeptAndALongerOneIsSaid() async throws {
        let waits = Waits()
        let limited = Data(Self.claudeError("rate_limit_error", "Rate limited").utf8)
        StubService.answer([
            .respond(status: 429, headers: Self.json.merging(["retry-after": "5"]) { $1 }, chunks: [limited]),
            .respond(status: 429, headers: Self.json.merging(["retry-after": "120"]) { $1 }, chunks: [limited]),
            .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-a")])]),
        ])

        let error = await failure {
            try await AnthropicModels.list(by: client(), key: key, waiting: { waits.record($0) })
        }

        XCTAssertEqual(waits.all, [.seconds(5)])
        XCTAssertEqual(error, GenerationError(kind: .rateLimited, message: "Too many requests. Try again in 2 minutes.",
                                              retryAfter: .seconds(120)), "Not asked for again before it may be")
        XCTAssertEqual(StubService.requests.count, 2)
    }

    func testAHostThatCantBeReachedIsTriedAgainWhenThatMayPass() async throws {
        let cutOff = Data(#"{"data":["#.utf8 + Data("\n".utf8))
        for failing in [StubService.Answer.fail(.cannotConnectToHost),
                        .fail(.networkConnectionLost, afterChunks: [cutOff])] {
            StubService.reset()
            let waits = Waits()
            StubService.answer([
                failing, .respond(status: 200, headers: Self.json, chunks: [Self.page([Self.bare("claude-a")])]),
            ])

            let models = try await AnthropicModels.list(by: client(), key: key, waiting: { waits.record($0) })

            XCTAssertEqual(models.map(\.id), ["claude-a"])
            XCTAssertEqual(waits.all, [.seconds(1)])
        }
    }

    func testAFailureThatWontPassIsntTriedAgain() async throws {
        let credit = "You have reached your specified workspace API usage limits."
        let failing: [(StubService.Answer, GenerationError.Kind)] = [
            (.respond(status: 401, headers: Self.json,
                      chunks: [Data(Self.claudeError("authentication_error", "No").utf8)]), .keyRejected),
            (.respond(status: 403, headers: Self.json,
                      chunks: [Data(Self.claudeError("permission_error", "No").utf8)]), .accessDenied),
            (.respond(status: 400, headers: Self.json,
                      chunks: [Data(Self.claudeError("invalid_request_error", "No").utf8)]), .requestRejected),
            (.respond(status: 429, headers: Self.json,
                      chunks: [Data(Self.claudeError("rate_limit_error", credit).utf8)]), .noCredit),
            (.fail(.notConnectedToInternet), .network),
            (.respond(status: 200, headers: Self.json, chunks: [Data("<html>Not a list</html>".utf8)]),
             .streamInterrupted),
            // A list that would read whole, were it not past the limit.
            (.respond(status: 200, headers: Self.json, chunks: [
                Self.page([Self.bare("claude-a")]) + Data(repeating: 0x20, count: ProviderStream.answerLimit),
            ]), .streamInterrupted),
        ]
        for (answer, kind) in failing {
            StubService.reset()
            let waits = Waits()
            StubService.answer(answer)

            let error = await failure {
                try await AnthropicModels.list(by: client(), key: key, waiting: { waits.record($0) })
            }

            XCTAssertEqual(error?.kind, kind)
            XCTAssertEqual(StubService.requests.count, 1, "\(kind)")
            XCTAssertEqual(waits.all, [], "\(kind)")
        }
    }

    func testStoppingAListIsAStopRatherThanAFailure() async throws {
        let start = Data(#"{"data":["#.utf8 + Data("\n".utf8))
        StubService.answer(.respond(status: 200, headers: Self.json,
                                    chunks: [start, Self.page([Self.bare("claude-a")])],
                                    holdsAfterFirst: true, releasesOnItsOwn: false))
        let client = client()
        let key = key
        let listing = Task { try await AnthropicModels.list(by: client, key: key, waiting: Self.noWait) }
        await waitUntil("the list is asked for") { StubService.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))

        // As Settings closes while it refreshes.
        listing.cancel()

        let result = await listing.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // And while it pauses before trying again.
        StubService.reset()
        StubService.answer(.respond(status: 503, headers: Self.html, chunks: [Data("<html>503</html>".utf8)]))
        let paused = Task {
            try await AnthropicModels.list(by: client, key: key, waiting: { _ in throw CancellationError() })
        }
        let stopped = await paused.result
        XCTAssertThrowsError(try stopped.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(StubService.requests.count, 1)
    }

    // MARK: OpenAI

    func testOpenAIsModelsAreListedWithWhenTheyShutDown() async throws {
        let list = #"{"object":"list","data":["#
            + #"{"id":"gpt-5-mini","object":"model","created":1754438400,"owned_by":"openai","shutdown_date":null},"#
            + #"{"id":"gpt-old","object":"model","created":1686935002,"owned_by":"openai","#
            + #""shutdown_date":"2026-12-01"},{"id":"gpt-bare","object":"model"},{"id":3},"#
            + #"{"id":"gpt-odd","created":"yesterday","shutdown_date":20261201},{"id":"gpt-zero","created":0},"#
            + #"{"id":"gpt-bare","object":"model","created":1}]}"#
        StubService.answer(.respond(status: 200, headers: Self.json, chunks: [Data(list.utf8)]))

        let models = try await OpenAIModels.list(by: client(), key: key, waiting: Self.noWait)

        XCTAssertEqual(models, [
            RemoteModel(id: "gpt-5-mini", created: Date(timeIntervalSince1970: 1_754_438_400)),
            RemoteModel(id: "gpt-old", created: Date(timeIntervalSince1970: 1_686_935_002),
                        shutDown: Date(timeIntervalSince1970: 1_796_083_200)),
            RemoteModel(id: "gpt-bare"),
            RemoteModel(id: "gpt-odd"),
            RemoteModel(id: "gpt-zero"),
        ], "A model listed again is kept where it was first")
        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.httpMethod, "GET")
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "authorization"), "Bearer synthetic-key")
    }

    func testAnOpenAIListThatGoesOnOrHasNothingReadableIsntAList() async throws {
        for list in [#"{"object":"list","data":[{"id":"gpt-a","object":"model"}],"has_more":true}"#,
                     #"{"object":"list","data":[{"id":3},{"object":"model"}]}"#] {
            StubService.reset()
            StubService.answer(.respond(status: 200, headers: Self.json, chunks: [Data(list.utf8)]))

            let error = await failure { try await OpenAIModels.list(by: client(), key: key, waiting: Self.noWait) }

            XCTAssertEqual(error, .interrupted, list)
        }
    }

    func testEachFailureToListOpenAIsModelsIsSaidAsWhatItMeans() async throws {
        let cases: [(Int, String?, String, GenerationError)] = [
            (401, "invalid_api_key", "Incorrect API key provided",
             GenerationError(kind: .keyRejected, message: "OpenAI didn't accept your API key.")),
            (403, "unsupported_country_region_territory", "Country, region, or territory not supported",
             GenerationError(kind: .regionUnavailable, message: "OpenAI isn't available in your region.")),
            (403, nil, "Not allowed",
             GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to OpenAI's models.")),
            (403, nil, "Your organization must be verified to use the models.",
             GenerationError(kind: .verificationRequired,
                             message: "OpenAI needs to verify your organization before you can use its models.")),
            (429, "insufficient_quota", "You exceeded your current quota",
             GenerationError(kind: .noCredit, message: "Your OpenAI account has no remaining credit.")),
            (404, nil, "",
             GenerationError(kind: .requestRejected, message: "OpenAI turned the request away.")),
        ]
        for (status, code, message, expected) in cases {
            StubService.reset()
            let waits = Waits()
            let body = message.isEmpty ? "<html>\(status)</html>" : Self.openAIError(code, message)
            StubService.answer(.respond(status: status, headers: message.isEmpty ? Self.html : Self.json,
                                        chunks: [Data(body.utf8)]))

            let error = await failure {
                try await OpenAIModels.list(by: client(), key: key, waiting: { waits.record($0) })
            }

            XCTAssertEqual(error, expected, "\(status) \(code ?? message)")
            XCTAssertEqual(waits.all, [], "Not tried again: \(status) \(code ?? message)")
        }
    }

    // MARK: Fixtures

    private static let noWait: @Sendable (Duration) async throws -> Void = { _ in }

    private static let claudeKeyRejected = GenerationError(kind: .keyRejected,
                                                           message: "Anthropic didn't accept your API key.")

    /// Claude Haiku 5.5 as the Models API lists it, with a synthetic date.
    private static let haiku = #"{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","#
        + #""created_at":"2026-08-01T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,"#
        + #""lifecycle":"active","retires_at":null,"capabilities":{"#
        + #""image_input":{"supported":true},"structured_outputs":{"supported":true},"#
        + #""thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true},"#
        + #""disabled":{"supported":true}}},"effort":{"supported":true,"low":{"supported":true},"#
        + #""medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"#
        + #""max":{"supported":true}}}}"#

    /// A Sonnet-shaped model on its way out, which turns thinking off between tools; synthetic.
    private static let sonnet = #"{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","#
        + #""lifecycle":"deprecated","retires_at":"2026-11-30T00:00:00Z","capabilities":{"#
        + #""image_input":{"supported":true},"thinking":{"supported":true,"types":{"adaptive":{"supported":true},"#
        + #""between_tools":{"supported":true},"disabled":{"supported":false}}},"#
        + #""effort":{"supported":true,"low":{"supported":true},"high":{"supported":true},"xhigh":null}}}"#

    private func client() -> ModelClient {
        ModelClient(protocolClasses: [StubService.self])
    }

    private func failure(_ list: () async throws -> [RemoteModel]) async -> GenerationError? {
        do {
            let models = try await list()
            XCTFail("Listed \(models.map(\.id)) instead of failing")
            return nil
        } catch {
            return error as? GenerationError
        }
    }

    private static func bare(_ id: String) -> String {
        #"{"type":"model","id":"\#(id)"}"#
    }

    /// A page of Claude's list, with more after the model `more` names.
    private static func page(_ models: [String], more: String? = nil) -> Data {
        let last = more.map { #""\#($0)""# } ?? "null"
        return Data((#"{"data":[\#(models.joined(separator: ","))],"has_more":\#(more != nil),"#
            + #""first_id":null,"last_id":\#(last)}"#).utf8)
    }

    private static func claudeError(_ type: String, _ message: String) -> String {
        #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_1"}"#
    }

    private static func openAIError(_ code: String?, _ message: String) -> String {
        let code = code.map { #""\#($0)""# } ?? "null"
        return #"{"error":{"message":"\#(message)","type":"invalid_request_error","param":null,"code":\#(code)}}"#
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
