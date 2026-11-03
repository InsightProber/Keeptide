import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySidebarPreference: Equatable {
    case automatic, shown, hidden
}

enum LibrarySidebarVisibility: Equatable {
    case visible, hidden
}

enum LibraryLayoutPolicy {
    static func sidebarVisibility(
        width: CGFloat,
        preference: LibrarySidebarPreference,
        current: LibrarySidebarVisibility
    ) -> LibrarySidebarVisibility {
        switch preference {
        case .shown:
            return .visible
        case .hidden:
            return .hidden
        case .automatic:
            if width < 960 { return .hidden }
            if width > 1_040 { return .visible }
            return current
        }
    }
}

struct LibraryView: View {
    @Bindable private var session: CaptureSession
    @Bindable private var commands: LibraryWindowCommands
    @State private var selectedSection: LibrarySection? = .recentClips
    @State private var selectedItemID: ItemID?
    @State private var showsIgnoredApplications = false
    @State private var sidebarPreference: LibrarySidebarPreference = .automatic
    @State private var sidebarVisibility: LibrarySidebarVisibility = .visible
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var bodyFocusRequest = 0
    @State private var bodyFocusSessionID: UUID?
    @State private var bodyFocusGeneration = 0
    @State private var availableWidth: CGFloat = 1_120

    init(session: CaptureSession, commands: LibraryWindowCommands = LibraryWindowCommands()) {
        _session = Bindable(wrappedValue: session)
        _commands = Bindable(wrappedValue: commands)
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $splitVisibility) {
                List(LibrarySection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            } content: {
                contentColumn
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } detail: {
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .onAppear {
                availableWidth = geometry.size.width
                updateSidebar(for: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                availableWidth = width
                updateSidebar(for: width)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { libraryToolbar }
        .onChange(of: splitVisibility) { _, visibility in
            let next: LibrarySidebarVisibility = visibility == .all ? .visible : .hidden
            guard next != sidebarVisibility else { return }
            sidebarVisibility = next
            sidebarPreference = next == .visible ? .shown : .hidden
        }
        .sheet(isPresented: $showsIgnoredApplications) {
            IgnoredApplicationsView(preferences: session.preferences)
        }
        .task(id: selectedItemID) {
            let ref = session.recent.first(where: { $0.itemID == selectedItemID })?.history
            await session.select(ref)
            if selectedSection == .recentClips, let selectedItemID {
                await session.libraryWorkspace?.select(selectedItemID)
            }
        }
        .onChange(of: selectedSection) { _, section in
            selectedItemID = nil
            guard let section else { return }
            Task { await session.libraryWorkspace?.setScope(section.scope) }
        }
        .onChange(of: commands.newSnippetRequest) { _, _ in
            startNewSnippet(focusGeneration: commands.newSnippetFocusGeneration)
        }
        .onChange(of: commands.saveRequest) { _, _ in saveCurrentEditor() }
        .onChange(of: commands.copyRequest) { _, _ in copyCurrentEditor() }
        .onChange(of: commands.openRequest) { _, request in
            guard let request else { return }
            Task { await session.libraryWorkspace?.open(request.ref) }
        }
        .disabled(session.libraryWorkspace?.isClosing == true)
    }

    @ViewBuilder
    private var contentColumn: some View {
        if selectedSection == .recentClips {
            VStack(spacing: 0) {
                captureStatus
                if session.actionMessage != nil { actionStatus.padding(12) }
                Divider()
                if let workspace = session.libraryWorkspace {
                    snippetList(workspace, recentStyle: true)
                } else if let error = session.libraryInitializationError {
                    ContentUnavailableView {
                        Label("Library unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                    .accessibilityIdentifier("LibraryInitializationError")
                } else {
                    ProgressView("Preparing library…")
                }
            }
        } else if let workspace = session.libraryWorkspace {
            snippetList(workspace)
        } else if let error = session.libraryInitializationError {
            ContentUnavailableView {
                Label("Library unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .accessibilityIdentifier("LibraryInitializationError")
        } else {
            ProgressView("Preparing library…")
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
                .disabled(!session.canToggleRecording)

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
        if let workspace = session.libraryWorkspace, let editor = workspace.editor {
            MemoEditorView(
                editor: editor,
                workspace: workspace,
                bodyFocusRequest: bodyFocusSessionID == editor.sessionID ? bodyFocusRequest : 0,
                shouldFocusBody: {
                    commands.focusGeneration == bodyFocusGeneration
                }
            )
            .id(editor.sessionID)
        } else {
            captureDetailColumn
        }
    }

    @ViewBuilder
    private var captureDetailColumn: some View {
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

                        Button {
                            Task {
                                guard let workspace = session.libraryWorkspace else { return }
                                await workspace.open(ref)
                                guard workspace.editor?.ref == ref else { return }
                                _ = try? await workspace.saveSelectedHistory()
                            }
                        } label: {
                            Label("Save as Snippet", systemImage: "bookmark")
                        }
                        .accessibilityIdentifier("SaveCaptureAsSnippet")
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

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            LibrarySearchField(text: searchBinding, focusRequest: commands.searchRequest)
                .frame(width: 220)

            Button {
                commands.requestNewSnippet()
            } label: {
                Label("New Snippet", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("NewSnippet")
            .disabled(session.libraryWorkspace == nil)

            Button { showsIgnoredApplications = true } label: {
                Label("Ignored Apps", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("IgnoredApplicationsToolbar")
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { session.libraryWorkspace?.query ?? "" },
            set: { value in session.libraryWorkspace?.updateQuery(value) }
        )
    }

    private func updateSidebar(for width: CGFloat) {
        let next = LibraryLayoutPolicy.sidebarVisibility(
            width: width,
            preference: sidebarPreference,
            current: sidebarVisibility
        )
        sidebarVisibility = next
        splitVisibility = next == .visible ? .all : .doubleColumn
    }

    private func startNewSnippet(focusGeneration: Int) {
        Task {
            await session.libraryWorkspace?.startNew()
            guard commands.focusGeneration == focusGeneration else { return }
            bodyFocusSessionID = session.libraryWorkspace?.editor?.sessionID
            bodyFocusGeneration = focusGeneration
            bodyFocusRequest += 1
        }
    }

    private func saveCurrentEditor() {
        Task {
            guard let workspace = session.libraryWorkspace else { return }
            do {
                if workspace.editor?.isReadOnly == true { _ = try await workspace.saveSelectedHistory() }
                else { _ = try await workspace.flush() }
            } catch { /* Workspace retains the draft and its visible failure. */ }
        }
    }

    private func copyCurrentEditor() {
        Task { _ = await session.libraryWorkspace?.copyCurrent(mode: .original) }
    }

    @ViewBuilder
    private func recoveredDrafts(_ workspace: LibraryWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = workspace.recoveryNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("DraftRecoveryNotice")
            }
            Label("Recovered drafts", systemImage: "arrow.counterclockwise.circle")
                .font(.headline)
            ForEach(workspace.recoveredDrafts) { draft in
                Button {
                    Task { await workspace.recoverDraft(draft.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.title.isEmpty ? "Untitled Draft" : draft.title)
                        if let preview = draft.bodyPreview, !preview.isEmpty {
                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .accessibilityIdentifier("RecoveredDrafts")
    }

    @ViewBuilder
    private func snippetList(_ workspace: LibraryWorkspace, recentStyle: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !workspace.recoveredDrafts.isEmpty || workspace.recoveryNotice != nil {
                recoveredDrafts(workspace)
                Divider()
            }
            if let message = workspace.message {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Spacer()
                    if workspace.editor?.status == .failed {
                        Button("Retry") { saveCurrentEditor() }
                    }
                }
                .padding(10)
                .background(.regularMaterial)
                .accessibilityIdentifier("LibraryFailureMessage")
            }
            if workspace.isLoading {
                ProgressView().controlSize(.small).padding(8)
            }
            if workspace.entries.isEmpty, !workspace.isLoading {
                ContentUnavailableView {
                    Label(recentStyle ? "No recent clips" : "No snippets",
                          systemImage: recentStyle ? "clipboard" : "doc.text")
                } description: {
                    Text(workspace.query.isEmpty
                         ? (recentStyle
                            ? "Start recording to keep new copies. Existing clipboard content is not imported."
                            : "Create a snippet or save a recent clip to keep it here.")
                         : "No items match your search.")
                }
                .accessibilityIdentifier(recentStyle ? "RecentClipsEmptyState" : "SnippetsEmptyState")
            } else {
                List(workspace.entries, selection: workspaceSelection(workspace)) { entry in
                    LibraryEntryRow(entry: entry)
                        .tag(entry.id)
                        .accessibilityIdentifier(recentStyle ? "RecentClipRow" : "LibraryEntryRow")
                        .onAppear {
                            guard entry.id == workspace.entries.last?.id, workspace.hasMoreEntries else { return }
                            Task { await workspace.loadMore() }
                        }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("SnippetList")
            }
        }
    }

    private func workspaceSelection(_ workspace: LibraryWorkspace) -> Binding<ItemID?> {
        Binding(
            get: { workspace.selectedEntryID },
            set: { itemID in
                guard let itemID else { return }
                Task { await workspace.select(itemID) }
            }
        )
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

private struct LibraryEntryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if let snippet = entry.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if entry.kind == .image {
                    Text("Image content")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(entry.lastCopiedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("LibraryEntryRow")
    }

    private var symbolName: String {
        switch entry.kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .other: "square.dashed"
        }
    }
}

private struct MemoEditorView: View {
    @Bindable var editor: MemoEditorSession
    @Bindable var workspace: LibraryWorkspace
    let bodyFocusRequest: Int
    let shouldFocusBody: @MainActor () -> Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let body = editor.body {
                EditorBridge(
                    documentID: editor.draftID,
                    text: body,
                    isCode: editor.kind == .code,
                    isEditable: !editor.isReadOnly && !workspace.isClosing,
                    focusRequest: bodyFocusRequest,
                    shouldFocus: shouldFocusBody,
                    onChange: { value, isComposing in
                        editor.setBody(value, isComposing: isComposing)
                    },
                    onFocusLost: {
                        Task { _ = try? await workspace.focusLost() }
                    }
                )
                .id(editor.sessionID)
                .accessibilityIdentifier("SnippetBodyEditor")
            } else {
                ContentUnavailableView(
                    "Original content preserved",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("This item has no editable text body. Its original formats remain available for copying.")
                )
                .accessibilityIdentifier("SnippetMetadataOnly")
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ComposingTextField(
                    text: editor.title,
                    placeholder: "Untitled Snippet",
                    isEditable: !editor.isReadOnly,
                    font: .preferredFont(forTextStyle: .title2),
                    onChange: editor.setTitle
                )
                .frame(height: 34)
                .accessibilityIdentifier("SnippetTitleEditor")

                Spacer(minLength: 16)

                if workspace.canUndoNewSave {
                    Button("Undo Save") {
                        Task { _ = try? await workspace.undoNewSave() }
                    }
                    .accessibilityIdentifier("LibraryUndoNewSave")
                }

                if editor.isReadOnly {
                    Button {
                        Task { _ = try? await workspace.saveSelectedHistory() }
                    } label: {
                        Label("Save as Snippet", systemImage: "bookmark")
                    }
                    .accessibilityIdentifier("SaveHistoryAsSnippet")
                }

                Button {
                    Task { _ = await workspace.copyCurrent(mode: .original) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityIdentifier(editor.isReadOnly ? "CopyCapture" : "CopyLibraryItem")
            }

            HStack(spacing: 10) {
                Picker("Kind", selection: kindBinding) {
                    Text("Text").tag(MemoKind.plainText)
                    Text("Prompt").tag(MemoKind.prompt)
                    Text("Code").tag(MemoKind.code)
                    Text("Markdown").tag(MemoKind.markdown)
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .disabled(editor.isReadOnly)

                statusLabel

                if editor.richSourceWarning {
                    Label("Saving edits creates an owned text version", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ComposingTextField(
                text: editor.note,
                placeholder: "Optional note",
                isEditable: !editor.isReadOnly,
                font: .preferredFont(forTextStyle: .callout),
                onChange: editor.setNote
            )
            .frame(height: 28)
            .accessibilityIdentifier("SnippetNoteEditor")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch editor.status {
        case .clean:
            EmptyView()
        case .saving:
            Label(editor.isComposing ? "Saving draft…" : "Saving…", systemImage: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 6) {
                Label(editor.failureMessage ?? "Could not save", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") { Task { _ = try? await workspace.flush() } }
                    .controlSize(.small)
            }
        }
    }

    private var kindBinding: Binding<MemoKind> {
        Binding(get: { editor.kind }, set: { editor.setKind($0) })
    }
}

private struct ComposingTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let isEditable: Bool
    let font: NSFont
    let onChange: @MainActor (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.font = font
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.isEditable = isEditable
        field.isSelectable = true
        field.font = font
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              field.stringValue != text else { return }
        field.stringValue = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onChange: @MainActor (String, Bool) -> Void

        init(onChange: @escaping @MainActor (String, Bool) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue, (field.currentEditor() as? NSTextView)?.hasMarkedText() == true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue, false)
        }
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

enum LibrarySection: String, CaseIterable, Identifiable {
    case recentClips
    case allSnippets
    case uncategorized

    var scope: LibraryScope {
        switch self {
        case .recentClips: .recentClips
        case .allSnippets: .allSnippets
        case .uncategorized: .uncategorized
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .recentClips: "Recent Clips"
        case .allSnippets: "All Snippets"
        case .uncategorized: "Uncategorized"
        }
    }

    var symbolName: String {
        switch self {
        case .recentClips: "clock"
        case .allSnippets: "doc.text"
        case .uncategorized: "tray"
        }
    }
}
