import Foundation

/// Claude's Messages API, streamed: what Keeptide sends for a request, and a generation's events from what comes back.
/// The instructions go in the system prompt and the content in a user message of its own. Nothing else is sent: no
/// sampling parameters, which the API version refuses, no fallback to another model, which would change the model
/// a person chose without a word, and nothing that identifies the person.
struct AnthropicMessagesSource: GenerationSource {
    let client: ModelClient
    let key: APIKey
    let request: ModelRequest

    private static let preset = ProviderPreset.anthropic
    /// The most of an error's body read to tell what went wrong.
    private static let errorBodyLimit = 64 * 1024
    /// The most of a provider's own message a result shows.
    private static let shownMessageLimit = 200

    func events() -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<GenerationEvent, any Error>.makeStream()
        let source = self
        let reading = Task {
            do {
                try await source.answer(into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reading.cancel() }
        return events
    }

    /// Sends the request, written here rather than by the caller as an image takes a while to encode, and reads the
    /// answer into `continuation` until Claude says it is done.
    private func answer(into continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation) async throws {
        guard let sent = cloudRequest() else { throw GenerationError.interrupted }
        let response: CloudResponse
        do {
            response = try await client.send(sent)
        } catch {
            throw Self.sendFailure(error)
        }
        guard response.status == 200 else { throw await Self.failure(of: response, for: request) }
        try await Self.read(response.body, for: request, into: continuation)
    }

    /// The request as sent, with the key in its header; nil if it can't be written, which a request of strings never
    /// is.
    private func cloudRequest() -> CloudRequest? {
        var headers = Self.preset.fixedHeaders
        headers["content-type"] = "application/json"
        switch Self.preset.auth {
        case .header(let name): headers[name] = key.value
        case .bearer: headers["authorization"] = "Bearer \(key.value)"
        }
        let content: Block = switch request.input {
        case .text(let text): Block(type: "text", text: text)
        case .image(let data, let mediaType):
            Block(type: "image", source: ImageSource(mediaType: mediaType, data: data.base64EncodedString()))
        }
        let body = Body(model: request.model, maxTokens: request.maxOutputTokens, system: request.instructions,
                        messages: [Message(content: [content])],
                        thinking: request.thinking.map { Thinking(type: $0.rawValue) },
                        outputConfig: request.effort.map { OutputConfig(effort: $0.rawValue) })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let encoded = try? encoder.encode(body) else { return nil }
        return CloudRequest(method: .post, url: Self.preset.baseURL.appending(path: "v1/messages"), headers: headers,
                            body: encoded)
    }

    /// Reads Claude's events into `continuation` until Claude says it is done. However else the answer ends, what it
    /// used so far is reported first, as it is paid for: a connection lost part way, an event that can't be read and
    /// a line too long end it unexpectedly.
    private static func read(_ body: AsyncThrowingStream<Data, any Error>, for request: ModelRequest,
                             into continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation)
        async throws {
        var parser = ServerSentEventParser()
        var answer = Answer(request: request)
        do {
            for try await chunk in body {
                for event in try parser.feed(chunk) {
                    for made in try answer.read(event) { continuation.yield(made) }
                    if answer.isOver { return }
                }
            }
            // The stream ended before Claude said it was done.
            throw GenerationError.interrupted
        } catch let error as CancellationError {
            throw error
        } catch {
            if let usage = answer.usage { continuation.yield(usage) }
            throw error as? GenerationError ?? .interrupted
        }
    }

    /// An HTTP error as a person reads it, from its status, its `retry-after` header and the error in its body. A body
    /// cut off is read for what arrived, and a body that isn't Claude's leaves the status to say what went wrong.
    private static func failure(of response: CloudResponse, for request: ModelRequest) async -> any Error {
        var body = Data()
        do {
            for try await chunk in response.body {
                body.append(chunk)
                if body.count >= errorBodyLimit { break }
            }
        } catch is CancellationError {
            return CancellationError()
        } catch {
            // What arrived is read as it is.
        }
        let error = try? JSONDecoder().decode(ErrorBody.self, from: body).error
        let seconds = response.headers["retry-after"].flatMap { Int($0) }
        return failure(type: error?.type, message: error?.message ?? "", status: response.status,
                       retryAfter: seconds.flatMap { $0 > 0 ? .seconds($0) : nil }, for: request)
    }

    /// An error Claude reported, by HTTP status or in the stream, as a person reads it. A few are told apart only by
    /// their message, and then only for the types that say them.
    fileprivate static func failure(type: String?, message: String, status: Int?, retryAfter: Duration?,
                                    for request: ModelRequest) -> GenerationError {
        let said = message.lowercased()
        let invalid = status == 400 || type == "invalid_request_error"
        let limited = status == 429 || type == "rate_limit_error"
        if status == 401 || type == "authentication_error" {
            return GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key.")
        }
        if status == 402 || type == "billing_error" || (invalid && said.contains("credit balance")) {
            return GenerationError(kind: .noCredit, message: "Your Anthropic account has no remaining credit.")
        }
        if (invalid || limited) && said.contains("usage limit") {
            return GenerationError(kind: .noCredit, message: "Your Anthropic account reached its spending limit.")
        }
        if type == "permission_error" {
            return GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to this model.")
        }
        if type == "forbidden" {
            return GenerationError(kind: .regionUnavailable, message: "Anthropic isn't available in your region.")
        }
        if status == 404 || type == "not_found_error" {
            return GenerationError(kind: .modelUnavailable, message: "\(request.modelName) is no longer available.")
        }
        if status == 413 || type == "request_too_large" || (invalid && said.contains("prompt is too long")) {
            return tooLarge(request)
        }
        if limited {
            return GenerationError(kind: .rateLimited, message: "Too many requests. Try again \(wait(retryAfter)).",
                                   retryAfter: retryAfter)
        }
        if status == 529 || type == "overloaded_error" {
            return GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again.")
        }
        if (status ?? 0) >= 500 || type == "api_error" {
            return GenerationError(kind: .overloaded, message: "Anthropic couldn't answer just now. Try again.")
        }
        // An error in the stream of a type Keeptide doesn't know ends the answer unexpectedly. Any other HTTP error,
        // such as a 403 for a reason of its own, is said in the provider's words.
        if status == nil && !invalid { return .interrupted }
        let shown = shown(message)
        return GenerationError(kind: .requestRejected, message: shown.isEmpty
                               ? "Anthropic turned the request away."
                               : "Anthropic turned the request away: \(shown)")
    }

    fileprivate static func tooLarge(_ request: ModelRequest) -> GenerationError {
        switch request.input {
        case .text: GenerationError(kind: .inputTooLarge, message: "This text is too long for this model.")
        case .image: GenerationError(kind: .inputTooLarge, message: "This image is too large for this model.")
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

    /// A request that couldn't be sent, as a person reads it: a host that can't be reached is named.
    private static func sendFailure(_ error: any Error) -> any Error {
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
}

/// What Claude's answer has said so far, and the events each of its server-sent events makes.
private struct Answer {
    let request: ModelRequest
    private var hasStarted = false
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var stopReason: String?
    /// Whether Claude said the message stopped.
    private(set) var isOver = false

    init(request: ModelRequest) {
        self.request = request
    }

    /// What the answer has used so far, once Claude started it.
    var usage: GenerationEvent? {
        hasStarted ? .usage(GenerationUsage(inputTokens: inputTokens, outputTokens: outputTokens)) : nil
    }

    mutating func read(_ event: ServerSentEvent) throws -> [GenerationEvent] {
        switch event.type {
        case "message_start":
            let usage = try decode(MessageStart.self, event.data).message.usage
            hasStarted = true
            inputTokens = usage?.inputTokens
            outputTokens = usage?.outputTokens
            return [.started(GenerationInfo(engine: request.modelName, model: request.model))]
        case "content_block_delta":
            // Thinking, and anything else that isn't text, stays out of the result.
            let delta = try decode(BlockDelta.self, event.data).delta
            guard delta.type == "text_delta", let text = delta.text, !text.isEmpty else { return [] }
            return [.delta(text)]
        case "message_delta":
            let delta = try decode(MessageDelta.self, event.data)
            stopReason = delta.delta.stopReason ?? stopReason
            outputTokens = delta.usage?.outputTokens ?? outputTokens
            inputTokens = delta.usage?.inputTokens ?? inputTokens
            return []
        case "message_stop":
            isOver = true
            let ending: FinishReason
            switch stopReason {
            case "end_turn", "stop_sequence": ending = .completed
            case "max_tokens": ending = .truncated
            case "refusal": ending = .refused
            case "model_context_window_exceeded": throw AnthropicMessagesSource.tooLarge(request)
            // Claude stopped for a tool or to pause, which a request without tools doesn't ask for, or didn't say why.
            default: throw GenerationError.interrupted
            }
            return [usage, GenerationEvent.finished(ending)].compactMap { $0 }
        case "error":
            let error = try decode(ErrorBody.self, event.data).error
            throw AnthropicMessagesSource.failure(type: error.type, message: error.message ?? "", status: nil,
                                                  retryAfter: nil, for: request)
        default:
            // `ping`, the start and end of each block, and events Keeptide doesn't know.
            return []
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ data: String) throws -> Value {
        // An event that can't be read ends the answer unexpectedly, as any failure but Claude's own does.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(data.utf8))
    }
}

// MARK: The wire

private struct Body: Encodable {
    let model: String
    let maxTokens: Int
    let stream = true
    let system: String
    let messages: [Message]
    let thinking: Thinking?
    let outputConfig: OutputConfig?
}

private struct Message: Encodable {
    let role = "user"
    let content: [Block]
}

private struct Block: Encodable {
    let type: String
    var text: String?
    var source: ImageSource?
}

private struct ImageSource: Encodable {
    let type = "base64"
    let mediaType: String
    let data: String
}

private struct Thinking: Encodable {
    let type: String
}

private struct OutputConfig: Encodable {
    let effort: String
}

private struct Usage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct MessageStart: Decodable {
    struct Started: Decodable {
        let usage: Usage?
    }

    let message: Started
}

private struct BlockDelta: Decodable {
    struct Delta: Decodable {
        let type: String
        let text: String?
    }

    let delta: Delta
}

private struct MessageDelta: Decodable {
    struct Delta: Decodable {
        let stopReason: String?
    }

    let delta: Delta
    let usage: Usage?
}

private struct ErrorBody: Decodable {
    struct Failure: Decodable {
        let type: String
        let message: String?
    }

    let error: Failure
}
