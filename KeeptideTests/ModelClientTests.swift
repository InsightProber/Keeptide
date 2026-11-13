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

/// A stand-in for the network in `ModelClient`'s session. It answers every request as the test says, so that nothing
/// reaches the network, and records what each request carried.
private final class StubService: URLProtocol, @unchecked Sendable {
    enum Answer {
        /// A response whose body comes in these chunks. When `holdsAfterFirst`, the rest waits for `releaseRest()`,
        /// or, when `releasesOnItsOwn`, for two seconds.
        case respond(status: Int, headers: [String: String], chunks: [Data], holdsAfterFirst: Bool = false,
                     releasesOnItsOwn: Bool = true)
        /// A redirect to another address; not followed, it is the answer.
        case redirect(to: URL, status: Int)
        /// The connection fails; when there are chunks, a moment after a streamed answer began with them.
        case fail(URLError.Code, afterChunks: [Data] = [])
        /// The connection fails with this error, whatever it is.
        case failWith(any Error & Sendable)
        /// No answer at all.
        case hang
    }

    struct Seen {
        let request: URLRequest
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = Answer.respond(status: 200, headers: [:], chunks: [])
    nonisolated(unsafe) private static var seen: [Seen] = []
    nonisolated(unsafe) private static var stoppedBeforeTheEnd = 0
    /// The rest of an answer held after its first chunk, and which answer it is.
    nonisolated(unsafe) private static var rest: (id: UUID, send: () -> Void)?
    nonisolated(unsafe) private static var restSentOnItsOwn = false

    static var requests: [Seen] { lock.withLock { seen } }
    /// How many requests were stopped before their answer was whole.
    static var cancellations: Int { lock.withLock { stoppedBeforeTheEnd } }
    static var releasedOnItsOwn: Bool { lock.withLock { restSentOnItsOwn } }

    static func answer(_ answer: Answer) {
        lock.withLock { current = answer }
    }

    static func reset() {
        lock.withLock {
            current = .respond(status: 200, headers: [:], chunks: [])
            seen = []
            stoppedBeforeTheEnd = 0
            rest = nil
            restSentOnItsOwn = false
        }
    }

    /// Sends the rest of an answer held after its first chunk.
    static func releaseRest() {
        let send = lock.withLock { () -> (() -> Void)? in
            defer { rest = nil }
            return rest?.send
        }
        send?()
    }

    private let stateLock = NSLock()
    private var isStopped = false
    private var isFinished = false
    /// The thread that started loading, on which the URL loading system wants its client called, and what waits to
    /// be run there.
    private var loadingThread: Thread?
    private var deferred: [() -> Void] = []

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        stateLock.withLock { loadingThread = Thread.current }
        let body = Self.body(of: request)
        let answer = Self.lock.withLock { () -> Answer in
            Self.seen.append(Seen(request: request, body: body))
            return Self.current
        }
        guard let url = request.url else { return }
        switch answer {
        case .respond(let status, let headers, let chunks, let holdsAfterFirst, let releasesOnItsOwn):
            respond(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            guard holdsAfterFirst, let first = chunks.first else {
                send(chunks)
                finish()
                return
            }
            send([first])
            let id = UUID()
            let rest = { [self] in
                onLoadingThread { [self] in
                    send(Array(chunks.dropFirst()))
                    finish()
                }
            }
            Self.lock.withLock { Self.rest = (id, rest) }
            guard releasesOnItsOwn else { return }
            // Only this answer's rest: a later test's held answer is its own.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                let send = Self.lock.withLock { () -> (() -> Void)? in
                    guard let held = Self.rest, held.id == id else { return nil }
                    Self.rest = nil
                    Self.restSentOnItsOwn = true
                    return held.send
                }
                send?()
            }
        case .redirect(let target, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            respond(response)
            finish()
        case .fail(let code, let chunks):
            guard !chunks.isEmpty else {
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            respond(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "text/event-stream"])!)
            send(chunks)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                onLoadingThread { [self] in
                    guard !stopped else { return }
                    client?.urlProtocol(self, didFailWithError: URLError(code))
                }
            }
        case .failWith(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang:
            break
        }
    }

    override func stopLoading() {
        let wasWhole = stateLock.withLock { () -> Bool in
            isStopped = true
            return isFinished
        }
        if !wasWhole { Self.lock.withLock { Self.stoppedBeforeTheEnd += 1 } }
    }

    private var stopped: Bool { stateLock.withLock { isStopped } }

    /// Runs `work` on the thread that started loading.
    private func onLoadingThread(_ work: @escaping () -> Void) {
        let thread = stateLock.withLock { () -> Thread? in
            deferred.append(work)
            return loadingThread
        }
        guard let thread else { return }
        perform(#selector(runDeferred), on: thread, with: nil, waitUntilDone: false,
                modes: [RunLoop.Mode.common.rawValue])
    }

    @objc private func runDeferred() {
        let work = stateLock.withLock { () -> [() -> Void] in
            defer { deferred = [] }
            return deferred
        }
        work.forEach { $0() }
    }

    private func respond(_ response: HTTPURLResponse) {
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
    }

    private func send(_ chunks: [Data]) {
        for chunk in chunks where !stopped { client?.urlProtocol(self, didLoad: chunk) }
    }

    private func finish() {
        guard !stopped else { return }
        stateLock.withLock { isFinished = true }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
