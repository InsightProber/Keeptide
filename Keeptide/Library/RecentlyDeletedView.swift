import SwiftUI

/// Deleted clips and snippets, one row per deleted facet. A row is selected by its exact facet, so an item whose
/// clip and snippet were both deleted has two rows, and Recover acts on the one selected. The actions are in the
/// toolbar, the Item menu and a row's context menu; the library asks before deleting permanently.
struct RecentlyDeletedView: View {
    @Bindable var maintenance: LibraryMaintenance
    /// The library's search, which here matches deleted items' titles.
    let query: String
    @Binding var selection: DeletedFacetIdentity?
    let onRecover: (TrashFacetSnapshot) -> Void
    let onDeletePermanently: (TrashFacetSnapshot) -> Void

    var body: some View {
        Group {
            if maintenance.isWorking, maintenance.trash.isEmpty {
                ProgressView("Loading Recently Deleted…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRows.isEmpty {
                ContentUnavailableView {
                    Label(
                        isSearching ? "No Deleted Items Match" : "Nothing Recently Deleted",
                        systemImage: "trash"
                    )
                } description: {
                    Text(
                        isSearching
                            ? "Deleted items are searched by title only."
                            : "Deleted clips and snippets are kept for \(RecentlyDeletedPresentation.days) days."
                    )
                }
                .accessibilityIdentifier("RecentlyDeletedEmptyState")
            } else {
                List(selection: $selection) {
                    Section {
                        ForEach(filteredRows, id: \.identity) { row in
                            RecentlyDeletedRow(row: row)
                                .tag(row.identity)
                                .contextMenu {
                                    Button("Recover") { onRecover(row) }
                                        .disabled(!row.canRestore || maintenance.isWorking)
                                    Button("Delete Permanently…", role: .destructive) { onDeletePermanently(row) }
                                        .disabled(maintenance.isWorking)
                                }
                        }
                    } header: {
                        Text(RecentlyDeletedPresentation.retentionNote)
                            .accessibilityIdentifier("RecentlyDeletedRetention")
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("RecentlyDeletedList")
            }
        }
        .task { await maintenance.refreshTrash() }
    }

    private var filteredRows: [TrashFacetSnapshot] {
        RecentlyDeletedPresentation.rows(maintenance.trash, matching: query)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A deleted facet in the other lists' row style: its title, then when it was deleted and whether it was a clip
/// or a snippet, and when it goes for good once that is a day or less away.
private struct RecentlyDeletedRow: View {
    let row: TrashFacetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: RecentlyDeletedPresentation.symbolName(row.identity.facet))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.isEmpty ? "Untitled" : row.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(RecentlyDeletedPresentation.metadata(for: row))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("RecentlyDeletedRow")
    }
}

enum RecentlyDeletedPresentation {
    static var days: Int { Int(DeletionWindow.duration / 86_400) }

    /// Said once, over the list.
    static var retentionNote: String {
        "Deleted items are kept for \(days) days, then removed permanently."
    }

    /// The deleted items whose titles contain `query`, ignoring case and surrounding spaces; all of them without one.
    /// Deleted items are not in the search index, so their titles are matched here.
    static func rows(_ trash: [TrashFacetSnapshot], matching query: String) -> [TrashFacetSnapshot] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return trash }
        return trash.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    static func facetName(_ facet: ContentFacet) -> String {
        switch facet {
        case .history: "Clip"
        case .memo: "Snippet"
        }
    }

    static func symbolName(_ facet: ContentFacet) -> String {
        switch facet {
        case .history: "doc.on.clipboard"
        case .memo: "bookmark"
        }
    }

    /// "Deleted 2 days ago · Snippet", and "· Removed tomorrow" once removal is a day or less away.
    static func metadata(for row: TrashFacetSnapshot, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.locale = locale
        var parts = [
            "Deleted \(formatter.localizedString(for: min(row.deletedAt, now), relativeTo: now))",
            facetName(row.identity.facet),
        ]
        if row.purgeAfter.timeIntervalSince(now) <= 86_400 {
            parts.append("Removed \(formatter.localizedString(for: max(row.purgeAfter, now), relativeTo: now))")
        }
        return parts.joined(separator: " · ")
    }

    static func restoreUnavailableReason(for row: TrashFacetSnapshot) -> String {
        switch row.identity.facet {
        case .history: "Its retention period or recovery window ended."
        case .memo: "Its recovery window ended."
        }
    }

    static func permanentConfirmationTitle(for row: TrashFacetSnapshot) -> String {
        "Permanently Delete \(facetName(row.identity.facet))?"
    }

    static func permanentConfirmationMessage(for row: TrashFacetSnapshot) -> String {
        let title = row.title.isEmpty ? "Untitled" : row.title
        return "“\(title)” will be removed for good. This cannot be undone."
    }
}
