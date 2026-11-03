import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class EditorBridgeTests: XCTestCase {
    func testEditorUsesNativePlainTextUndoAndLocalFindBarConfiguration() {
        let controller = EditorTextController()
        let editor = controller.textView

        XCTAssertFalse(editor.isRichText)
        XCTAssertFalse(editor.importsGraphics)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertTrue(editor.usesFindBar)
        XCTAssertFalse(editor.usesFindPanel)
        XCTAssertTrue(editor.isIncrementalSearchingEnabled)
        XCTAssertTrue(controller.scrollView.documentView === editor)
    }

    func testTextChangesReportMarkedTextUntilCompositionCommits() {
        var changes: [(String, Bool)] = []
        let controller = EditorTextController { changes.append(($0, $1)) }
        let editor = controller.textView

        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        editor.insertText("中", replacementRange: editor.markedRange())
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))

        XCTAssertEqual(changes.map(\.0), ["zhong", "中"])
        XCTAssertEqual(changes.map(\.1), [true, false])
    }

    func testSameDocumentRefreshDoesNotReplaceMarkedTextSelectionOrUndoHistory() throws {
        let documentID = UUID()
        let (controller, window) = hostedController()
        defer { window.close() }
        controller.update(documentID: documentID, text: "committed", isCode: false,
                          isEditable: true, focusRequest: 0)
        let editor = controller.textView
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 4, length: 3))
        let selected = editor.selectedRange()
        let marked = editor.markedRange()
        let undo = try XCTUnwrap(editor.undoManager)
        let couldUndo = undo.canUndo

        controller.update(documentID: documentID, text: "stale model echo", isCode: false,
                          isEditable: true, focusRequest: 0)

        // Replacing UTF-16 range 4..<7 in "committed" removes "itt".
        XCTAssertEqual(editor.string, "comm候选ed")
        XCTAssertEqual(editor.selectedRange(), selected)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(undo.canUndo, couldUndo)
    }

    func testChangingDocumentResetsContentSelectionAndUndoWithoutImplicitFocus() throws {
        let first = UUID()
        let second = UUID()
        let (controller, window) = hostedController()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(nil))
        controller.update(documentID: first, text: "first", isCode: false,
                          isEditable: true, focusRequest: 0)
        let editor = controller.textView
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        controller.update(documentID: second, text: "second", isCode: false,
                          isEditable: false, focusRequest: 0)

        XCTAssertEqual(editor.string, "second")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
        XCTAssertFalse(window.firstResponder === editor)
    }

    func testFocusChangesOnlyForANewExplicitFocusRequest() async {
        let documentID = UUID()
        let (controller, window) = hostedController()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(nil))
        controller.update(documentID: documentID, text: "text", isCode: false,
                          isEditable: true, focusRequest: 0)
        XCTAssertFalse(window.firstResponder === controller.textView)

        controller.update(documentID: documentID, text: "text", isCode: false,
                          isEditable: true, focusRequest: 1)
        await controller.settlePendingFocus()
        XCTAssertTrue(window.firstResponder === controller.textView)

        XCTAssertTrue(window.makeFirstResponder(nil))
        controller.update(documentID: documentID, text: "text", isCode: false,
                          isEditable: true, focusRequest: 1)
        await controller.settlePendingFocus()
        XCTAssertFalse(window.firstResponder === controller.textView)
    }

    func testFocusRequestMadeBeforeAttachmentIsAppliedWhenTheEditorJoinsAWindow() async {
        let controller = EditorTextController()
        controller.update(documentID: UUID(), text: "text", isCode: false,
                          isEditable: true, focusRequest: 1)
        XCTAssertNil(controller.textView.window)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        await controller.settlePendingFocus()
        XCTAssertTrue(window.firstResponder === controller.textView)
    }

    func testDeferredFocusIsCancelledWhenTheDocumentChangesOrBecomesReadOnly() async {
        let controller = EditorTextController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(nil))

        controller.update(documentID: UUID(), text: "first", isCode: false,
                          isEditable: true, focusRequest: 1)
        controller.update(documentID: UUID(), text: "second", isCode: false,
                          isEditable: false, focusRequest: 1)
        await controller.settlePendingFocus()

        XCTAssertFalse(window.firstResponder === controller.textView)
    }

    func testDeferredBodyFocusDoesNotStealFocusFromANewerSearchIntent() async {
        let controller = EditorTextController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.addSubview(controller.scrollView)
        let searchField = NSSearchField(frame: NSRect(x: 20, y: 270, width: 220, height: 24))
        container.addSubview(searchField)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        var bodyFocusIsCurrent = true
        controller.update(documentID: UUID(), text: "", isCode: false,
                          isEditable: true, focusRequest: 1,
                          shouldFocus: { bodyFocusIsCurrent })
        bodyFocusIsCurrent = false
        XCTAssertTrue(window.makeFirstResponder(searchField))

        await controller.settlePendingFocus()

        XCTAssertTrue(window.firstResponder === searchField.currentEditor())
        XCTAssertFalse(window.firstResponder === controller.textView)
    }

    func testResettingFocusRequestCancelsPendingFocusForTheSameDocument() async {
        let documentID = UUID()
        let (controller, window) = hostedController()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(nil))

        controller.update(documentID: documentID, text: "", isCode: false,
                          isEditable: true, focusRequest: 1)
        controller.update(documentID: documentID, text: "", isCode: false,
                          isEditable: true, focusRequest: 0)

        await controller.settlePendingFocus()

        XCTAssertFalse(window.firstResponder === controller.textView)
    }

    func testCodeEditorInsertsTabAndDisablesTypographicSubstitution() {
        let controller = EditorTextController()
        controller.update(documentID: UUID(), text: "let value = 1", isCode: true,
                          isEditable: true, focusRequest: 0)
        let editor = controller.textView
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))

        XCTAssertTrue(controller.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(editor.string, "let value = 1\t")
        XCTAssertEqual(editor.font, NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
    }

    func testPlainTextEditorLeavesTabForNativeFocusTraversal() {
        let controller = EditorTextController()
        controller.update(documentID: UUID(), text: "prompt", isCode: false,
                          isEditable: true, focusRequest: 0)

        XCTAssertFalse(controller.textView(controller.textView,
                                           doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(controller.textView.string, "prompt")
    }

    func testFindControllerUsesTheEditorsLocalFindInterfaceAndEscapeHidesIt() {
        let editor = RecordingFindTextView()
        editor.usesFindBar = true
        let finder = DocumentFindController(textView: editor)

        finder.showFind()
        XCTAssertTrue(finder.isFindInterfaceVisible)
        XCTAssertEqual(editor.actions, [.showFindInterface])

        finder.hideFind()
        XCTAssertFalse(finder.isFindInterfaceVisible)
        XCTAssertEqual(editor.actions, [.showFindInterface, .hideFindInterface])
    }

    func testFocusLossCallbackDoesNotFireForOrdinaryTextChanges() {
        var focusLosses = 0
        let controller = EditorTextController(onFocusLost: { focusLosses += 1 })

        controller.textDidChange(Notification(name: NSText.didChangeNotification,
                                              object: controller.textView))
        XCTAssertEqual(focusLosses, 0)
        controller.textDidEndEditing(Notification(name: NSText.didEndEditingNotification,
                                                  object: controller.textView))
        XCTAssertEqual(focusLosses, 1)
    }

    func testLibrarySearchFocusRequestWorksAcrossToolbarWindowAttachmentAndOnlyOnce() {
        let controller = LibrarySearchController()
        controller.update(text: "", focusRequest: 1)
        XCTAssertNil(controller.searchField.window)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.searchField
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.firstResponder === controller.searchField.currentEditor())

        XCTAssertTrue(window.makeFirstResponder(nil))
        controller.update(text: "", focusRequest: 1)
        XCTAssertFalse(window.firstResponder === controller.searchField.currentEditor())
    }

    func testLibrarySearchReportsNativeTextChangesWithoutEchoingProgrammaticUpdates() {
        var changes: [String] = []
        let controller = LibrarySearchController(onChange: { changes.append($0) })
        controller.update(text: "initial", focusRequest: 0)
        XCTAssertEqual(controller.searchField.stringValue, "initial")
        XCTAssertEqual(changes, [])

        controller.searchField.stringValue = "合成 query"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )

        XCTAssertEqual(changes, ["合成 query"])
    }

    func testLibrarySearchDoesNotReplaceMarkedTextDuringExternalQueryRefresh() throws {
        let controller = LibrarySearchController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.searchField
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(controller.searchField))

        let editor = try XCTUnwrap(controller.searchField.currentEditor() as? NSTextView)
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedText = controller.searchField.stringValue

        controller.update(text: "stale external query", focusRequest: 0)

        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(controller.searchField.stringValue, markedText)
    }

    private func hostedController() -> (EditorTextController, NSWindow) {
        let controller = EditorTextController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        window.makeKeyAndOrderFront(nil)
        return (controller, window)
    }

}

private final class RecordingFindTextView: NSTextView {
    var actions: [NSTextFinder.Action] = []

    override func performFindPanelAction(_ sender: Any?) {
        guard let value = sender as? NSNumber,
              let action = NSTextFinder.Action(rawValue: value.intValue) else { return }
        actions.append(action)
    }
}
