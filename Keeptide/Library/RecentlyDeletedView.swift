import SwiftUI

struct RecentlyDeletedView: View {
    @Bindable var maintenance: LibraryMaintenance
    @State private var titleFilter = ""
    @State private var pendingPermanentDeletion: TrashFacetSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter deleted item titles", text: $titleFilter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("RecentlyDeletedTitleFilter")
                Button {
                    Task { await maintenance.refreshTrash() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(maintenance.isWorking)
                .help("Refresh Recently Deleted")
                .accessibilityLabel("Refresh Recently Deleted")
                .accessibilityIdentifier("RefreshRecentlyDeleted")
            }
            .padding(12)

            Divider()

            if maintenance.isWorking, maintenance.trash.isEmpty {
                ProgressView("Loading Recently Deleted…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRows.isEmpty {
                ContentUnavailableView {
                    Label(
                        titleFilter.isEmpty ? "Recently Deleted is Empty" : "No Deleted Items Match",
                        systemImage: "trash"
                    )
                } description: {
                    Text(
                        titleFilter.isEmpty
                            ? "Items you remove remain here until their recovery window ends."
                            : "This filter checks deleted item titles only."
                    )
                }
                .accessibilityIdentifier("RecentlyDeletedEmptyState")
            } else {
                List(filteredRows, id: \.identity) { row in
                    deletedRow(row)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("RecentlyDeletedList")
            }

            if let message = maintenance.message {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("RecentlyDeletedMessage")
            }
        }
        .task { await maintenance.refreshTrash() }
        .confirmationDialog(
            pendingPermanentDeletion.map(RecentlyDeletedPresentation.permanentConfirmationTitle)
                ?? "Permanently Delete Item?",
            isPresented: Binding(
                get: { pendingPermanentDeletion != nil },
                set: { if !$0 { pendingPermanentDeletion = nil } }
            ),
            presenting: pendingPermanentDeletion
        ) { row in
            Button("Delete Permanently", role: .destructive) {
                pendingPermanentDeletion = nil
                Task { _ = await maintenance.permanentlyDelete(row.identity) }
            }
            Button("Cancel", role: .cancel) { pendingPermanentDeletion = nil }
        } message: { row in
            Text(RecentlyDeletedPresentation.permanentConfirmationMessage(for: row))
        }
    }

    private var filteredRows: [TrashFacetSnapshot] {
        let query = titleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return maintenance.trash }
        return maintenance.trash.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func deletedRow(_ row: TrashFacetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.title.isEmpty ? "Untitled" : row.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(RecentlyDeletedPresentation.facetName(row.identity.facet))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Label(
                    "Deleted \(row.deletedAt.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "trash"
                )
                Label(
                    "Permanent after \(row.purgeAfter.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "clock"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !row.canRestore {
                Text(RecentlyDeletedPresentation.restoreUnavailableReason(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("RestoreUnavailableReason")
            }

            HStack(spacing: 8) {
                Button("Restore") {
                    Task { _ = await maintenance.restore(row.identity) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!row.canRestore || maintenance.isWorking)
                .help(
                    row.canRestore
                        ? "Restore this exact item"
                        : RecentlyDeletedPresentation.restoreUnavailableReason(for: row)
                )
                .accessibilityIdentifier("RestoreDeletedItem")

                Button("Delete Permanently", role: .destructive) {
                    pendingPermanentDeletion = row
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(maintenance.isWorking)
                .accessibilityIdentifier("PermanentlyDeleteItem")
                .layoutPriority(1)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RecentlyDeletedRow")
    }
}

enum RecentlyDeletedPresentation {
    static func facetName(_ facet: ContentFacet) -> String {
        switch facet {
        case .history: "Clipboard History"
        case .memo: "Saved Snippet"
        }
    }

    static func restoreUnavailableReason(for row: TrashFacetSnapshot) -> String {
        switch row.identity.facet {
        case .history:
            "Restore is unavailable because the retention period or recovery window ended."
        case .memo:
            "Restore is unavailable because the recovery window ended."
        }
    }

    static func permanentConfirmationTitle(for row: TrashFacetSnapshot) -> String {
        "Permanently Delete \(facetName(row.identity.facet))?"
    }

    static func permanentConfirmationMessage(for row: TrashFacetSnapshot) -> String {
        let title = row.title.isEmpty ? "Untitled" : row.title
        return "“\(title)” will be permanently removed from \(facetName(row.identity.facet).lowercased()). This cannot be undone."
    }
}
