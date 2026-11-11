import Foundation

/// A request to a model service, as `ModelClient` sends it. It is a plain value, so that it could cross into another
/// process; printed or dumped, it shows its method and address, never its headers, such as a key, or its body.
struct CloudRequest: Equatable, Codable, Sendable {
    enum Method: String, Codable, Sendable {
        case get = "GET"
        case post = "POST"
    }

    var method: Method
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
}

extension CloudRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "\(method.rawValue) \(url.absoluteString)" }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["method": method.rawValue, "url": url.absoluteString], displayStyle: .struct)
    }
}

/// What a model service answered: its status and headers as they arrive, and its body as it streams in.
struct CloudResponse: Sendable {
    let status: Int
    /// The headers, by their names in lower case.
    let headers: [String: String]
    /// The body as it comes: each line once it ends, and a line longer than `ModelClient.chunkSize` in parts of that
    /// many bytes, only the last of which ends it. The parts are bytes, to join into lines before they are read as
    /// text, since a part can end within a character. Not reading the body to the end, or cancelling the task that
    /// reads it, cancels the request.
    let body: AsyncThrowingStream<Data, any Error>
}

/// Why `ModelClient` didn't send a request, or got no answer to it.
enum CloudError: Error, Equatable, Sendable {
    /// The address isn't one Keeptide connects to: a host it wasn't given, a scheme other than HTTPS, a port other than
    /// HTTPS's, or a user name in it. Nothing was sent.
    case notAllowed
    /// The host couldn't be reached, or the connection to it failed.
    case unreachable(host: String, URLError.Code)
    /// Something other than an HTTP response came back.
    case notHTTP
}
