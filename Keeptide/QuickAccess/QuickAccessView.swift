import AppKit
import SwiftUI

struct QuickAccessView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                QuickAccessSearchField()
                    .accessibilityLabel("Quick access query")
                    .accessibilityIdentifier("Quick access query")
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            .background(.regularMaterial)

            Divider()

            ContentUnavailableView {
                Label("No content yet", systemImage: "doc.on.clipboard")
            } description: {
                Text("Your saved content will appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct QuickAccessSearchField: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FocusingSearchField {
        let field = FocusingSearchField()
        field.placeholderString = "Search Keeptide"
        field.focusRingType = .default
        field.font = .preferredFont(forTextStyle: .title3)
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("Quick access query")
        return field
    }

    func updateNSView(_ nsView: FocusingSearchField, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let searchField = control as? NSSearchField else {
                return false
            }

            switch QuickAccessEscapePolicy.action(
                hasMarkedText: textView.hasMarkedText(),
                hasQuery: !searchField.stringValue.isEmpty
            ) {
            case .passToInputMethod:
                return false
            case .clearQuery:
                searchField.stringValue = ""
                return true
            case .closePanel:
                searchField.window?.orderOut(nil)
                return true
            }
        }
    }
}

private final class FocusingSearchField: NSSearchField {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        focusIfWindowIsKey()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        focusIfWindowIsKey()
    }

    private func focusIfWindowIsKey() {
        guard window?.isKeyWindow == true else { return }
        window?.makeFirstResponder(self)
    }
}

enum QuickAccessEscapeAction: Equatable {
    case passToInputMethod
    case clearQuery
    case closePanel
}

enum QuickAccessEscapePolicy {
    static func action(hasMarkedText: Bool, hasQuery: Bool) -> QuickAccessEscapeAction {
        if hasMarkedText {
            return .passToInputMethod
        }
        if hasQuery {
            return .clearQuery
        }
        return .closePanel
    }
}
