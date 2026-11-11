import Foundation

/// OpenAI's Responses API, streamed: what Keeptide sends for a request, and a generation's events from what comes back.
/// The instructions go in `instructions` and the content in a user message of its own, and OpenAI is asked not to keep
/// the response. Nothing else is sent: no sampling parameters, no tools, and nothing that identifies the person.
struct OpenAIResponsesSource: GenerationSource {
    let client: ModelClient
    let key: APIKey
    let request: ModelRequest

    private static let preset = ProviderPreset.openAI
    /// Failures in the stream for something the request asked, said in OpenAI's words.
    private static let requestProblemCodes: Set<String> = [
        "invalid_prompt", "data_residency_mismatch", "invalid_image", "invalid_image_format", "invalid_base64_image",
        "invalid_image_url", "image_too_small", "image_parse_error", "invalid_image_mode",
        "unsupported_image_media_type", "empty_image_file", "failed_to_download_image", "image_file_not_found",
    ]
    /// Failures for text or an image too large for the model.
    private static let tooLargeCodes: Set<String> = [
        "context_length_exceeded", "string_above_max_length", "image_too_large", "image_file_too_large",
    ]
    /// Failures that are OpenAI's policies declining the request, which end the answer as declined.
    private static let policyCodes: Set<String> = [
        "bio_policy", "image_content_policy_violation", "misalignment_policy_violation",
    ]

    func events() -> AsyncThrowingStream<GenerationEvent, any Error> {
        let source = self
        let request = request
        return ProviderStream.events(from: Self.preset, by: client, sending: { source.cloudRequest() },
                                     answer: Answer(request: request)) { status, headers, body in
            if Self.isPolicy((try? ProviderStream.decode(HTTPError.self, body).error)?.code) {
                return .declined(GenerationInfo(engine: request.modelName, model: request.model))
            }
            return .error(Self.failure(body, status: status, headers: headers, about: .generation(request)))
        }
    }

    /// Whether `code` is one of OpenAI's policies declining the request, which ends the answer as declined however it
    /// comes: as an HTTP error, a failed response or an error in the stream.
    fileprivate static func isPolicy(_ code: String?) -> Bool {
        code.map(policyCodes.contains) ?? false
    }

    /// The request as sent, with the key in its header.
    private func cloudRequest() -> CloudRequest? {
        let content: Content = switch request.input {
        case .text(let text): Content(type: "input_text", text: text)
        case .image(let data, let mediaType):
            Content(type: "input_image", imageUrl: "data:\(mediaType);base64,\(data.base64EncodedString())")
        }
        let body = Body(model: request.model, instructions: request.instructions,
                        input: [Message(content: [content])], maxOutputTokens: request.maxOutputTokens,
                        reasoning: request.effort.map { Reasoning(effort: $0.rawValue) })
        guard let encoded = ProviderStream.encode(body) else { return nil }
        return CloudRequest(method: .post, url: Self.preset.baseURL.appending(path: "v1/responses"),
                            headers: ProviderStream.headers(for: Self.preset, key: key), body: encoded)
    }

    /// An HTTP error as a person reads it, from its status, its `retry-after` header and the error in its body.
    fileprivate static func failure(_ body: Data, status: Int, headers: [String: String],
                                    about subject: ProviderStream.Subject) -> GenerationError {
        let error = try? ProviderStream.decode(HTTPError.self, body).error
        return failure(code: error?.code, message: error?.message ?? "", status: status,
                       retryAfter: ProviderStream.retryAfter(in: headers), about: subject)
    }

    /// An error OpenAI reported, by HTTP status or in the stream, as a person reads it. Its code tells most apart, and
    /// its status the rest.
    fileprivate static func failure(code: String?, message: String, status: Int?, retryAfter: Duration?,
                                    about subject: ProviderStream.Subject) -> GenerationError {
        let said = message.lowercased()
        if status == 401 || code == "invalid_api_key" {
            return GenerationError(kind: .keyRejected, message: "OpenAI didn't accept your API key.")
        }
        if code == "unsupported_country_region_territory" {
            return GenerationError(kind: .regionUnavailable, message: "OpenAI isn't available in your region.")
        }
        if code == "insufficient_quota" || code == "credit_balance_exhausted" {
            return GenerationError(kind: .noCredit, message: "Your OpenAI account has no remaining credit.")
        }
        if code == "organization_spend_limit_exceeded" {
            return GenerationError(kind: .noCredit, message: "Your OpenAI account reached its spending limit.")
        }
        if code == "project_spend_limit_exceeded" {
            return GenerationError(kind: .noCredit, message: "Your OpenAI project reached its spending limit.")
        }
        if code == "organization_usage_limit_exceeded" {
            return GenerationError(kind: .noCredit, message: "Your OpenAI account reached its usage limit.")
        }
        // Said by an HTTP error, or by an error in the stream once it has begun.
        if said.contains("must be verified") {
            let what = switch subject {
            case .generation: "this model"
            case .models: "its models"
            }
            return GenerationError(kind: .verificationRequired,
                                   message: "OpenAI needs to verify your organization before you can use \(what).")
        }
        // A 403 that isn't OpenAI's own, such as a proxy's page, is only turned away.
        if status == 403 && !message.isEmpty {
            let what = switch subject {
            case .generation: "this model"
            case .models: "OpenAI's models"
            }
            return GenerationError(kind: .accessDenied, message: "Your API key doesn't have access to \(what).")
        }
        if case .generation(let request) = subject {
            if status == 404 || code == "model_not_found" {
                return GenerationError(kind: .modelUnavailable,
                                       message: "\(request.modelName) isn't available with your API key.")
            }
            if status == 413 || isTooLarge(code) {
                return ProviderStream.tooLarge(request)
            }
            // More tokens than the account may send in a minute, which waiting doesn't help.
            if (status == 429 || code == "rate_limit_exceeded") && said.hasPrefix("request too large") {
                return tooLargeForAMinute(request)
            }
        }
        if status == 429 || code == "rate_limit_exceeded" || code == "slow_down" {
            return ProviderStream.rateLimited(retryAfter: retryAfter)
        }
        if status == 503 || code == "server_is_overloaded" {
            return GenerationError(kind: .overloaded, message: "OpenAI is busy right now. Try again.")
        }
        if (status ?? 0) >= 500 || code == "server_error" {
            return GenerationError(kind: .overloaded, message: "OpenAI couldn't answer just now. Try again.")
        }
        // A failure in the stream that Keeptide doesn't know ends the answer unexpectedly. Any other HTTP error is said
        // in OpenAI's words.
        if status == nil && !requestProblemCodes.contains(code ?? "") { return .interrupted }
        return ProviderStream.rejected(by: preset, saying: message)
    }

    private static func isTooLarge(_ code: String?) -> Bool {
        code.map(tooLargeCodes.contains) ?? false
    }

    private static func tooLargeForAMinute(_ request: ModelRequest) -> GenerationError {
        switch request.input {
        case .text:
            GenerationError(kind: .inputTooLarge,
                            message: "This text is too long for your OpenAI account's per-minute limit.")
        case .image:
            GenerationError(kind: .inputTooLarge,
                            message: "This image is too large for your OpenAI account's per-minute limit.")
        }
    }
}

/// What OpenAI's response has said so far, and the events each of its server-sent events makes. Each event is known by
/// the type in its data.
private struct Answer: ProviderAnswer {
    let request: ModelRequest
    /// Whether OpenAI said the response ended.
    private(set) var isOver = false
    /// What the response used, which OpenAI says only as it ends.
    private(set) var usage: GenerationUsage?
    /// Whether the model declined in words of its own, which a person isn't shown.
    private var refused = false

    init(request: ModelRequest) {
        self.request = request
    }

    mutating func read(_ event: ServerSentEvent) throws -> [GenerationEvent] {
        let data = Data(event.data.utf8)
        switch try ProviderStream.decode(Typed.self, data).type {
        case "response.created":
            return [.started(GenerationInfo(engine: request.modelName, model: request.model))]
        case "response.output_text.delta":
            let text = try ProviderStream.decode(TextDelta.self, data).delta
            return text.isEmpty ? [] : [.delta(text)]
        case "response.refusal.delta", "response.refusal.done":
            refused = true
            return []
        case "response.completed":
            let refused = refused
            return try end(data) { _ in refused ? .refused : .completed }
        case "response.incomplete":
            return try end(data) { response in
                switch response.incompleteDetails?.reason {
                case "max_output_tokens": .truncated
                case "content_filter": .refused
                // Reasons that a request without tools or steering doesn't meet.
                default: throw GenerationError.interrupted
                }
            }
        case "response.failed":
            let request = request
            return try end(data) { response in
                if OpenAIResponsesSource.isPolicy(response.error?.code) { return .refused }
                throw OpenAIResponsesSource.failure(code: response.error?.code, message: response.error?.message ?? "",
                                                    status: nil, retryAfter: nil, about: .generation(request))
            }
        case "error":
            // Its fields are at the top, or under `error`.
            let error = try ProviderStream.decode(ErrorEvent.self, data)
            let code = error.error?.code ?? error.code
            if OpenAIResponsesSource.isPolicy(code) {
                isOver = true
                return [.finished(.refused)]
            }
            throw OpenAIResponsesSource.failure(code: code, message: error.error?.message ?? error.message ?? "",
                                                status: nil, retryAfter: nil, about: .generation(request))
        default:
            // The response's progress, its items and parts, reasoning, and events Keeptide doesn't know.
            return []
        }
    }

    /// The response's last event: what it used, then how it ended, or the failure it ended with.
    private mutating func end(_ data: Data,
                              _ ending: (Ended.Response) throws -> FinishReason) throws -> [GenerationEvent] {
        isOver = true
        let response = try ProviderStream.decode(Ended.self, data).response
        usage = response.usage.map { GenerationUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) }
        return try [usage.map(GenerationEvent.usage), GenerationEvent.finished(ending(response))].compactMap { $0 }
    }
}

/// OpenAI's list of models: each one's identifier, when it was made, and when OpenAI will shut it down, once it has
/// said.
enum OpenAIModels {
    private static let preset = ProviderPreset.openAI

    static func list(by client: ModelClient, key: APIKey,
                     waiting wait: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        async throws -> [RemoteModel] {
        let request = CloudRequest(method: .get, url: preset.baseURL.appending(path: "v1/models"),
                                   headers: ProviderStream.headers(for: preset, key: key))
        let body = try await ProviderStream.fetch(request, from: preset, by: client, waiting: wait) {
            OpenAIResponsesSource.failure($2, status: $0, headers: $1, about: .models)
        }
        // A list that says it goes on, as OpenAI's other lists can, isn't the whole list.
        guard let list = try? JSONDecoder().decode(ModelList.self, from: body), list.hasMore != true else {
            throw GenerationError.interrupted
        }
        let models = list.data.compactMap { $0.value?.model }
        // A list none of whose models can be read would empty the catalog it stands in for.
        guard !models.isEmpty || list.data.isEmpty else { throw GenerationError.interrupted }
        var listed: Set<String> = []
        return models.filter { listed.insert($0.id).inserted }
    }
}

// MARK: The wire

private struct Body: Encodable {
    let model: String
    let instructions: String
    let input: [Message]
    let maxOutputTokens: Int
    let store = false
    let stream = true
    let reasoning: Reasoning?
}

private struct Message: Encodable {
    let role = "user"
    let content: [Content]
}

private struct Content: Encodable {
    let type: String
    var text: String?
    var imageUrl: String?
}

private struct Reasoning: Encodable {
    let effort: String
}

private struct Typed: Decodable {
    let type: String
}

private struct TextDelta: Decodable {
    let delta: String
}

private struct Usage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct Failure: Decodable {
    let code: String?
    let message: String?
}

private struct Ended: Decodable {
    struct Response: Decodable {
        struct Details: Decodable {
            let reason: String?
        }

        let usage: Usage?
        let incompleteDetails: Details?
        let error: Failure?
    }

    let response: Response
}

private struct ErrorEvent: Decodable {
    let code: String?
    let message: String?
    let error: Failure?
}

private struct HTTPError: Decodable {
    let error: Failure
}

private struct ModelList: Decodable {
    let data: [Lenient<ListedModel>]
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }
}

/// A model as OpenAI lists it. Only its identifier must be read; anything else that can't be is unknown.
private struct ListedModel: Decodable {
    let id: String
    /// Seconds since 1970.
    let created: Double?
    /// A day, such as "2026-12-01".
    let shutdownDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case created
        case shutdownDate = "shutdown_date"
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: fields, debugDescription: "No identifier")
        }
        created = try? fields.decodeIfPresent(Double.self, forKey: .created)
        shutdownDate = try? fields.decodeIfPresent(String.self, forKey: .shutdownDate)
    }

    var model: RemoteModel {
        RemoteModel(id: id, created: created.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                    shutDown: shutdownDate.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) })
    }
}
