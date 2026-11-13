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
    /// Why the link's page isn't shown, when Keeptide never loads it.
    var note: String? = nil
    /// What was loaded of the link's page: its picture, and its title where the link has none of its own.
    var preview: LinkPreview? = nil
    var onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = preview?.image { LinkPicture(image: image) }

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

            if let note {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("LinkNotLoadedNote")
            }

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

    /// The link's own title, then its page's, each as a card shows it: on one line, without direction controls.
    private var displayTitle: String? {
        LinkPreview.shownTitle(title) ?? LinkPreview.shownTitle(preview?.title)
    }
}
