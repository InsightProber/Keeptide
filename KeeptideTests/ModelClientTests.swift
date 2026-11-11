import XCTest
@testable import Keeptide

/// `ModelClient`, the one way Keeptide reaches a model service. A stand-in answers every request in place of the
/// network, so nothing here leaves this Mac; the content and the key are synthetic.
@MainActor
final class ModelClientTests: XCTestCase {
    private let messages = URL(string: "https://api.anthropic.com/v1/messages")!
    private let models = URL(string: "https://api.openai.com/v1/models")!
    /// As a streamed answer says it is. Without a type, the system holds back the first 512 bytes of a body to tell it.
    private static let stream = ["Content-Type": "text/event-stream"]

    override func setUp() async throws {
        StubService.reset()
    }

    override func tearDown() async throws {
        StubService.reset()
    }

    func testARequestToAProvidersAPIArrivesAsMadeAndItsAnswerComesBackALineAtATime() async throws {
        StubService.answer(.respond(status: 200, headers: ["Content-Type": "text/event-stream",
                                                           "Request-Id": "req_synthetic"],
                                    chunks: [Data("event: one\n".utf8), Data("data: {}\n\ntail".utf8)]))
        let client = ModelClient(protocolClasses: [StubService.self])

        let response = try await client.send(CloudRequest(method: .post, url: messages,
                                                          headers: ["x-api-key": "synthetic-key"],
                                                          body: Data(#"{"synthetic":true}"#.utf8)))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["request-id"], "req_synthetic", "By its name in lower case")
        let chunks = try await Self.read(response.body)
        XCTAssertEqual(chunks, ["event: one\n", "data: {}\n", "\n", "tail"])
        XCTAssertEqual(StubService.requests.count, 1)
        let seen = try XCTUnwrap(StubService.requests.first)
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.url, messages)
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
        XCTAssertEqual(seen.body, Data(#"{"synthetic":true}"#.utf8))
    }

    func testEachLineComesBackAsItEndsNotOnceTheAnswerIsWhole() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream,
                                    chunks: [Data("first\n".utf8), Data("second\n".utf8)], holdsAfterFirst: true))
        let client = ModelClient(protocolClasses: [StubService.self])
        let response = try await client.send(CloudRequest(method: .get, url: models))
        var body = response.body.makeAsyncIterator()

        let first = try await body.nextText()

        XCTAssertEqual(first, "first\n")
        XCTAssertFalse(StubService.releasedOnItsOwn, "It came before the rest was sent")
        StubService.releaseRest()
        let second = try await body.nextText()
        XCTAssertEqual(second, "second\n")
        let end = try await body.nextText()
        XCTAssertNil(end)
    }

    func testALongLineComesBackInParts() async throws {
        let line = Data(repeating: UInt8(ascii: "a"), count: ModelClient.chunkSize * 2 + 10)
        StubService.answer(.respond(status: 200, headers: Self.stream, chunks: [line]))
        let client = ModelClient(protocolClasses: [StubService.self])
        let response = try await client.send(CloudRequest(method: .get, url: models))

        let chunks = try await Self.read(response.body)

        XCTAssertEqual(chunks.map(\.count), [ModelClient.chunkSize, ModelClient.chunkSize, 10])
    }

    func testNothingIsSentToAnAddressThatIsntAProvidersAPIOverHTTPS() async throws {
        let client = ModelClient(protocolClasses: [StubService.self])
        for address in ["https://example.com/v1/messages", "https://api.anthropic.com.example.net/v1/messages",
                        "https://evil-api.openai.com/v1/models", "http://api.anthropic.com/v1/messages",
                        "https://synthetic:secret@api.openai.com/v1/models", "https://synthetic@api.openai.com/v1/models",
                        "https://api.openai.com:8443/v1/models",
                        "wss://api.openai.com/v1/realtime"] {
            do {
                _ = try await client.send(CloudRequest(method: .get, url: try XCTUnwrap(URL(string: address))))
                XCTFail("\(address) was sent")
            } catch {
                XCTAssertEqual(error as? CloudError, .notAllowed, address)
            }
        }
        XCTAssertTrue(StubService.requests.isEmpty, "Nothing reached the network")
    }

    func testAProvidersHostIsFoundWhateverItsCaseAndWithHTTPSsPortSpelledOut() async throws {
        StubService.answer(.respond(status: 200, headers: [:], chunks: []))
        let client = ModelClient(protocolClasses: [StubService.self])

        for address in ["https://API.Anthropic.COM/v1/models", "https://api.openai.com:443/v1/models"] {
            let response = try await client.send(CloudRequest(method: .get, url: try XCTUnwrap(URL(string: address))))
            XCTAssertEqual(response.status, 200, address)
        }

        XCTAssertEqual(StubService.requests.count, 2)
    }

    func testHostsGivenTakeThePlaceOfTheProviders() async throws {
        StubService.answer(.respond(status: 204, headers: [:], chunks: []))
        let client = ModelClient(hosts: ["models.example"], protocolClasses: [StubService.self])

        let given = try await client.send(CloudRequest(method: .get, url: URL(string: "https://models.example/v1")!))

        XCTAssertEqual(given.status, 204)
        do {
            _ = try await client.send(CloudRequest(method: .get, url: models))
            XCTFail("A provider's host was used")
        } catch {
            XCTAssertEqual(error as? CloudError, .notAllowed)
        }
    }

    func testARedirectIsTheAnswerAndIsntFollowed() async throws {
        StubService.answer(.redirect(to: URL(string: "https://elsewhere.example/v1/models")!, status: 307))
        let client = ModelClient(protocolClasses: [StubService.self])

        let response = try await client.send(CloudRequest(method: .get, url: models,
                                                          headers: ["Authorization": "Bearer synthetic-key"]))

        XCTAssertEqual(response.status, 307)
        XCTAssertEqual(response.headers["location"], "https://elsewhere.example/v1/models")
        XCTAssertEqual(StubService.requests.map { $0.request.url?.host() }, ["api.openai.com"],
                       "The key went nowhere else")
    }

    func testCancellingARequestBeforeItIsAnsweredStopsIt() async throws {
        StubService.answer(.hang)
        let client = ModelClient(protocolClasses: [StubService.self])
        let sending = Task { try await client.send(CloudRequest(method: .get, url: models)) }
        await waitUntil("it is sent") { StubService.requests.count == 1 }

        sending.cancel()

        await waitUntil("it stops") { StubService.cancellations == 1 }
        let result = await sending.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    func testStoppingReadingAnAnswerStopsTheRequest() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream,
                                    chunks: [Data("first\n".utf8), Data("never\n".utf8)], holdsAfterFirst: true,
                                    releasesOnItsOwn: false))
        let client = ModelClient(protocolClasses: [StubService.self])
        let response = try await client.send(CloudRequest(method: .get, url: models))
        var body = response.body.makeAsyncIterator()
        let first = try await body.nextText()
        XCTAssertEqual(first, "first\n")
        let waiting = Task { [body] in
            var body = body
            return try await body.nextText()
        }
        try await Task.sleep(for: .milliseconds(50))

        waiting.cancel()

        await waitUntil("it stops") { StubService.cancellations == 1 }
        // Waiting for more ends with nothing more, or as cancelled.
        switch await waiting.result {
        case .success(let more): XCTAssertNil(more)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testAnAnswerStillComingInIsReadToTheEndAfterTheClientIsLetGo() async throws {
        StubService.answer(.respond(status: 200, headers: Self.stream,
                                    chunks: [Data("first\n".utf8), Data("second\n".utf8)], holdsAfterFirst: true))
        var client: ModelClient? = ModelClient(protocolClasses: [StubService.self])
        let response = try await XCTUnwrap(client).send(CloudRequest(method: .get, url: models))

        client = nil
        StubService.releaseRest()

        let chunks = try await Self.read(response.body)
        XCTAssertEqual(chunks, ["first\n", "second\n"])
        XCTAssertEqual(StubService.cancellations, 0)
    }

    func testItsSessionKeepsNothingOnThisMac() {
        let configuration = ModelClient(protocolClasses: [StubService.self]).configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    func testARequestNeverShowsItsHeadersOrBodyWhenPrinted() {
        let request = CloudRequest(method: .post, url: messages, headers: ["x-api-key": "synthetic-key"],
                                   body: Data("synthetic body".utf8))
        var dumped = ""
        dump(request, to: &dumped)

        for shown in [String(describing: request), String(reflecting: request), dumped] {
            XCTAssertFalse(shown.contains("synthetic-key"), shown)
            XCTAssertFalse(shown.contains("synthetic body"), shown)
            XCTAssertTrue(shown.contains("api.anthropic.com"), shown)
        }
    }

    func testAFailureFromBeyondURLLoadingIsSaidAsTheHostUnreachable() async throws {
        StubService.answer(.failWith(NSError(domain: "kCFErrorDomainCFNetwork", code: 310,
                                             userInfo: [NSURLErrorFailingURLErrorKey: models])))
        let client = ModelClient(protocolClasses: [StubService.self])

        do {
            _ = try await client.send(CloudRequest(method: .get, url: models))
            XCTFail("It answered")
        } catch {
            guard case .unreachable(let host, _)? = error as? CloudError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(host, "api.openai.com")
        }
    }

    func testAHostThatCantBeReachedIsNamedWhenItIsAskedAndAsItAnswers() async throws {
        StubService.answer(.fail(.cannotConnectToHost))
        let client = ModelClient(protocolClasses: [StubService.self])
        do {
            _ = try await client.send(CloudRequest(method: .get, url: models))
            XCTFail("It answered")
        } catch {
            XCTAssertEqual(error as? CloudError, .unreachable(host: "api.openai.com", .cannotConnectToHost))
        }

        StubService.answer(.fail(.networkConnectionLost, afterChunks: [Data("partial\n".utf8)]))
        let response = try await client.send(CloudRequest(method: .post, url: messages))
        do {
            _ = try await Self.read(response.body)
            XCTFail("It ended as if whole")
        } catch {
            XCTAssertEqual(error as? CloudError, .unreachable(host: "api.anthropic.com", .networkConnectionLost))
        }
    }

    private static func read(_ body: AsyncThrowingStream<Data, any Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in body { chunks.append(String(decoding: chunk, as: UTF8.self)) }
        return chunks
    }
}

private extension AsyncThrowingStream.Iterator where Element == Data, Failure == any Error {
    /// The next chunk, as text, read on the caller's actor.
    mutating func nextText(isolation: isolated (any Actor)? = #isolation) async throws -> String? {
        try await next(isolation: isolation).map { String(decoding: $0, as: UTF8.self) }
    }
}
