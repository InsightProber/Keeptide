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
            .error(Self.failure(body, status: status, headers: headers, about: .generation(request)))
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

    /// An HTTP error as a person reads it, from its status, its `retry-after` header and the error in its body.
    fileprivate static func failure(_ body: Data, status: Int, headers: [String: String],
                                    about subject: ProviderStream.Subject) -> GenerationError {
        let error = try? ProviderStream.decode(ErrorBody.self, body).error
        return failure(type: error?.type, message: error?.message ?? "", status: status,
                       retryAfter: ProviderStream.retryAfter(in: headers), about: subject)
    }

    /// An error Claude reported, by HTTP status or in the stream, as a person reads it. A few are told apart only by
    /// their message, and then only for the types that say them.
    fileprivate static func failure(type: String?, message: String, status: Int?, retryAfter: Duration?,
                                    about subject: ProviderStream.Subject) -> GenerationError {
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
            let what = switch subject {
            case .generation: "this model"
            case .models: "Anthropic's models"
            }
            return GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to \(what).")
        }
        if type == "forbidden" {
            return GenerationError(kind: .regionUnavailable, message: "Anthropic isn't available in your region.")
        }
        if case .generation(let request) = subject, status == 404 || type == "not_found_error" {
            return GenerationError(kind: .modelUnavailable, message: "\(request.modelName) is no longer available.")
        }
        if case .generation(let request) = subject,
           status == 413 || type == "request_too_large" || (invalid && said.contains("prompt is too long")) {
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
                                                  retryAfter: nil, about: .generation(request))
        default:
            // `ping`, the start and end of each block, and events Keeptide doesn't know.
            return []
        }
    }
}

/// Claude's list of models, read page by page until Claude says there are no more, and given only whole.
enum AnthropicModels {
    private static let preset = ProviderPreset.anthropic
    /// The most models a page holds, which the Models API allows.
    private static let pageSize = 1000
    /// The most pages read. Ten thousand models is more than any provider offers, so a list that goes on is refused.
    private static let pageLimit = 10

    static func list(by client: ModelClient, key: APIKey,
                     waiting wait: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        async throws -> [RemoteModel] {
        var models: [RemoteModel] = []
        var listed: Set<String> = []
        var cursors: Set<String> = []
        var after: String?
        for _ in 0..<pageLimit {
            var url = preset.baseURL.appending(path: "v1/models")
            url.append(queryItems: [URLQueryItem(name: "limit", value: "\(pageSize)")]
                + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? []))
            let request = CloudRequest(method: .get, url: url, headers: ProviderStream.headers(for: preset, key: key))
            let body = try await ProviderStream.fetch(request, from: preset, by: client, waiting: wait) {
                AnthropicMessagesSource.failure($2, status: $0, headers: $1, about: .models)
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: body) else {
                throw GenerationError.interrupted
            }
            let read = page.data.compactMap { $0.value?.model }
            // A page of models none of which can be read would empty the catalog it stands in for.
            guard !read.isEmpty || page.data.isEmpty else { throw GenerationError.interrupted }
            // A model listed again, as the list changes between pages, is kept where it was first.
            models += read.filter { listed.insert($0.id).inserted }
            guard page.hasMore == true else { return models }
            // A page that says there are more says where it ended, somewhere the list hasn't been.
            guard let last = page.lastID, cursors.insert(last).inserted else { throw GenerationError.interrupted }
            after = last
        }
        throw GenerationError.interrupted
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

/// A page of the Models API's list.
private struct Page: Decodable {
    let data: [Lenient<ListedModel>]
    let hasMore: Bool?
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

/// A model as the Models API lists it. Only its identifier must be read; anything else that can't be is unknown. A
/// capability's levels are read by their names, as they come, so the keys are spelled out rather than converted from
/// snake case.
private struct ListedModel: Decodable {
    let id: String
    let displayName: String?
    let createdAt: String?
    let maxInputTokens: Int?
    let maxTokens: Int?
    let capabilities: Capabilities?
    let lifecycle: String?
    let retiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
        case maxInputTokens = "max_input_tokens"
        case maxTokens = "max_tokens"
        case capabilities
        case lifecycle
        case retiresAt = "retires_at"
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: fields, debugDescription: "No identifier")
        }
        displayName = try? fields.decodeIfPresent(String.self, forKey: .displayName)
        createdAt = try? fields.decodeIfPresent(String.self, forKey: .createdAt)
        maxInputTokens = try? fields.decodeIfPresent(Int.self, forKey: .maxInputTokens)
        maxTokens = try? fields.decodeIfPresent(Int.self, forKey: .maxTokens)
        capabilities = try? fields.decodeIfPresent(Capabilities.self, forKey: .capabilities)
        lifecycle = try? fields.decodeIfPresent(String.self, forKey: .lifecycle)
        retiresAt = try? fields.decodeIfPresent(String.self, forKey: .retiresAt)
    }

    var model: RemoteModel {
        RemoteModel(id: id, displayName: displayName, created: createdAt.flatMap(Self.date),
                    maxInputTokens: maxInputTokens.flatMap(Self.known), maxOutputTokens: maxTokens.flatMap(Self.known),
                    readsImages: capabilities?.imageInput?.supported,
                    thinkingTypes: capabilities?.thinking?.types.map {
                        Set($0.supported.compactMap(ModelRequest.Thinking.init))
                    },
                    efforts: capabilities?.effort.map { Set($0.supported.compactMap(ModelRequest.Effort.init)) },
                    lifecycle: lifecycle.flatMap(RemoteModel.Lifecycle.init), shutDown: retiresAt.flatMap(Self.date))
    }

    /// A date, or nil for the epoch, which the Models API gives for a date it doesn't know.
    private static func date(_ text: String) -> Date? {
        let date = (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        return date.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }

    /// A count of tokens, or nil for none, which no model takes.
    private static func known(_ tokens: Int) -> Int? {
        tokens > 0 ? tokens : nil
    }
}

/// The capabilities Keeptide shapes a request by. The Models API gives the whole tree, each leaf saying whether it is
/// supported; the rest is left unread, and a capability that can't be read is unknown.
private struct Capabilities: Decodable {
    struct Leaf: Decodable {
        let supported: Bool?
    }

    struct Thinking: Decodable {
        let types: Levels?

        enum CodingKeys: String, CodingKey {
            case types
        }

        init(from decoder: any Decoder) throws {
            types = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Levels.self, forKey: .types)
        }
    }

    let imageInput: Leaf?
    let thinking: Thinking?
    let effort: Levels?

    enum CodingKeys: String, CodingKey {
        case imageInput = "image_input"
        case thinking
        case effort
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        imageInput = try? fields.decodeIfPresent(Leaf.self, forKey: .imageInput)
        thinking = try? fields.decodeIfPresent(Thinking.self, forKey: .thinking)
        effort = try? fields.decodeIfPresent(Levels.self, forKey: .effort)
    }
}

/// The levels under a capability by name, beside the capability's own `supported`: those that are supported. A level
/// given as null isn't; one that can't be read leaves the whole capability unknown.
private struct Levels: Decodable {
    let supported: Set<String>

    init(from decoder: any Decoder) throws {
        let levels = try decoder.container(keyedBy: Name.self)
        var supported: Set<String> = []
        for name in levels.allKeys where name.stringValue != "supported" {
            guard try !levels.decodeNil(forKey: name) else { continue }
            if try levels.decode(Capabilities.Leaf.self, forKey: name).supported == true {
                supported.insert(name.stringValue)
            }
        }
        self.supported = supported
    }

    private struct Name: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}
