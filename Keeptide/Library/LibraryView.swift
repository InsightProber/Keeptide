import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationSplitView {
            List(LibrarySection.allCases) { section in
                Label(section.title, systemImage: section.symbolName)
            }
            .navigationTitle("Library")
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            ContentUnavailableView {
                Label("No content yet", systemImage: "doc.text")
            } description: {
                Text("Snippet creation will be added in a later milestone.")
            }
            .navigationTitle("All Snippets")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .background(Color(nsColor: .textBackgroundColor))
        } detail: {
            ContentUnavailableView {
                Label("Select an item", systemImage: "doc.text")
            } description: {
                Text("Content details will appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
    case recentClips
    case allSnippets
    case favorites
    case uncategorized

    var id: Self { self }

    var title: String {
        switch self {
        case .recentClips: "Recent Clips"
        case .allSnippets: "All Snippets"
        case .favorites: "Favorites"
        case .uncategorized: "Uncategorized"
        }
    }

    var symbolName: String {
        switch self {
        case .recentClips: "clock"
        case .allSnippets: "doc.text"
        case .favorites: "star"
        case .uncategorized: "tray"
        }
    }
}
