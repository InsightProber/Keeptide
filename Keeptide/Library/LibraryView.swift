import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable private var session: CaptureSession
    @State private var selectedSection: LibrarySection? = .recentClips
    @State private var selectedItemID: ItemID?
    @State private var showsIgnoredApplications = false
    @State private var showsApplicationPicker = false
    @State private var applicationPickerMessage: String?

    init(session: CaptureSession = CaptureSession()) {
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
            IgnoredApplicationsView(
                preferences: session.preferences,
                showsApplicationPicker: $showsApplicationPicker,
                applicationPickerMessage: $applicationPickerMessage
            )
        }
        .fileImporter(
            isPresented: $showsApplicationPicker,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                    applicationPickerMessage = "The selected application does not provide a readable bundle identifier."
                    return
                }
                session.preferences.addExclusion(bundleID)
                applicationPickerMessage = nil
            case let .failure(error):
                if (error as NSError).code == NSUserCancelledError { return }
                applicationPickerMessage = "Keeptide could not read the selected application. No app was added."
            }
        }
        .onChange(of: selectedItemID) { _, itemID in
            let ref = session.recent.first(where: { $0.itemID == itemID }).flatMap(preferredRef)
            Task { await session.select(ref) }
        }
        .onChange(of: selectedSection) { _, section in
            guard section != .recentClips else { return }
            selectedItemID = nil
            Task { await session.select(nil) }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        if selectedSection == .recentClips {
            VStack(spacing: 0) {
                captureStatus
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
                Image(systemName: session.preferences.isEnabled ? "record.circle.fill" : "pause.circle")
                    .foregroundStyle(session.preferences.isEnabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                Text(session.isPausing ? "Pausing recording…" : (session.preferences.isEnabled ? "Recording new copies" : "Recording paused"))
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
                        session.preferences.isEnabled ? "Pause Recording" : "Start Recording",
                        systemImage: session.preferences.isEnabled ? "pause.fill" : "record.circle"
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
        if let content = session.selectedContent,
           let summary = session.recent.first(where: { $0.itemID == selectedItemID }),
           let ref = preferredRef(summary) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.title.isEmpty ? "Clipboard Item" : summary.title)
                                .font(.title2.weight(.semibold))
                            Text(formatSummary(content))
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
                    }

                    Divider()
                    if let actionMessage = session.actionMessage {
                        Label(actionMessage, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("CaptureActionStatus")
                    }
                    if let text = readableText(content) {
                        Text(text)
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if content.representations.contains(where: isImage) {
                        ContentUnavailableView(
                            "Image capture",
                            systemImage: "photo",
                            description: Text("The original image representations are preserved for copying.")
                        )
                    } else if content.representations.contains(where: { representation in
                        SystemFileReferenceClassifier.isLocalFileReference(
                            typeIdentifier: representation.typeIdentifier,
                            bytes: representation.bytes
                        )
                    }) {
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
        } else {
            ContentUnavailableView {
                Label("Select a recent clip", systemImage: "doc.text")
            } description: {
                Text("Content details and the explicit Copy action will appear here.")
            }
        }
    }

    private func preferredRef(_ summary: ItemSummary) -> ContentRef? {
        summary.memo ?? summary.history
    }

    private func readableText(_ content: ResolvedContent) -> String? {
        let plainTextTypes = Set([
            "public.utf8-plain-text",
            "public.plain-text",
            "NSStringPboardType"
        ])
        return content.representations.lazy.compactMap { representation in
            guard plainTextTypes.contains(representation.typeIdentifier),
                  let bytes = representation.bytes else { return nil }
            return String(data: bytes, encoding: .utf8)
        }.first
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
    @Binding var showsApplicationPicker: Bool
    @Binding var applicationPickerMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var manualBundleID = ""

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
    }

    private func addManualBundleID() {
        let bundleID = manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        preferences.addExclusion(bundleID)
        manualBundleID = ""
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
