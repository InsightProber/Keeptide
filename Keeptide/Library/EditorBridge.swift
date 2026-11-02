import AppKit
import SwiftUI

/// Native text editing with document-scoped selection, undo and composition.
struct EditorBridge: NSViewRepresentable {
    let documentID: UUID
    let text: String
    let isCode: Bool
    let isEditable: Bool
    let focusRequest: Int
    let onChange: @MainActor (String, Bool) -> Void
    let onFocusLost: @MainActor () -> Void

    func makeCoordinator() -> EditorTextController {
        EditorTextController(onChange: onChange, onFocusLost: onFocusLost)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            documentID: documentID,
            text: text,
            isCode: isCode,
            isEditable: isEditable,
            focusRequest: focusRequest
        )
    }
}

@MainActor
final class EditorTextController: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: NSTextView

    private let onChange: @MainActor (String, Bool) -> Void
    private let onFocusLost: @MainActor () -> Void
    private var currentDocumentID: UUID?
    private var currentFocusRequest = 0
    private var pendingFocusRequest: Int?
    private var isCode = false
    private var suppressesChanges = false
    private var lastReportedChange: ReportedChange?

    init(
        onChange: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
        onFocusLost: @escaping @MainActor () -> Void = {}
    ) {
        self.onChange = onChange
        self.onFocusLost = onFocusLost
        scrollView = NSScrollView()
        textView = EditorTextView(frame: .zero)
        super.init()
        (textView as? EditorTextView)?.onWindowAttachment = { [weak self] in
            self?.applyPendingFocusIfPossible()
        }
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFindPanel = false
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Snippet body")
        textView.delegate = self
    }

    func update(documentID: UUID, text: String, isCode: Bool, isEditable: Bool, focusRequest: Int) {
        let changesDocument = currentDocumentID != documentID
        self.isCode = isCode
        textView.isEditable = isEditable
        textView.isSelectable = true

        if changesDocument {
            currentDocumentID = documentID
            replaceText(text, selection: NSRange(location: 0, length: 0))
            textView.undoManager?.removeAllActions()
            lastReportedChange = nil
        } else if textView.string != text, !textView.hasMarkedText() {
            replaceText(text, selection: textView.selectedRange())
        }
        applyTypography(isCode: isCode)

        if focusRequest != currentFocusRequest {
            currentFocusRequest = focusRequest
            pendingFocusRequest = focusRequest > 0 && isEditable ? focusRequest : nil
        }
        applyPendingFocusIfPossible()
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressesChanges else { return }
        let change = ReportedChange(text: textView.string, isComposing: textView.hasMarkedText())
        guard lastReportedChange != change else { return }
        lastReportedChange = change
        onChange(change.text, change.isComposing)
    }

    func textDidEndEditing(_ notification: Notification) {
        onFocusLost()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertTab(_:)), isCode, textView.isEditable else {
            return false
        }
        textView.insertText("\t", replacementRange: textView.selectedRange())
        return true
    }

    private func replaceText(_ text: String, selection: NSRange) {
        suppressesChanges = true
        defer { suppressesChanges = false }
        let undo = textView.undoManager
        undo?.disableUndoRegistration()
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: textView.string.utf16.count),
            with: text
        )
        undo?.enableUndoRegistration()
        let length = text.utf16.count
        let location = min(selection.location, length)
        let selectedLength = min(selection.length, length - location)
        textView.setSelectedRange(NSRange(location: location, length: selectedLength))
    }

    private func applyTypography(isCode: Bool) {
        let font = isCode
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.preferredFont(forTextStyle: .body)
        textView.font = font
        textView.typingAttributes[.font] = font
    }

    private func applyPendingFocusIfPossible() {
        guard pendingFocusRequest != nil,
              textView.isEditable,
              textView.window?.makeFirstResponder(textView) == true else { return }
        pendingFocusRequest = nil
    }
}

private final class EditorTextView: NSTextView {
    var onWindowAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onWindowAttachment?()
    }
}

private struct ReportedChange: Equatable {
    let text: String
    let isComposing: Bool
}
