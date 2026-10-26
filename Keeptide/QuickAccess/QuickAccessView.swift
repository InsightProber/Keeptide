import AppKit
import SwiftUI

struct QuickAccessView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
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
                Text("Keeptide is ready for content when recording is added in a later milestone.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct QuickAccessSearchField: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusingSearchField {
        let field = FocusingSearchField()
        field.placeholderString = "Search Keeptide"
        field.isBordered = false
        field.focusRingType = .default
        field.font = .preferredFont(forTextStyle: .title3)
        field.setAccessibilityIdentifier("Quick access query")
        return field
    }

    func updateNSView(_ nsView: FocusingSearchField, context: Context) {}
}

private final class FocusingSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
