import AppKit
import SwiftUI

/// The card that takes the preview card's place while a terminal command waits for a review: what to check, the
/// command with every line break, tab, control and invisible character made visible, and the buttons that confirm or
/// cancel it. Nothing is written or sent before it is confirmed. ⌘Return confirms and Escape cancels, as the panel
/// handles them; Return alone does neither.
struct CommandReviewView: View {
    let review: CommandReview
    /// What confirming does: "Confirm Paste into Terminal" or "Confirm Copy Command".
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    /// Keys pressed in the command's text that act on the panel, as in the preview's text.
    let onCommand: (QuickAccessCommand) -> Void

    init(review: CommandReview, confirmTitle: String, onConfirm: @escaping () -> Void,
         onCancel: @escaping () -> Void, onCommand: @escaping (QuickAccessCommand) -> Void = { _ in }) {
        self.review = review
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onCommand = onCommand
    }

    /// Said above a review that replaces one that no longer applied.
    static let renewalNotice = "The content or target changed. Review it and confirm again."

    /// "Review this 2-line command", or "Review this command" for one line that holds a character a terminal acts on.
    static func title(for review: CommandReview) -> String {
        review.command.lineCount > 1 ? "Review this \(review.command.lineCount)-line command" : "Review this command"
    }

    static func explanation(for review: CommandReview) -> String {
        review.command.lineCount > 1 ? "A terminal can run each line as soon as it arrives. Check every line."
            : "It contains control or invisible characters a terminal can act on."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(for: review))
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(Self.explanation(for: review))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if review.isRenewal {
                Label {
                    Text(Self.renewalNotice)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("CommandReviewNotice")
            }
            PreviewText(text: review.command.visibleText, monospaced: true, accessibilityName: "Command",
                        accessibilityID: "CommandReviewText", onCommand: onCommand)
                .frame(minHeight: 44)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            HStack(spacing: 16) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("CommandReviewCancel")
                // The key cap goes with the button it stands for, as Return's goes with its word in the toolbar.
                HStack(spacing: QuickAccessCopyHint.spacing) {
                    ReviewKeycap(symbol: "⌘⏎")
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("CommandReviewConfirm")
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CommandReview")
    }
}

/// ⌘⏎ drawn as the toolbar draws Return's key cap, beside the button it confirms with. VoiceOver reads the button.
private struct ReviewKeycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: ToolbarPalette.glyph))
            .padding(.horizontal, 4)
            .frame(minWidth: QuickAccessKeycap.minimumSize.width, minHeight: QuickAccessKeycap.minimumSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: ToolbarPalette.keycapEdge), lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }
}
