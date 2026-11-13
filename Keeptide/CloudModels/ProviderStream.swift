import Foundation

/// A provider's answer as its server-sent events arrive: the events each one makes, whether the provider said the
/// answer is over, and what the answer has used so far, once the provider said.
protocol ProviderAnswer: Sendable {
    var isOver: Bool { get }
    var usage: GenerationUsage? { get }
    mutating func read(_ event: ServerSentEvent) throws -> [GenerationEvent]
}

/// What every provider's source does alike: send its request, read the streamed answer until the provider says it is
/// over, and say what went wrong as a person reads it.
enum ProviderStream {
    /// How a response other than a 200 ends the generation.
    enum Failure: Sendable {
        /// With this error.
        case error(GenerationError)
        /// As declined by the model it names, when the provider's policies blocked the request before an answer began.
        case declined(GenerationInfo)
    }

    /// The most of an error's body read to tell what went wrong.
    static let errorBodyLimit = 64 * 1024
    /// The most of a provider's own message a result shows.
    static let shownMessageLimit = 200

    /// A generation's events. The request is written in the task that sends it, rather than by the caller, as an image
    /// takes a while to encode, and a generation stopped meanwhile sends nothing. `answer` reads a 200's events, and
    /// `failure` tells any other status from its headers and the start of its body. Stopping reading the events
    /// cancels the request.
    static func events<Answer: ProviderAnswer>(
        from preset: ProviderPreset, by client: ModelClient, sending request: @escaping @Sendable () -> CloudRequest?,
        answer: Answer,
        failure: @escaping @Sendable (_ status: Int, _ headers: [String: String], _ body: Data) -> Failure
    ) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<GenerationEvent, any Error>.makeStream()
        let reading = Task {
            do {
                guard let sent = request() else { throw GenerationError.interrupted }
                try Task.checkCancellation()
                let response: CloudResponse
                do {
                    response = try await client.send(sent)
                } catch {
                    throw sendFailure(error, to: preset)
                }
                guard response.status == 200 else {
                    guard let body = await errorBody(of: response) else { throw CancellationError() }
                    switch failure(response.status, response.headers, body) {
                    case .error(let error):
                        throw error
                    case .declined(let model):
                        continuation.yield(.started(model))
                        continuation.yield(.finished(.refused))
                        continuation.finish()
                        return
                    }
                }
                try await read(response.body, with: answer, into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reading.cancel() }
        return events
    }

    /// The headers every request to `preset` carries, with `key` where the provider wants it.
    static func headers(for preset: ProviderPreset, key: APIKey) -> [String: String] {
        var headers = preset.fixedHeaders
        headers["content-type"] = "application/json"
        switch preset.auth {
        case .header(let name): headers[name] = key.value
        case .bearer: headers["authorization"] = "Bearer \(key.value)"
        }
        return headers
    }

    /// A request's body with its keys in snake case; nil if it can't be written, which a body of strings never is.
    static func encode(_ body: some Encodable) -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        // An escaped slash, frequent in base64, only adds bytes.
        encoder.outputFormatting = .withoutEscapingSlashes
        return try? encoder.encode(body)
    }

    /// An event's or an error's JSON, its keys in snake case. One that can't be read ends the answer unexpectedly, as
    /// any failure but the provider's own does.
    static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    /// How long a `retry-after` header asks to wait, when it gives a number of seconds above zero.
    static func retryAfter(in headers: [String: String]) -> Duration? {
        headers["retry-after"].flatMap { Int($0) }.flatMap { $0 > 0 ? .seconds($0) : nil }
    }

    /// Too many requests, and when to try again.
    static func rateLimited(retryAfter: Duration?) -> GenerationError {
        GenerationError(kind: .rateLimited, message: "Too many requests. Try again \(wait(retryAfter)).",
                        retryAfter: retryAfter)
    }

    /// The text or image too large for the model.
    static func tooLarge(_ request: ModelRequest) -> GenerationError {
        switch request.input {
        case .text: GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")
        case .image: GenerationError(kind: .inputTooLarge, message: "This image is too large for this model.")
        }
    }

    /// The request turned away for the provider's own reason, in its words when it gave some.
    static func rejected(by preset: ProviderPreset, saying message: String) -> GenerationError {
        let shown = shown(message)
        return GenerationError(kind: .requestRejected, message: shown.isEmpty
                               ? "\(preset.displayName) turned the request away."
                               : "\(preset.displayName) turned the request away: \(shown)")
    }

    /// Reads the answer's events into `continuation` until the provider says it is over. However else the answer
    /// ends, what it used so far is reported first, as it is paid for: a connection lost part way, an event that can't
    /// be read and a line too long end it unexpectedly.
    private static func read<Answer: ProviderAnswer>(
        _ body: AsyncThrowingStream<Data, any Error>, with answer: Answer,
        into continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation
    ) async throws {
        var parser = ServerSentEventParser()
        var answer = answer
        do {
            for try await chunk in body {
                for event in try parser.feed(chunk) {
                    for made in try answer.read(event) { continuation.yield(made) }
                    if answer.isOver { return }
                }
            }
            // The stream ended before the provider said the answer was over.
            throw GenerationError.interrupted
        } catch let error as CancellationError {
            throw error
        } catch {
            if let usage = answer.usage { continuation.yield(.usage(usage)) }
            throw error as? GenerationError ?? .interrupted
        }
    }

    /// The start of an error's body: what arrived before it ended, was cut off or reached the limit. Nil when the task
    /// reading it was cancelled.
    private static func errorBody(of response: CloudResponse) async -> Data? {
        var body = Data()
        do {
            for try await chunk in response.body {
                body.append(chunk)
                if body.count >= errorBodyLimit { break }
            }
        } catch is CancellationError {
            return nil
        } catch {
            // What arrived is read as it is.
        }
        return body
    }

    /// A request that couldn't be sent, as a person reads it: a host that can't be reached is named.
    private static func sendFailure(_ error: any Error, to preset: ProviderPreset) -> any Error {
        switch error as? CloudError {
        case .unreachable(let host, _)?:
            return GenerationError(kind: .network, message: "Can't reach \(host).")
        case .notAllowed?:
            return GenerationError(kind: .network,
                                   message: "Can't reach \(preset.baseURL.host(percentEncoded: false) ?? "").")
        case .notHTTP?:
            return GenerationError.interrupted
        case nil:
            return error is CancellationError ? error : GenerationError.interrupted
        }
    }

    /// When to try again, as a person says it: in seconds under a minute, else in minutes or hours, rounded up.
    private static func wait(_ retryAfter: Duration?) -> String {
        guard let seconds = retryAfter?.components.seconds else { return "shortly" }
        let (count, unit): (Int64, String) = switch seconds {
        case ..<60: (seconds, "second")
        case ..<3600: ((seconds + 59) / 60, "minute")
        default: ((seconds + 3599) / 3600, "hour")
        }
        return "in \(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// A provider's own message as a result shows it: its first line, cut short when that is long.
    private static func shown(_ message: String) -> String {
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isNewline }
        return line.count > shownMessageLimit ? String(line.prefix(shownMessageLimit)) + "…" : String(line)
    }
}
