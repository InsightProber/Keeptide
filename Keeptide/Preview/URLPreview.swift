import Foundation
import SwiftUI

enum URLPreviewPolicy {
    static func actionableURL(_ url: URL) -> URL? {
        let source = url.absoluteString
        guard !source.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        url.host != nil else { return nil }
        return url
    }
}

struct URLPreview: View {
    let title: String?
    let url: URL
    var onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let displayTitle {
                Text(verbatim: displayTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            Text(verbatim: url.absoluteString)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let actionableURL = URLPreviewPolicy.actionableURL(url) {
                Button {
                    onOpen(actionableURL)
                } label: {
                    Label("Open Link", systemImage: "arrow.up.right.square")
                }
                .accessibilityHint(Text(verbatim: "Opens the displayed address"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityElement(children: .contain)
    }

    private var displayTitle: String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
