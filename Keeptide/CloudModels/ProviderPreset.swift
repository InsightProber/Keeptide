import Foundation

/// A model provider Keeptide knows, as data: where its API is, how a request proves who sends it, and the headers each
/// request carries. A provider that speaks a wire Keeptide already speaks needs only another preset.
struct ProviderPreset: Hashable, Sendable {
    enum ID: String, Sendable {
        case anthropic
        case openAI = "openai"
    }

    /// How requests and their streamed answers are shaped.
    enum Wire: Sendable {
        case anthropicMessages
        case openAIResponses
    }

    /// Where the API key goes: a bearer token, or a header of its own.
    enum Auth: Hashable, Sendable {
        case bearer
        case header(String)
    }

    let id: ID
    /// The provider as people see it, such as "Anthropic".
    let displayName: String
    let wire: Wire
    let baseURL: URL
    let auth: Auth
    let fixedHeaders: [String: String]

    static let anthropic = ProviderPreset(
        id: .anthropic, displayName: "Anthropic", wire: .anthropicMessages,
        baseURL: URL(string: "https://api.anthropic.com")!, auth: .header("x-api-key"),
        fixedHeaders: ["anthropic-version": "2026-10-21"]
    )

    static let openAI = ProviderPreset(
        id: .openAI, displayName: "OpenAI", wire: .openAIResponses,
        baseURL: URL(string: "https://api.openai.com")!, auth: .bearer, fixedHeaders: [:]
    )

    static let all: [ProviderPreset] = [.anthropic, .openAI]
}
