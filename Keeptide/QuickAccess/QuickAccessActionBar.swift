import SwiftUI

/// The bottom bar: the primary action on the left, Preview and Actions on the right.
/// Shortcuts are hints; every action works with the pointer.
struct QuickAccessActionBar: View {
    let canAct: Bool
    let canPreview: Bool
    let isPreviewExpanded: Bool
    let failure: PasteRefusal?
    let primary: () -> Void
    let togglePreview: () -> Void
    let openActions: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: primary) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(!canAct)
            .accessibilityIdentifier("QuickAccessPrimaryAction")
            if let failure {
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .accessibilityIdentifier("QuickAccessFailure")
            }
            Spacer(minLength: 8)
            Button(isPreviewExpanded ? "Hide Preview" : "Preview", action: togglePreview)
                .disabled(!canPreview)
                .accessibilityIdentifier("QuickAccessPreviewButton")
            Button("Actions", action: openActions)
                .accessibilityIdentifier("QuickAccessActionsButton")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.regularMaterial)
    }
}

extension PasteRefusal {
    var message: String {
        switch self {
        case .stale: "The results changed. Select the item again."
        case .contentUnavailable: "This item changed or is no longer available."
        case .noPlainText: "This item has no plain text."
        case .writeFailed: "Couldn't write to the clipboard."
        }
    }
}
