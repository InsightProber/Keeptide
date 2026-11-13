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

    func events() -> AsyncThrowingStream<GenerationEvent, any Error> {
        let source = self
        let request = request
        return ProviderStream.events(from: Self.preset, by: client, sending: { source.cloudRequest() },
                                     answer: Answer(request: request)) { status, headers, body in
            let error = try? ProviderStream.decode(ErrorBody.self, body).error
            return .error(Self.failure(type: error?.type, message: error?.message ?? "", status: status,
                                       retryAfter: ProviderStream.retryAfter(in: headers), for: request))
        }
    }

    /// The request as sent, with the key in its header.
    private func cloudRequest() -> CloudRequest? {
        let content: Block = switch request.input {
        case .text(let text): Block(type: "text", text: text)
        case .image(let data, let mediaType):
            Block(type: "image", source: ImageSource(mediaType: mediaType, data: data.base64EncodedString()))
        }
        let body = Body(model: request.model, maxTokens: request.maxOutputTokens, system: request.instructions,
                        messages: [Message(content: [content])],
                        thinking: request.thinking.map { Thinking(type: $0.rawValue) },
                        outputConfig: request.effort.map { OutputConfig(effort: $0.rawValue) })
        guard let encoded = ProviderStream.encode(body) else { return nil }
        return CloudRequest(method: .post, url: Self.preset.baseURL.appending(path: "v1/messages"),
                            headers: ProviderStream.headers(for: Self.preset, key: key), body: encoded)
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
            return ProviderStream.tooLarge(request)
        }
        if limited {
            return ProviderStream.rateLimited(retryAfter: retryAfter)
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
        return ProviderStream.rejected(by: preset, saying: message)
    }
}

/// What Claude's answer has said so far, and the events each of its server-sent events makes.
private struct Answer: ProviderAnswer {
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
    var usage: GenerationUsage? {
        hasStarted ? GenerationUsage(inputTokens: inputTokens, outputTokens: outputTokens) : nil
    }

    mutating func read(_ event: ServerSentEvent) throws -> [GenerationEvent] {
        let data = Data(event.data.utf8)
        switch event.type {
        case "message_start":
            let usage = try ProviderStream.decode(MessageStart.self, data).message.usage
            hasStarted = true
            inputTokens = usage?.inputTokens
            outputTokens = usage?.outputTokens
            return [.started(GenerationInfo(engine: request.modelName, model: request.model))]
        case "content_block_delta":
            // Thinking, and anything else that isn't text, stays out of the result.
            let delta = try ProviderStream.decode(BlockDelta.self, data).delta
            guard delta.type == "text_delta", let text = delta.text, !text.isEmpty else { return [] }
            return [.delta(text)]
        case "message_delta":
            let delta = try ProviderStream.decode(MessageDelta.self, data)
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
            case "model_context_window_exceeded": throw ProviderStream.tooLarge(request)
            // Claude stopped for a tool or to pause, which a request without tools doesn't ask for, or didn't say why.
            default: throw GenerationError.interrupted
            }
            return [usage.map(GenerationEvent.usage), GenerationEvent.finished(ending)].compactMap { $0 }
        case "error":
            let error = try ProviderStream.decode(ErrorBody.self, data).error
            throw AnthropicMessagesSource.failure(type: error.type, message: error.message ?? "", status: nil,
                                                  retryAfter: nil, for: request)
        default:
            // `ping`, the start and end of each block, and events Keeptide doesn't know.
            return []
        }
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
