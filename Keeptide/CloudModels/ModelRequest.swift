import Foundation

/// A provider's API key. It goes only into its request's headers; printed or dumped, it shows nothing of itself.
struct APIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var description: String { "API key" }

    var debugDescription: String { description }

    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What a model is asked to make, whatever the provider: the instructions, the content, and how the request is shaped
/// for the model, as its catalog entry says.
struct ModelRequest: Sendable {
    enum Input: Sendable {
        case text(String)
        /// An image already re-encoded on this Mac, as PNG or JPEG.
        case image(Data, mediaType: String)
    }

    /// How hard a model works at an answer, where it lets that be set. Each provider takes some of these, and a model
    /// some of those, as its catalog entry says.
    enum Effort: String, Sendable {
        /// OpenAI's way of answering without reasoning first. Not `none`, which `Optional.none` would shadow.
        case noReasoning = "none"
        case minimal, low, medium, high, xhigh, max
    }

    /// How a model thinks before it answers, where it lets that be set.
    enum Thinking: String, Sendable {
        case adaptive
        case disabled
        /// Claude Sonnet 5.5's way of turning thinking off.
        case betweenTools = "between_tools"
    }

    /// The provider's model identifier, such as "claude-haiku-5-5".
    var model: String
    /// The model as people see it, such as "Claude Haiku 5.5".
    var modelName: String
    var instructions: String
    var input: Input
    var maxOutputTokens: Int
    /// Nil leaves it to the model.
    var thinking: Thinking?
    /// Nil leaves it to the model.
    var effort: Effort?
}
