import AppKit

/// The host's paste target. It takes ⌘V only while it has the keyboard focus, so a paste that reaches another
/// control is not counted, and it passes on the modifiers the key arrived with, so an extra ⇧ shows. The host has
/// no Edit menu; nothing else here answers ⌘V.
final class DirectPasteReceiverView: NSTextView {
    /// Answers a ⌘V with the text to insert, given the modifiers it arrived with.
    var onPaste: ((NSEvent.ModifierFlags) -> String)?

    private static let placeholder = "Click here, then paste from Keeptide"

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }
        let text = onPaste?(event.modifierFlags) ?? ""
        if !text.isEmpty { insertText(text, replacementRange: selectedRange()) }
        return true
    }

    /// NSTextView has no placeholder of its own; it is drawn where the first line starts while there is no text.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        NSAttributedString(string: Self.placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func accessibilityPlaceholderValue() -> String? { Self.placeholder }
}
