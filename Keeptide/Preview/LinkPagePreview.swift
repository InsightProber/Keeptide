import AppKit
import SwiftUI

/// A link in quick access's preview: its page, loaded in a web view that keeps nothing, under a bar with the page's
/// address and Open in Browser. Until the page shows, and when it can't, the preview shows what is known of the page:
/// its picture and title.
struct LinkPagePreview: View {
    let url: URL
    let page: LinkWebView.Page
    /// The link's title as the clip has it, if any.
    let title: String?
    /// What was loaded of the page for its card.
    let preview: LinkPreview?
    var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @State private var phase: LinkWebView.Phase = .loading
    /// Where the page shown has moved to from the link, if it has.
    @State private var movedTo: URL?

    /// The address of the page shown: the link's until the page moves, and again when it can't be shown.
    private var address: URL { phase == .failed ? url : movedTo ?? url }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: address.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open in Browser") { openInBrowser(address) }
                    .controlSize(.small)
                    .accessibilityIdentifier("OpenLinkInBrowser")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                if phase == .failed {
                    LinkPageFallback(url: url, title: title, preview: preview)
                } else {
                    // Clear until the page shows, and out of VoiceOver's way; it takes no click until then either.
                    LinkWebView(page: page, onPhase: { phase = $0 }, onAddress: { movedTo = $0 },
                                openInBrowser: openInBrowser)
                        .opacity(phase == .loaded ? 1 : 0.0001)
                        .accessibilityHidden(phase != .loaded)
                    if phase == .loading {
                        LinkPageFallback(url: url, title: title, preview: preview)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("LinkPagePreview")
    }
}

/// What is known of a link's page without loading it: its picture, its title and its address.
struct LinkPageFallback: View {
    let url: URL
    let title: String?
    let preview: LinkPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = preview?.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
            if let shown = LinkPreview.shownTitle(title) ?? LinkPreview.shownTitle(preview?.title) {
                Text(verbatim: shown)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
            }
            Text(verbatim: url.absoluteString)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}
