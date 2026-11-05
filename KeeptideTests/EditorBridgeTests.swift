import AppKit
import Observation
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

    func testLongBodyWrapsToTheVisibleViewportAndReflowsWithoutChangingEditingState() throws {
        let documentID = UUID()
        let (controller, window) = hostedController()
        defer { window.close() }
        let body = """
        Once you've decided, this long sentence must wrap inside the library detail column as the window changes size.
        同一段中文内容也必须跟随详情栏宽度换行，不能从窗口左边或右边被裁掉。
        unbroken-token-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
        """
        controller.update(documentID: documentID, text: body, isCode: false,
                          isEditable: true, focusRequest: 0)
        let editor = controller.textView
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 14, length: 9))
        editor.insertText("retained ", replacementRange: editor.selectedRange())
        let expectedText = editor.string
        let expectedSelection = editor.selectedRange()
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo, "The regression must preserve a real native undo entry across reflow")

        layout(window, controller: controller, width: 500)
        let wideFragments = try lineFragments(in: editor)
        assertFragmentsFitViewport(wideFragments, editor: editor)

        layout(window, controller: controller, width: 280)
        let narrowFragments = try lineFragments(in: editor)
        assertFragmentsFitViewport(narrowFragments, editor: editor)
        XCTAssertGreaterThan(narrowFragments.count, wideFragments.count,
                             "Narrowing the detail column must reflow the body instead of clipping it")

        layout(window, controller: controller, width: 640)
        let widenedFragments = try lineFragments(in: editor)
        assertFragmentsFitViewport(widenedFragments, editor: editor)
        XCTAssertLessThan(widenedFragments.count, narrowFragments.count)
        XCTAssertEqual(editor.string, expectedText)
        XCTAssertEqual(editor.selectedRange(), expectedSelection)
        XCTAssertTrue(undo.canUndo)
    }

    func testLoadedAndReplacementTextUseSemanticForegroundAcrossAppearances() throws {
        let (controller, window) = hostedController()
        defer { window.close() }
        let editor = controller.textView
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        window.appearance = light
        controller.update(documentID: UUID(), text: "Loaded in light appearance", isCode: false,
                          isEditable: true, focusRequest: 0)

        for appearance in [light, dark] {
            window.appearance = appearance
            window.contentView?.layoutSubtreeIfNeeded()
            assertSemanticTextColor(editor, appearance: appearance)
        }

        controller.update(documentID: UUID(), text: "let replacement = \"dark\"", isCode: true,
                          isEditable: true, focusRequest: 0)
        assertSemanticTextColor(editor, appearance: dark)
        XCTAssertEqual(editor.font,
                       NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
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

    func testConsumedBodyFocusDoesNotReplayWhenControllerIsRecreatedAndTitleOwnsFocus() async {
        let sessionID = UUID()
        let documentID = UUID()
        let owner = BodyFocusStateBox()
        let request = owner.state.request(
            sessionID: sessionID,
            documentID: documentID,
            generation: 1
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let title = NSTextField(frame: NSRect(x: 20, y: 270, width: 240, height: 24))
        container.addSubview(title)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let first = EditorTextController(onFocusAccepted: { acceptedDocumentID, acceptedRequest in
            owner.state.consume(
                sessionID: sessionID,
                documentID: acceptedDocumentID,
                request: acceptedRequest
            )
        })
        first.scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
        container.addSubview(first.scrollView)
        first.update(
            documentID: documentID,
            text: "body",
            isCode: false,
            isEditable: true,
            focusRequest: request
        )
        await first.settlePendingFocus()

        XCTAssertTrue(window.firstResponder === first.textView)
        XCTAssertEqual(owner.state.request(for: sessionID, documentID: documentID), 0)
        XCTAssertTrue(window.makeFirstResponder(title))
        let titleEditor = title.currentEditor()
        XCTAssertNotNil(titleEditor)

        first.scrollView.removeFromSuperview()
        let recreated = EditorTextController(onFocusAccepted: { _, _ in
            XCTFail("A consumed request must not be replayed by a recreated controller")
        })
        recreated.scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
        container.addSubview(recreated.scrollView)
        recreated.update(
            documentID: documentID,
            text: "body",
            isCode: false,
            isEditable: true,
            focusRequest: owner.state.request(for: sessionID, documentID: documentID)
        )
        await recreated.settlePendingFocus()

        XCTAssertTrue(window.firstResponder === titleEditor)
        XCTAssertFalse(window.firstResponder === recreated.textView)
    }

    func testDeferredBodyFocusReaderObservesNewRequestAndConsumption() async {
        let state = BodyFocusRequestState()
        let sessionID = UUID()
        let documentID = UUID()
        // SwiftUI stores column-builder closures before the asynchronous new
        // snippet operation issues its focus request.
        let readFromDeferredColumn = { [state] in
            state.request(for: sessionID, documentID: documentID)
        }
        XCTAssertEqual(readFromDeferredColumn(), 0)
        let requested = expectation(description: "request invalidates the column")
        withObservationTracking {
            _ = readFromDeferredColumn()
        } onChange: {
            requested.fulfill()
        }
        let request = state.request(sessionID: sessionID, documentID: documentID, generation: 1)
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(readFromDeferredColumn(), request)

        let consumed = expectation(description: "consumption invalidates the column")
        withObservationTracking {
            _ = readFromDeferredColumn()
        } onChange: {
            consumed.fulfill()
        }
        XCTAssertTrue(state.consume(sessionID: sessionID, documentID: documentID, request: request))
        await fulfillment(of: [consumed], timeout: 1)
        XCTAssertEqual(readFromDeferredColumn(), 0)
    }

    func testStaleBodyFocusAcknowledgementCannotConsumeANewerRequest() {
        let firstSessionID = UUID()
        let firstDocumentID = UUID()
        let secondSessionID = UUID()
        let secondDocumentID = UUID()
        let state = BodyFocusRequestState()
        let first = state.request(
            sessionID: firstSessionID,
            documentID: firstDocumentID,
            generation: 4
        )
        let second = state.request(
            sessionID: secondSessionID,
            documentID: secondDocumentID,
            generation: 5
        )

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertFalse(state.consume(
            sessionID: firstSessionID,
            documentID: firstDocumentID,
            request: first
        ))
        XCTAssertFalse(state.consume(
            sessionID: secondSessionID,
            documentID: firstDocumentID,
            request: second
        ))
        XCTAssertEqual(state.request(for: secondSessionID, documentID: secondDocumentID), second)
        XCTAssertTrue(state.isCurrent(
            sessionID: secondSessionID,
            documentID: secondDocumentID,
            request: second,
            generation: 5
        ))
        XCTAssertFalse(state.isCurrent(
            sessionID: secondSessionID,
            documentID: secondDocumentID,
            request: second,
            generation: 4
        ))
        XCTAssertTrue(state.consume(
            sessionID: secondSessionID,
            documentID: secondDocumentID,
            request: second
        ))
        XCTAssertEqual(state.request(for: secondSessionID, documentID: secondDocumentID), 0)
        XCTAssertEqual(
            state.request(sessionID: secondSessionID, documentID: UUID(), generation: 6),
            3,
            "Consuming a request must not reset the monotonic request counter"
        )
    }

    func testFocusAcknowledgementRequiresAttachmentEditableStateAndCurrentIntent() async {
        let documentID = UUID()
        var accepted: [(UUID, Int)] = []
        let controller = EditorTextController(onFocusAccepted: { accepted.append(($0, $1)) })
        let intent = FocusIntentBox()
        controller.update(
            documentID: documentID,
            text: "body",
            isCode: false,
            isEditable: true,
            focusRequest: 1,
            shouldFocus: { intent.isCurrent }
        )
        XCTAssertTrue(accepted.isEmpty, "A request cannot be acknowledged before window attachment")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(nil))
        await controller.settlePendingFocus()

        XCTAssertTrue(accepted.isEmpty, "A stale intent rejected by shouldFocus must not be acknowledged")
        XCTAssertFalse(window.firstResponder === controller.textView)

        intent.isCurrent = true
        XCTAssertTrue(window.makeFirstResponder(nil))
        controller.update(
            documentID: documentID,
            text: "body",
            isCode: false,
            isEditable: false,
            focusRequest: 2,
            shouldFocus: { intent.isCurrent }
        )
        await controller.settlePendingFocus()

        XCTAssertTrue(accepted.isEmpty, "A read-only editor must not acknowledge body focus")
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

        let bodyFocusIntent = FocusIntentBox(isCurrent: true)
        controller.update(documentID: UUID(), text: "", isCode: false,
                          isEditable: true, focusRequest: 1,
                          shouldFocus: { bodyFocusIntent.isCurrent })
        bodyFocusIntent.isCurrent = false
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

    func testLibrarySearchFocusRequestWorksAcrossToolbarWindowAttachmentAndOnlyOnce() async {
        let controller = LibrarySearchController()
        controller.update(text: "", focusRequest: 1)
        XCTAssertNil(controller.searchField.window)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.searchField
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await controller.settlePendingFocus()
        XCTAssertTrue(window.firstResponder === controller.searchField.currentEditor())

        XCTAssertTrue(window.makeFirstResponder(nil))
        controller.update(text: "", focusRequest: 1)
        await controller.settlePendingFocus()
        XCTAssertFalse(window.firstResponder === controller.searchField.currentEditor())
    }

    func testConsumedLibrarySearchFocusDoesNotReplayAfterControllerRecreation() async {
        let owner = SearchFocusStateBox()
        let intent = owner.state.request(1, generation: 1)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let title = NSTextField(frame: NSRect(x: 20, y: 105, width: 240, height: 24))
        container.addSubview(title)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let first = LibrarySearchController()
        first.searchField.frame = NSRect(x: 20, y: 60, width: 240, height: 24)
        first.update(
            text: "",
            focusRequest: intent.request,
            shouldFocus: { owner.state.isCurrent(intent, generation: 1) },
            onFocusAccepted: { request in
                guard request == intent.request else { return }
                owner.state.consume(intent, generation: 1)
            }
        )
        container.addSubview(first.searchField)
        await first.settlePendingFocus()

        XCTAssertTrue(window.firstResponder === first.searchField.currentEditor())
        XCTAssertNil(owner.state.pending)
        XCTAssertTrue(window.makeFirstResponder(title))
        let titleEditor = title.currentEditor()
        XCTAssertNotNil(titleEditor)

        first.searchField.removeFromSuperview()
        let recreated = LibrarySearchController()
        recreated.searchField.frame = NSRect(x: 20, y: 60, width: 240, height: 24)
        recreated.update(
            text: "",
            focusRequest: owner.state.pending?.request ?? 0,
            shouldFocus: { false },
            onFocusAccepted: { _ in
                XCTFail("A consumed search intent must not replay after controller recreation")
            }
        )
        container.addSubview(recreated.searchField)
        await recreated.settlePendingFocus()

        XCTAssertTrue(window.firstResponder === titleEditor)
        XCTAssertFalse(window.firstResponder === recreated.searchField.currentEditor())
    }

    func testNewerFocusIntentInvalidatesObsoleteSearchAndLateAckCannotConsumeNewSearch() {
        var state = SearchFocusRequestState()
        let obsoleteSearch = state.request(1, generation: 1)

        state.invalidate() // The next focus generation belongs to Cmd-N.
        XCTAssertFalse(state.isCurrent(obsoleteSearch, generation: 2))
        XCTAssertFalse(state.consume(obsoleteSearch, generation: 2))
        XCTAssertNil(state.pending)

        let currentSearch = state.request(2, generation: 3)
        XCTAssertFalse(state.consume(obsoleteSearch, generation: 3))
        XCTAssertEqual(state.pending, currentSearch)
        XCTAssertTrue(state.isCurrent(currentSearch, generation: 3))
        XCTAssertFalse(state.consume(currentSearch, generation: 2))
        XCTAssertEqual(state.pending, currentSearch)
        XCTAssertTrue(state.consume(currentSearch, generation: 3))
        XCTAssertNil(state.pending)
    }

    #if !SWIFT_PACKAGE
    func testLibraryWindowCommandsPublishAndFenceSearchFocusAcrossNewSnippetOrdering() async throws {
        let commands = LibraryWindowCommands()
        let published = expectation(description: "pending search focus changed")
        withObservationTracking {
            _ = commands.pendingSearchFocus
        } onChange: {
            published.fulfill()
        }

        commands.requestSearch()
        await fulfillment(of: [published], timeout: 1)
        let first = try XCTUnwrap(commands.pendingSearchFocus)
        XCTAssertEqual(first.request, 1)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(commands.searchRequest, 1)
        XCTAssertEqual(commands.focusGeneration, 1)

        commands.requestNewSnippet()
        XCTAssertNil(commands.pendingSearchFocus)
        XCTAssertEqual(commands.focusGeneration, 2)
        XCTAssertEqual(commands.newSnippetFocusGeneration, 2)
        XCTAssertEqual(commands.newSnippetRequest, 1)

        commands.requestSearch()
        let second = try XCTUnwrap(commands.pendingSearchFocus)
        XCTAssertEqual(second.request, 2)
        XCTAssertEqual(second.generation, 3)
        XCTAssertEqual(commands.searchRequest, 2)
        XCTAssertEqual(commands.focusGeneration, 3)

        XCTAssertFalse(commands.consumeSearchFocus(first))
        XCTAssertEqual(commands.pendingSearchFocus, second)
        XCTAssertTrue(commands.consumeSearchFocus(second))
        XCTAssertNil(commands.pendingSearchFocus)
    }
    #endif

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

    private func layout(_ window: NSWindow, controller: EditorTextController, width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 320))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
    }

    private func lineFragments(in editor: NSTextView) throws -> [NSRect] {
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        let textContainer = try XCTUnwrap(editor.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var fragments: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            fragments.append(usedRect)
        }
        XCTAssertFalse(fragments.isEmpty)
        return fragments
    }

    private func assertFragmentsFitViewport(
        _ fragments: [NSRect], editor: NSTextView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let textContainer = editor.textContainer else {
            return XCTFail("Missing native text container", file: file, line: line)
        }
        let viewportWidth = editor.enclosingScrollView?.contentSize.width ?? 0
        XCTAssertGreaterThan(viewportWidth, 0, file: file, line: line)
        XCTAssertEqual(editor.frame.width, viewportWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(textContainer.size.width, viewportWidth - editor.textContainerInset.width * 2,
                       accuracy: 1, file: file, line: line)
        for fragment in fragments {
            XCTAssertLessThanOrEqual(fragment.maxX, textContainer.size.width + 1,
                                     "Every rendered line must remain inside the visible detail width",
                                     file: file, line: line)
        }
    }

    private func assertSemanticTextColor(
        _ editor: NSTextView, appearance: NSAppearance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !editor.string.isEmpty else {
            return XCTFail("The color assertion requires loaded text", file: file, line: line)
        }
        let glyphColor = (editor.textStorage?.attribute(
            .foregroundColor, at: 0, effectiveRange: nil
        ) as? NSColor) ?? editor.textColor
        let typingColor = editor.typingAttributes[.foregroundColor] as? NSColor

        XCTAssertEqual(editor.textColor, .textColor, file: file, line: line)
        XCTAssertEqual(glyphColor, .textColor, file: file, line: line)
        XCTAssertEqual(typingColor, .textColor, file: file, line: line)
        XCTAssertEqual(resolvedRGBA(glyphColor, appearance: appearance),
                       resolvedRGBA(.textColor, appearance: appearance),
                       "Existing glyphs must follow the effective light or dark appearance",
                       file: file, line: line)
    }

    private func resolvedRGBA(_ color: NSColor?, appearance: NSAppearance) -> [CGFloat] {
        var components: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            guard let converted = color?.usingColorSpace(.deviceRGB) else { return }
            components = [converted.redComponent, converted.greenComponent,
                          converted.blueComponent, converted.alphaComponent]
        }
        return components
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

@MainActor
private final class BodyFocusStateBox {
    let state = BodyFocusRequestState()
}

@MainActor
private final class FocusIntentBox {
    var isCurrent: Bool

    init(isCurrent: Bool = false) {
        self.isCurrent = isCurrent
    }
}

@MainActor
private final class SearchFocusStateBox {
    var state = SearchFocusRequestState()
}
