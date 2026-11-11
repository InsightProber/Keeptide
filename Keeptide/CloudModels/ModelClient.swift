import Foundation

/// The one way Keeptide reaches a model service: over HTTPS, and only to the hosts it was given, the providers' own APIs
/// unless told otherwise. It follows no redirect, so that a request, and the key in its headers, goes to no other host;
/// keeps no cache, cookies or credentials; and logs nothing it sends or receives. Requests run off the main actor, and
/// an answer's body streams in as it comes, even once the client itself is let go.
final class ModelClient: Sendable {
    /// The hosts of the model services Keeptide knows: Anthropic's and OpenAI's APIs.
    static let providerHosts = Set(ProviderPreset.all.compactMap { $0.baseURL.host(percentEncoded: false) })
    /// The most of a line passed on at once while it doesn't end.
    static let chunkSize = 16 * 1024

    private let hosts: Set<String>
    private let refusal: RedirectRefusal
    private let session: URLSession

    /// `hosts`, when given, are the only hosts it connects to, in place of the providers'. `protocolClasses`, for
    /// tests, answer every request in place of the network.
    init(hosts: Set<String> = ModelClient.providerHosts, protocolClasses: [AnyClass] = []) {
        self.hosts = Set(hosts.map { $0.lowercased() })
        let configuration = URLSessionConfiguration.ephemeral
        // Nothing sent or received is kept on this Mac.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // Without a connection, a request fails at once rather than waiting for one.
        configuration.waitsForConnectivity = false
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        let refusal = RedirectRefusal()
        self.refusal = refusal
        session = URLSession(configuration: configuration, delegate: refusal, delegateQueue: nil)
    }

    deinit {
        // Answers still coming in are read to the end; reading no further cancels them, as it always does.
        session.finishTasksAndInvalidate()
    }

    /// How its session is set up: what it keeps on this Mac, which is nothing.
    var configuration: URLSessionConfiguration { session.configuration }

    /// Whether Keeptide connects to `url`: over HTTPS, on HTTPS's port, to one of its hosts, with no user name or
    /// password in it.
    func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false)?.lowercased(),
              hosts.contains(host), url.port == nil || url.port == 443,
              url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else { return false }
        return true
    }

    /// Sends `request`, and returns the answer once its headers arrive, with its body to read as it streams in. An
    /// address it doesn't connect to is refused before anything is sent, and a redirect is the answer rather than
    /// followed. Cancelling the task that waits for the answer cancels the request.
    func send(_ request: CloudRequest) async throws -> CloudResponse {
        guard allows(request.url) else { throw CloudError.notAllowed }
        let host = request.url.host(percentEncoded: false)?.lowercased() ?? ""
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            // The task refuses redirects itself, whatever the session's delegate would do.
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: refusal)
        } catch {
            throw Self.failure(error, host: host)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw CloudError.notHTTP
        }
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in http.allHeaderFields { headers[name.lowercased()] = value }
        return CloudResponse(status: http.statusCode, headers: headers, body: Self.body(bytes, host: host))
    }

    /// The body as it comes: each line once it ends, and a long one `chunkSize` bytes at a time.
    private static func body(_ bytes: sending URLSession.AsyncBytes,
                             host: String) -> AsyncThrowingStream<Data, any Error> {
        let task = bytes.task
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let reading = Task {
            var chunk = Data()
            do {
                for try await byte in bytes {
                    chunk.append(byte)
                    guard byte == UInt8(ascii: "\n") || chunk.count >= chunkSize else { continue }
                    continuation.yield(chunk)
                    chunk = Data()
                }
                if !chunk.isEmpty { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: failure(error, host: host))
            }
        }
        // Read to the end or not, the request ends with the body.
        continuation.onTermination = { _ in
            reading.cancel()
            task.cancel()
        }
        return body
    }

    /// A failure as Keeptide says it: a request cancelled as cancelled, and anything else as the host it couldn't
    /// reach, with nothing more of the error, such as the address it was for.
    private static func failure(_ error: any Error, host: String) -> any Error {
        if error is CancellationError { return error }
        guard let error = error as? URLError else { return CloudError.unreachable(host: host, .unknown) }
        return error.code == .cancelled ? CancellationError() : CloudError.unreachable(host: host, error.code)
    }
}

/// Refuses every redirect, so that a request, and the key in its headers, goes only to the host it was made for.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
