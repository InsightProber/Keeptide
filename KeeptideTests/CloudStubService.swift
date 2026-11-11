import Foundation

/// A stand-in for the network in a `ModelClient`'s session, for the cloud-model tests. It answers every request as the
/// test says, so that nothing reaches the network, and records what each request carried. Its state is shared, so
/// each test resets it first; tests run one at a time.
final class StubService: URLProtocol, @unchecked Sendable {
    enum Answer {
        /// A response whose body comes in these chunks. When `holdsAfterFirst`, the rest waits for `releaseRest()`,
        /// or, when `releasesOnItsOwn`, for two seconds.
        case respond(status: Int, headers: [String: String], chunks: [Data], holdsAfterFirst: Bool = false,
                     releasesOnItsOwn: Bool = true)
        /// A redirect to another address; not followed, it is the answer.
        case redirect(to: URL, status: Int)
        /// The connection fails; when there are chunks, a moment after a streamed answer began with them.
        case fail(URLError.Code, afterChunks: [Data] = [], status: Int = 200)
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
        case .fail(let code, let chunks, let status):
            guard !chunks.isEmpty else {
                client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            respond(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
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
