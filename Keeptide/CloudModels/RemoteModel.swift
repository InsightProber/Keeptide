import Foundation

/// A model a provider lists, with what the provider says of it. What it doesn't say is nil: not known, rather than not
/// supported.
struct RemoteModel: Equatable, Sendable {
    /// Where a model is in its provider's life for it.
    enum Lifecycle: String, Sendable {
        case active
        /// Still served, but closed to anyone who doesn't use it yet, and retiring.
        case deprecated
        case retired
    }

    /// The provider's model identifier, such as "claude-haiku-5-5".
    let id: String
    /// The model as the provider names it for people, such as "Claude Haiku 5.5".
    var displayName: String?
    var created: Date?
    var maxInputTokens: Int?
    var maxOutputTokens: Int?
    var readsImages: Bool?
    /// The ways of thinking the model takes that a request can ask for.
    var thinkingTypes: Set<ModelRequest.Thinking>?
    var efforts: Set<ModelRequest.Effort>?
    var lifecycle: Lifecycle?
    /// When the provider will stop serving the model, once it has said. A provider that gives only the day, as OpenAI
    /// does, gives the start of that day in UTC, so it is shown in UTC.
    var shutDown: Date?
}

/// An item of a provider's list that is nil when it can't be read, so that the rest of the list still can be.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
