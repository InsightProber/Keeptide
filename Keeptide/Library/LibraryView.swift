import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable private var session: CaptureSession
    @State private var selectedSection: LibrarySection? = .recentClips
    @State private var selectedItemID: ItemID?
    @State private var showsIgnoredApplications = false

    init(session: CaptureSession) {
        _session = Bindable(wrappedValue: session)
    }

    var body: some View {
        NavigationSplitView {
            List(LibrarySection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationTitle("Library")
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            contentColumn
                .navigationTitle(selectedSection?.title ?? "Library")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } detail: {
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showsIgnoredApplications) {
            IgnoredApplicationsView(preferences: session.preferences)
        }
        .task(id: selectedItemID) {
            let ref = session.recent.first(where: { $0.itemID == selectedItemID })?.history
            await session.select(ref)
        }
        .onChange(of: selectedSection) { _, section in
            guard section != .recentClips else { return }
            selectedItemID = nil
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        if selectedSection == .recentClips {
            VStack(spacing: 0) {
                captureStatus
                if session.actionMessage != nil { actionStatus.padding(12) }
                Divider()
                if session.recent.isEmpty {
                    ContentUnavailableView {
                        Label("No recent clips", systemImage: "clipboard")
                    } description: {
                        Text("Start recording to keep new copies. Existing clipboard content is not imported.")
                    }
                    .accessibilityIdentifier("RecentClipsEmptyState")
                } else {
                    List(session.recent, id: \.itemID, selection: $selectedItemID) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.title.isEmpty ? "Clipboard Item" : summary.title)
                                .lineLimit(2)
                            Text(summary.lastCopiedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(summary.itemID)
                        .accessibilityIdentifier("RecentClipRow")
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Planned for a later milestone", systemImage: "hammer")
            } description: {
                Text("Recent clipboard capture is available first. This library section is not implemented yet.")
            }
        }
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: session.isRecording ? "record.circle.fill" : "pause.circle")
                    .foregroundStyle(session.isRecording ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(captureHeadline)
                        .font(.headline)
                    Text(session.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("CaptureStatus")
                }
                Spacer()
            }
            HStack {
                Button {
                    session.preferences.isEnabled.toggle()
                } label: {
                    Label(
                        session.isRecording ? "Pause Recording" : "Start Recording",
                        systemImage: session.isRecording ? "pause.fill" : "record.circle"
                    )
                }
                .accessibilityIdentifier("CaptureRecordingToggle")
                .disabled(!session.isReady || session.isPausing)

                Button {
                    showsIgnoredApplications = true
                } label: {
                    Label("Ignored Apps", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("IgnoredApplications")
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if session.selectionIsLoading {
            ProgressView("Loading clip…")
        } else if let content = session.selectedContent,
           let summary = session.recent.first(where: { $0.itemID == selectedItemID }),
           let ref = summary.history {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.title.isEmpty ? "Clipboard Item" : summary.title)
                                .font(.title2.weight(.semibold))
                            Text(content.isActionable ? formatSummary(content) : integritySummary(content.integrity))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await session.copy(ref) }
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .accessibilityIdentifier("CopyCapture")
                        .disabled(!content.isActionable || session.selectionIsLoading)
                    }

                    Divider()
                    if !content.isActionable {
                        unavailableContent(content.integrity)
                    } else if let preview = session.selectedPreview {
                        Text(preview.text)
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if preview.isTruncated {
                            Label("Preview limited to the first 8 KiB", systemImage: "ellipsis.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CapturePreviewTruncated")
                        }
                    } else if content.representations.contains(where: isImage) {
                        ContentUnavailableView(
                            "Image capture",
                            systemImage: "photo",
                            description: Text("The original image representations are preserved for copying.")
                        )
                    } else if content.representations.contains(where: { $0.storage == .localReference }) {
                        ContentUnavailableView(
                            "File reference",
                            systemImage: "doc",
                            description: Text("The file remains local to this Mac and may require relocation later.")
                        )
                    } else {
                        ContentUnavailableView(
                            "Original formats preserved",
                            systemImage: "doc.on.clipboard",
                            description: Text("This capture has no directly readable text preview.")
                        )
                    }
                }
                .padding(24)
            }
        } else if selectedItemID != nil, session.selectionError != nil {
            ContentUnavailableView {
                Label("Clip unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(session.selectionError ?? "This clip could not be loaded.")
            }
            .accessibilityIdentifier("CaptureSelectionError")
        } else {
            ContentUnavailableView {
                Label("Select a recent clip", systemImage: "doc.text")
            } description: {
                Text("Content details and the explicit Copy action will appear here.")
            }
        }
    }

    private var captureHeadline: String {
        if session.isPausing { return "Pausing recording…" }
        if session.isRecording { return "Recording new copies" }
        return session.isReady ? "Recording paused" : "Recording unavailable"
    }

    @ViewBuilder
    private var actionStatus: some View {
        if let actionMessage = session.actionMessage {
            Label(actionMessage, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("CaptureActionStatus")
        }
    }

    private func integritySummary(_ integrity: ContentIntegrity) -> String {
        switch integrity {
        case .complete: "Original formats available"
        case .requiresRelocation: "File access required"
        case .recovering: "Content is still recovering"
        case .corrupt: "Content is unavailable"
        }
    }

    @ViewBuilder
    private func unavailableContent(_ integrity: ContentIntegrity) -> some View {
        switch integrity {
        case .complete:
            EmptyView()
        case .requiresRelocation:
            ContentUnavailableView(
                "File access required",
                systemImage: "doc.badge.ellipsis",
                description: Text("Choose the original file again before copying this clip.")
            )
        case .recovering:
            ContentUnavailableView(
                "Content is recovering",
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                description: Text("Keeptide will make this clip available after recovery completes.")
            )
        case .corrupt:
            ContentUnavailableView(
                "Content unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The original formats could not be verified, so this clip cannot be copied.")
            )
        }
    }

    private func isImage(_ representation: RepresentationValue) -> Bool {
        let type = representation.typeIdentifier.lowercased()
        return type == "public.png" || type == "public.jpeg" || type == "public.tiff" || type == "public.heic"
    }

    private func formatSummary(_ content: ResolvedContent) -> String {
        let itemCount = Set(content.representations.map(\.itemIndex)).count
        let formatCount = content.representations.count
        return "\(itemCount) item\(itemCount == 1 ? "" : "s") • \(formatCount) format\(formatCount == 1 ? "" : "s")"
    }
}

private struct IgnoredApplicationsView: View {
    @Bindable var preferences: CapturePreferences
    @Environment(\.dismiss) private var dismiss
    @State private var manualBundleID = ""
    @State private var showsApplicationPicker = false
    @State private var applicationPickerMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored Applications")
                        .font(.title2.weight(.semibold))
                    Text("New copies observed from these apps are skipped. Source identification is best effort.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if preferences.excludedApplications.isEmpty {
                ContentUnavailableView(
                    "No ignored apps",
                    systemImage: "hand.raised.slash",
                    description: Text("Choose an application or add its bundle identifier.")
                )
            } else {
                List(preferences.excludedApplications, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            preferences.removeExclusion(bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(bundleID)")
                    }
                }
                .frame(minHeight: 150)
            }

            HStack {
                Button("Choose Application…") { showsApplicationPicker = true }
                TextField("Bundle identifier", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManualBundleID)
                Button("Add", action: addManualBundleID)
                    .disabled(manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let applicationPickerMessage {
                Label(applicationPickerMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("IgnoredApplicationPickerMessage")
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
        .fileImporter(
            isPresented: $showsApplicationPicker,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false,
            onCompletion: handleApplicationPicker
        )
    }

    private func addManualBundleID() {
        let bundleID = manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        preferences.addExclusion(bundleID)
        manualBundleID = ""
    }

    private func handleApplicationPicker(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                applicationPickerMessage = "The selected application does not provide a readable bundle identifier."
                return
            }
            preferences.addExclusion(bundleID)
            applicationPickerMessage = nil
        case let .failure(error):
            if (error as NSError).code == NSUserCancelledError { return }
            applicationPickerMessage = "Keeptide could not read the selected application. No app was added."
        }
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
