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

    /// The explicit preference View › Show Sidebar / Hide Sidebar sets: the other of what shows now.
    static func preference(toggling visibility: LibrarySidebarVisibility) -> LibrarySidebarPreference {
        visibility == .visible ? .hidden : .shown
    }
}

struct LibraryView: View {
    @Bindable private var session: CaptureSession
    @Bindable private var commands: LibraryWindowCommands
    @State private var selectedScope: LibraryScope? = .recentClips
    @State private var selectedItemID: ItemID?
    @State private var selectedEntryIDs: Set<ItemID> = []
    @State private var collectionEditorMode: CollectionEditorMode?
    @State private var collectionPendingDeletion: CollectionSnapshot?
    @State private var sidebarPreference: LibrarySidebarPreference = .automatic
    @State private var sidebarVisibility: LibrarySidebarVisibility = .visible
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var bodyFocus = BodyFocusRequestState()
    @State private var availableWidth: CGFloat = 1_120
    @FocusState private var sidebarHasFocus: Bool
    @State private var searchPresented = false
    @State private var searchScope: LibrarySearchScope = .allContent

    init(session: CaptureSession, commands: LibraryWindowCommands = LibraryWindowCommands()) {
        _session = Bindable(wrappedValue: session)
        _commands = Bindable(wrappedValue: commands)
    }

    private var libraryLayout: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $splitVisibility) {
                librarySidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            } content: {
                // The system draws the columns' backgrounds, the sidebar's glass and the scroll edges under the toolbar.
                contentColumn
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar { contentToolbar }
            } detail: {
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar { detailToolbar }
            }
            // The system search field at the toolbar's trailing end, and under it while searching, All Content or
            // This View. The scopes modifier must follow the searchable one.
            .searchable(text: searchBinding, isPresented: $searchPresented, placement: .toolbar,
                        prompt: Text(searchPrompt))
            .searchScopes($searchScope, activation: .onSearchPresentation) { searchScopeOptions }
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
        .onChange(of: splitVisibility) { _, visibility in
            let next: LibrarySidebarVisibility = visibility == .all ? .visible : .hidden
            guard next != sidebarVisibility else { return }
            sidebarVisibility = next
            sidebarPreference = next == .visible ? .shown : .hidden
        }
    }

    private var presentedLibrary: some View {
        libraryLayout
        .sheet(isPresented: exportStatusPresentation) {
            if let coordinator = session.exportCoordinator {
                ExportStatusView(coordinator: coordinator)
            }
        }
        .sheet(item: $collectionEditorMode) { mode in
            CollectionEditorSheet(mode: mode) { name, color in
                guard let workspace = session.libraryWorkspace else { return false }
                switch mode {
                case .create:
                    return await workspace.createCollection(CollectionDraft(name: name, color: color))
                case .edit(let snapshot):
                    return await workspace.editCollection(snapshot, name: name, color: color)
                }
            }
        }
        .confirmationDialog(
            collectionPendingDeletion.map { "Delete “\($0.value.name)”?" } ?? "Delete Collection?",
            isPresented: Binding(
                get: { collectionPendingDeletion != nil },
                set: { if !$0 { collectionPendingDeletion = nil } }
            ),
            presenting: collectionPendingDeletion
        ) { collection in
            Button("Delete Collection", role: .destructive) {
                deleteCollection(collection)
            }
            Button("Cancel", role: .cancel) { collectionPendingDeletion = nil }
        } message: { _ in
            Text("Snippets in it will become unfiled. Nothing is deleted.")
        }
    }

    private var selectionLibrary: some View {
        presentedLibrary
        .task(id: selectedItemID) {
            let ref = session.recent.first(where: { $0.itemID == selectedItemID })?.history
            await session.select(ref)
            if selectedScope == .recentClips, let selectedItemID {
                await session.libraryWorkspace?.select(selectedItemID)
            }
        }
        .onChange(of: selectedScope) { previous, scope in
            // A list cannot be deselected: the one chosen stays, and so do the subtitle and the library's list.
            guard let scope else {
                selectedScope = previous
                return
            }
            guard previous != nil else { return }
            selectedItemID = nil
            selectedEntryIDs.removeAll()
            updateExportContext()
            session.libraryWorkspace?.updateScope(scope)
        }
        .onChange(of: selectedItemID) { _, _ in updateExportContext() }
        .onChange(of: selectedEntryIDs) { _, _ in updateExportContext() }
        .onChange(of: session.libraryWorkspace?.entries.map(\.ref) ?? []) { _, _ in
            updateExportContext()
        }
    }

    /// The sidebar's commands, and what the window and its menus show of the list chosen.
    private var listLibrary: some View {
        selectionLibrary
        .onChange(of: currentScopeTitle, initial: true) { _, title in commands.showListTitle(title) }
        .onChange(of: listContext, initial: true) { _, context in
            commands.updateListContext(
                scope: context.scope, sections: context.sections, sidebarIsVisible: context.sidebarIsVisible
            )
        }
        .onChange(of: commands.previousListRequest) { _, _ in moveList(-1) }
        .onChange(of: commands.nextListRequest) { _, _ in moveList(1) }
        .onChange(of: commands.listRequest) { _, request in
            if let request { selectedScope = request.scope }
        }
        .onChange(of: commands.sidebarFocusRequest) { _, _ in sidebarHasFocus = true }
        .onChange(of: commands.searchRequest) { _, _ in searchPresented = true }
        .onChange(of: searchPresented, initial: true) { _, presented in commands.updateSearchPresented(presented) }
        .onChange(of: searchScope) { _, scope in session.libraryWorkspace?.updateSearchScope(scope) }
        .onChange(of: commands.sidebarToggleRequest) { _, _ in toggleSidebar() }
        .onChange(of: commands.newCollectionRequest) { _, _ in
            if session.libraryWorkspace != nil { collectionEditorMode = .create }
        }
        .onChange(of: session.libraryWorkspace.map(ObjectIdentifier.init)) { _, opened in
            // A list chosen while the library was still opening is the one it opens on.
            guard opened != nil, let selectedScope else { return }
            session.libraryWorkspace?.updateScope(selectedScope)
        }
        .onChange(of: session.libraryWorkspace?.scope) { previous, scope in
            // The library left a list that is gone: a deleted collection, or Unfiled with the last collection.
            guard previous != nil, let scope, scope != selectedScope else { return }
            selectedScope = scope
        }
    }

    private struct ListContext: Equatable {
        let scope: LibraryScope
        let sections: [[LibrarySidebar.ListEntry]]
        let sidebarIsVisible: Bool
    }

    private var listContext: ListContext {
        ListContext(scope: selectedScope ?? .recentClips, sections: listSections,
                    sidebarIsVisible: sidebarVisibility == .visible)
    }

    private var listSections: [[LibrarySidebar.ListEntry]] {
        LibrarySidebar.sections(
            collections: session.libraryWorkspace?.collections.map { ($0.value.id, $0.value.name) } ?? []
        )
    }

    var body: some View {
        listLibrary
        .onChange(of: commands.newSnippetRequest) { _, _ in
            startNewSnippet(focusGeneration: commands.newSnippetFocusGeneration)
        }
        .onChange(of: commands.saveRequest) { _, _ in saveCurrentEditor() }
        .onChange(of: commands.copyRequest) { _, _ in copyCurrentEditor() }
        .onChange(of: commands.openRequest) { _, request in
            guard let request else { return }
            Task { await session.libraryWorkspace?.open(request.ref) }
        }
        .onChange(of: commands.exportLibraryRequest, initial: true) { _, request in
            if request > 0 { beginExport(selectedOnly: false) }
        }
        .onChange(of: commands.exportSelectedRequest, initial: true) { _, request in
            if request > 0 { beginExport(selectedOnly: true) }
        }
        .onAppear { updateExportContext() }
        .disabled(session.libraryWorkspace?.isClosing == true)
    }

    private var exportStatusPresentation: Binding<Bool> {
        Binding(
            get: { session.exportCoordinator?.presentsStatus == true },
            set: { presented in
                guard !presented else { return }
                guard let coordinator = session.exportCoordinator else { return }
                if case .exporting = coordinator.phase {
                    coordinator.cancel()
                } else {
                    coordinator.dismissResult()
                }
            }
        )
    }

    private func updateExportContext() {
        commands.updateExportContext(
            refs: currentExportRefs(),
            isRecentlyDeleted: selectedScope == .recentlyDeleted
        )
    }

    private func currentExportRefs() -> [ContentRef] {
        guard selectedScope != .recentlyDeleted, let workspace = session.libraryWorkspace else { return [] }
        if selectedScope == .recentClips {
            guard let selectedItemID else { return [] }
            return workspace.entries.filter { $0.id == selectedItemID }.map(\.ref)
        }
        return workspace.entries.filter { selectedEntryIDs.contains($0.id) }.map(\.ref)
    }

    private func beginExport(selectedOnly: Bool) {
        guard selectedScope != .recentlyDeleted,
              let coordinator = session.exportCoordinator,
              let workspace = session.libraryWorkspace else { return }
        let requested = currentExportRefs()
        if selectedOnly && requested.isEmpty { return }

        coordinator.start {
            if workspace.editor?.isComposing == true
                || (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {
                throw ExportPreparationError.compositionInProgress
            }
            if selectedOnly, currentExportRefs() != requested {
                throw ExportPreparationError.selectionChanged
            }

            let editorRef = workspace.editor?.ref
            let flushed: ContentRef?
            do {
                flushed = try await workspace.flush()
            } catch {
                throw ExportPreparationError.saveFailed
            }
            guard selectedOnly else { return .allVisible }
            return try ExportSelectionResolver.selectedScope(
                requested: requested,
                editorRef: editorRef,
                flushedRef: flushed,
                displayed: currentExportRefs()
            )
        }
    }

    /// Clipboard, Snippets and Collections sections, then Recently Deleted on its own. Unfiled follows the collections
    /// while there is any: without one it would only repeat All Snippets.
    private var librarySidebar: some View {
        List(selection: $selectedScope) {
            Section("Clipboard") {
                Label("Recent Clips", systemImage: "clock")
                    .tag(LibraryScope.recentClips)
            }
            Section("Snippets") {
                Label("All Snippets", systemImage: "bookmark")
                    .tag(LibraryScope.allSnippets)
                Label("Favorites", systemImage: "star")
                    .tag(LibraryScope.favorites)
            }
            Section {
                if let workspace = session.libraryWorkspace {
                    ForEach(workspace.collections, id: \.value.id) { collection in
                        collectionSidebarRow(collection, workspace: workspace)
                            .tag(LibraryScope.collection(collection.value.id))
                    }
                    if !workspace.collections.isEmpty {
                        Label("Unfiled", systemImage: "tray")
                            .tag(LibraryScope.uncategorized)
                    }
                }
            } header: {
                collectionsHeader
            }
            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .tag(LibraryScope.recentlyDeleted)
            }
        }
        .listStyle(.sidebar)
        .focused($sidebarHasFocus)
        .accessibilityIdentifier("LibrarySidebar")
        .task { await session.libraryWorkspace?.refreshCollections() }
    }

    /// The Collections heading and its button for a new collection; right-clicking the heading offers the same.
    private var collectionsHeader: some View {
        HStack {
            Text("Collections")
            Spacer()
            Button {
                collectionEditorMode = .create
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Collection")
            .accessibilityLabel("New Collection")
            .accessibilityIdentifier("AddCollection")
            .disabled(session.libraryWorkspace == nil)
        }
        // A sidebar heading otherwise reads as one text, and its button cannot be reached on its own.
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("New Collection…") { collectionEditorMode = .create }
                .disabled(session.libraryWorkspace == nil)
        }
    }

    private func collectionSidebarRow(
        _ collection: CollectionSnapshot,
        workspace: LibraryWorkspace
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.collection(collection.value.color))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(collection.value.name)
                .lineLimit(1)
                .accessibilityLabel(collection.value.name)
                .help(collection.value.name)
        }
        .accessibilityLabel(collection.value.name)
        .accessibilityIdentifier("CollectionRow-\(collection.value.id.rawValue.uuidString)")
        .contextMenu {
            Button("Rename Collection") { collectionEditorMode = .edit(collection) }
            Button("Move Up") {
                Task { _ = await workspace.reorderCollection(collection, offset: -1) }
            }
            .disabled(workspace.collections.first?.value.id == collection.value.id)
            Button("Move Down") {
                Task { _ = await workspace.reorderCollection(collection, offset: 1) }
            }
            .disabled(workspace.collections.last?.value.id == collection.value.id)
            Divider()
            Button("Delete Collection", role: .destructive) {
                collectionPendingDeletion = collection
            }
        }
    }

    private func deleteCollection(_ collection: CollectionSnapshot) {
        collectionPendingDeletion = nil
        // The library leaves the list if it goes with the collection, and the sidebar follows (`listLibrary`).
        Task { _ = await session.libraryWorkspace?.deleteCollection(collection) }
    }

    /// The list the sidebar chooses. Why new copies are not kept shows over it, unless it is Recently Deleted, which new
    /// copies never reach.
    private var contentColumn: some View {
        VStack(spacing: 0) {
            if selectedScope != .recentlyDeleted, let notice = session.captureNotice { captureNoticeLine(notice) }
            scopeColumn
        }
    }

    @ViewBuilder
    private var scopeColumn: some View {
        if selectedScope == .recentlyDeleted {
            if let maintenance = session.maintenance {
                RecentlyDeletedView(maintenance: maintenance, query: session.libraryWorkspace?.query ?? "")
            } else {
                ContentUnavailableView {
                    Label("Recently Deleted Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Keeptide couldn't check deleted items right now.")
                }
                .accessibilityIdentifier("RecentlyDeletedUnavailable")
            }
        } else if selectedScope == .recentClips {
            VStack(spacing: 0) {
                if session.actionMessage != nil {
                    actionStatus.padding(12)
                    Divider()
                }
                if let workspace = session.libraryWorkspace {
                    snippetList(workspace, recentStyle: true)
                } else if let error = session.libraryInitializationError {
                    ContentUnavailableView {
                        Label("Keeptide Couldn't Open the Library", systemImage: "exclamationmark.triangle")
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
                Label("Keeptide Couldn't Open the Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .accessibilityIdentifier("LibraryInitializationError")
        } else {
            ProgressView("Preparing library…")
        }
    }

    /// Why new copies are not kept, while that is so. While they are kept, nothing is said.
    private func captureNoticeLine(_ notice: String) -> some View {
        VStack(spacing: 0) {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .accessibilityIdentifier("CaptureStatus")
            Divider()
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selectedScope == .recentlyDeleted {
            ContentUnavailableView { Text("No Item Selected") }
                .accessibilityIdentifier("RecentlyDeletedDetail")
        } else if let workspace = session.libraryWorkspace, let editor = workspace.editor {
            let focusRequest = bodyFocus.request(for: editor.sessionID, documentID: editor.draftID)
            MemoEditorView(
                editor: editor,
                workspace: workspace,
                contentKind: editorContentKind(editor, in: workspace),
                previewService: session.previewService,
                fileAccessStore: session.fileAccessStore,
                fileAccessIdentity: session.fileAccessIdentity,
                bodyFocusRequest: focusRequest,
                shouldFocusBody: {
                    bodyFocus.isCurrent(
                        sessionID: editor.sessionID,
                        documentID: editor.draftID,
                        request: focusRequest,
                        generation: commands.focusGeneration
                    )
                },
                onBodyFocusAccepted: { sessionID, documentID, request in
                    bodyFocus.consume(
                        sessionID: sessionID,
                        documentID: documentID,
                        request: request
                    )
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
                    } else {
                        LibraryContentPreview(
                            ref: ref,
                            kind: summary.kind,
                            service: session.previewService,
                            fileAccessStore: session.fileAccessStore,
                            fileAccessIdentity: session.fileAccessIdentity,
                            applicationName: summary.sourceApp
                        )
                        .frame(minHeight: 360)
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
            ContentUnavailableView { Text(selectedScope == .recentClips ? "No Clip Selected" : "No Snippet Selected") }
        }
    }

    /// Over the list: while the sidebar is hidden, a menu at the toolbar's leading edge chooses the list; then the
    /// group that creates, New Snippet.
    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        if sidebarVisibility == .hidden {
            ToolbarItem(placement: .navigation) { scopeMenu }
        }
        ToolbarItem {
            Button {
                commands.requestNewSnippet()
            } label: {
                Label("New Snippet", systemImage: "square.and.pencil")
            }
            .help("New Snippet")
            .accessibilityIdentifier("NewSnippet")
            .disabled(session.libraryWorkspace == nil || selectedScope == .recentlyDeleted)
        }
    }

    /// Over the detail: the system's search item. Giving the detail column toolbar items of its own is also what
    /// splits the toolbar by column, so New Snippet stays over the list.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        DefaultToolbarItem(kind: .search)
    }

    /// The search field's prompt names what an empty search lists, and Recently Deleted says it matches titles.
    private var searchPrompt: String {
        switch selectedScope ?? .recentClips {
        case .recentClips: "Search Recent Clips"
        case .allSnippets: "Search Snippets"
        case .favorites: "Search Favorites"
        case .uncategorized: "Search Unfiled"
        case .recentlyDeleted: "Search Recently Deleted by Title"
        case .collection: "Search “\(currentScopeTitle)”"
        }
    }

    /// All Content never includes deleted items, so Recently Deleted's search has no scope bar.
    @ViewBuilder
    private var searchScopeOptions: some View {
        if selectedScope != .recentlyDeleted {
            Text("All Content").tag(LibrarySearchScope.allContent)
            Text("This View").tag(LibrarySearchScope.thisView)
        }
    }

    /// The sidebar's lists in its order and sections, and New Collection… after them. ⌘L opens the same lists from
    /// AppKit (`LibraryWindowController.makeListMenu`), finding this menu by its help.
    private var scopeMenu: some View {
        Menu {
            ForEach(Array(listSections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section, id: \.scope) { list in
                    Button {
                        selectedScope = list.scope
                    } label: {
                        Label(list.title, systemImage: list.symbolName)
                    }
                }
            }
            Divider()
            Button {
                collectionEditorMode = .create
            } label: {
                Label("New Collection…", systemImage: "plus")
            }
            .disabled(session.libraryWorkspace == nil)
        } label: {
            Label(currentScopeTitle, systemImage: "line.3.horizontal.decrease.circle")
                .lineLimit(1)
        }
        .help(LibrarySidebar.chooseListHelp)
        .accessibilityLabel("Library Scope: \(currentScopeTitle)")
        .accessibilityIdentifier("LibraryScopeMenu")
    }

    private var currentScopeTitle: String {
        guard let selectedScope else { return "Library" }
        switch selectedScope {
        case .recentClips: return "Recent Clips"
        case .favorites: return "Favorites"
        case .allSnippets: return "All Snippets"
        case .uncategorized: return "Unfiled"
        case .recentlyDeleted: return "Recently Deleted"
        case .collection(let id):
            return session.libraryWorkspace?.collections.first(where: { $0.value.id == id })?.value.name
                ?? "Collection"
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { session.libraryWorkspace?.query ?? "" },
            set: { value in session.libraryWorkspace?.updateQuery(value) }
        )
    }

    /// ⌘[ and ⌘]: the previous or next list in the sidebar, stopping at either end.
    private func moveList(_ offset: Int) {
        let collections = session.libraryWorkspace?.collections.map(\.value.id) ?? []
        guard let next = LibrarySidebar.scope(offset, from: selectedScope ?? .recentClips, collections: collections)
        else { return }
        selectedScope = next
    }

    /// View › Show Sidebar / Hide Sidebar: an explicit choice, kept whatever the window's width.
    private func toggleSidebar() {
        sidebarPreference = LibraryLayoutPolicy.preference(toggling: sidebarVisibility)
        updateSidebar(for: availableWidth)
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
        let requestedScope = selectedScope ?? .recentClips
        guard requestedScope != .recentlyDeleted else { return }
        Task {
            await session.libraryWorkspace?.startNew(in: requestedScope)
            guard commands.focusGeneration == focusGeneration else { return }
            guard let editor = session.libraryWorkspace?.editor else { return }
            bodyFocus.request(
                sessionID: editor.sessionID,
                documentID: editor.draftID,
                generation: focusGeneration
            )
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
            if !recentStyle, !selectedEntryIDs.isEmpty {
                selectionActionBar(workspace)
                Divider()
            }
            if workspace.entries.isEmpty, !workspace.isLoading {
                emptyList(workspace, recentStyle: recentStyle)
            } else {
                List(workspace.entries, selection: entrySelection(workspace, recentStyle: recentStyle)) { entry in
                    LibraryEntryRow(entry: entry)
                        .tag(entry.id)
                        .accessibilityIdentifier(recentStyle ? "RecentClipRow" : "LibraryEntryRow")
                        .contextMenu {
                            entryActions(for: contextEntries(entry, workspace: workspace), workspace: workspace)
                        }
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

    /// What an empty list holds and how things get there; a search that finds nothing says so in the system's words.
    @ViewBuilder
    private func emptyList(_ workspace: LibraryWorkspace, recentStyle: Bool) -> some View {
        if !workspace.query.isEmpty, searchScope == .thisView {
            ContentUnavailableView {
                Label("No Results for “\(workspace.query)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling or try a new search.")
            } actions: {
                Button("Search All Content") { searchScope = .allContent }
            }
            .accessibilityIdentifier("LibrarySearchEmptyState")
        } else if !workspace.query.isEmpty {
            ContentUnavailableView.search(text: workspace.query)
                .accessibilityIdentifier("LibrarySearchEmptyState")
        } else {
            let empty = LibraryEmptyList.make(
                for: recentStyle ? .recentClips : selectedScope ?? .allSnippets, named: currentScopeTitle
            )
            ContentUnavailableView {
                Label(empty.title, systemImage: empty.symbol)
            } description: {
                Text(empty.message)
            } actions: {
                if empty.offersNewSnippet {
                    Button("New Snippet") { commands.requestNewSnippet() }
                }
            }
            .accessibilityIdentifier(empty.identifier)
        }
    }

    private func entrySelection(
        _ workspace: LibraryWorkspace,
        recentStyle: Bool
    ) -> Binding<Set<ItemID>> {
        Binding(
            get: {
                if recentStyle { return selectedItemID.map { [$0] } ?? [] }
                return selectedEntryIDs
            },
            set: { itemIDs in
                if recentStyle {
                    selectedItemID = itemIDs.first
                    return
                }
                selectedEntryIDs = itemIDs
                if itemIDs.count == 1, let itemID = itemIDs.first {
                    Task { await workspace.select(itemID) }
                }
            }
        )
    }

    private func selectionActionBar(_ workspace: LibraryWorkspace) -> some View {
        HStack(spacing: 12) {
            Text("\(selectedActionEntries(workspace).count) selected")
                .font(.callout.weight(.medium))
            Spacer()
            selectionActionsMenu(entries: selectedActionEntries(workspace), workspace: workspace)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func selectionActionsMenu(
        entries: [LibraryEntry],
        workspace: LibraryWorkspace
    ) -> some View {
        Menu {
            entryActions(for: entries, workspace: workspace)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .disabled(entries.isEmpty)
        .accessibilityLabel("Actions for \(entries.count) selected items")
        .accessibilityIdentifier("SelectionActions")
    }

    @ViewBuilder
    private func entryActions(for entries: [LibraryEntry], workspace: LibraryWorkspace) -> some View {
        let refs = entries.map(\.ref)
        let canOrganize = !entries.isEmpty && entries.allSatisfy { $0.ref.facet == .memo }
        let removesFavorite = !entries.isEmpty && entries.allSatisfy(\.isFavorite)

        Button(removesFavorite ? "Remove from Favorites" : "Add to Favorites") {
            Task { _ = await workspace.setFavorite(refs, isFavorite: !removesFavorite) }
        }
        .disabled(!canOrganize)

        Menu("Move To") {
            Button("Move to Unfiled") {
                Task { _ = await workspace.moveItems(refs, to: nil) }
            }
            ForEach(workspace.collections, id: \.value.id) { collection in
                Button("Move to \(collection.value.name)") {
                    Task { _ = await workspace.moveItems(refs, to: collection) }
                }
            }
        }
        .disabled(!canOrganize)

        Divider()
        Button("Move to Recently Deleted", role: .destructive) {
            moveToRecentlyDeleted(entries, workspace: workspace)
        }
        .disabled(entries.isEmpty || session.maintenance == nil)
    }

    private func moveToRecentlyDeleted(_ entries: [LibraryEntry], workspace: LibraryWorkspace) {
        guard let maintenance = session.maintenance, !entries.isEmpty else { return }
        Task {
            for entry in entries {
                let removed = await workspace.moveToRecentlyDeleted(entry.ref) { ref in
                    await maintenance.remove(ref)
                }
                guard removed else { break }
            }
            selectedEntryIDs.removeAll()
            selectedItemID = nil
        }
    }

    private func selectedActionEntries(_ workspace: LibraryWorkspace) -> [LibraryEntry] {
        workspace.entries.filter { selectedEntryIDs.contains($0.id) }
    }

    private func contextEntries(_ entry: LibraryEntry, workspace: LibraryWorkspace) -> [LibraryEntry] {
        if selectedEntryIDs.contains(entry.id) {
            let selected = selectedActionEntries(workspace)
            if !selected.isEmpty { return selected }
        }
        return [entry]
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

    private func formatSummary(_ content: ResolvedContent) -> String {
        let itemCount = Set(content.representations.map(\.itemIndex)).count
        let formatCount = content.representations.count
        return "\(itemCount) item\(itemCount == 1 ? "" : "s") • \(formatCount) format\(formatCount == 1 ? "" : "s")"
    }

    private func editorContentKind(
        _ editor: MemoEditorSession,
        in workspace: LibraryWorkspace
    ) -> ContentKind {
        guard let ref = editor.ref else { return .text }
        return workspace.entries.first(where: { $0.ref == ref })?.kind
            ?? workspace.entries.first(where: { $0.id == ref.itemID })?.kind
            ?? .text
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
            Spacer(minLength: 4)
            if entry.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .help("Favorite")
                    .accessibilityLabel("Favorite")
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
    let contentKind: ContentKind
    let previewService: PreviewService?
    let fileAccessStore: FileAccessStore?
    let fileAccessIdentity: StoreIdentity?
    let bodyFocusRequest: Int
    let shouldFocusBody: @MainActor () -> Bool
    let onBodyFocusAccepted: @MainActor (UUID, UUID, Int) -> Void
    @State private var markdownMode = MarkdownReadingMode.source

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let ref = editor.ref, showsTypedPreview {
                LibraryContentPreview(
                    ref: ref,
                    kind: contentKind,
                    service: previewService,
                    fileAccessStore: fileAccessStore,
                    fileAccessIdentity: fileAccessIdentity
                )
            } else if let body = editor.body {
                ZStack {
                    EditorBridge(
                        documentID: editor.draftID,
                        text: body,
                        isCode: editor.kind == .code,
                        isEditable: canEditSource,
                        focusRequest: bodyFocusRequest,
                        shouldFocus: { canEditSource && shouldFocusBody() },
                        onChange: { value, isComposing in
                            editor.setBody(value, isComposing: isComposing)
                        },
                        onFocusLost: {
                            Task { _ = try? await workspace.focusLost() }
                        },
                        onFocusAccepted: { documentID, request in
                            onBodyFocusAccepted(editor.sessionID, documentID, request)
                        }
                    )
                    .id(editor.sessionID)
                    .opacity(isShowingMarkdownPreview ? 0 : 1)
                    .allowsHitTesting(!isShowingMarkdownPreview)
                    .accessibilityHidden(isShowingMarkdownPreview)
                    .accessibilityIdentifier("SnippetBodyEditor")

                    if isShowingMarkdownPreview {
                        MarkdownReadingView(documentID: editor.draftID, source: body)
                            .background(Color(nsColor: .textBackgroundColor))
                    }
                }
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
        .onChange(of: editor.kind) { _, kind in
            if kind != .markdown { markdownMode = .source }
        }
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
                .accessibilityIdentifier("SnippetKindPicker")

                if editor.kind == .markdown, editor.body != nil {
                    Picker("Markdown view", selection: markdownModeBinding) {
                        Text("Source")
                            .tag(MarkdownReadingMode.source)
                            .accessibilityIdentifier("MarkdownModeSource")
                        Text("Preview")
                            .tag(MarkdownReadingMode.preview)
                            .accessibilityIdentifier("MarkdownModePreview")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(editor.isComposing || activeTextViewIsComposing)
                    .accessibilityIdentifier("MarkdownModePicker")
                    .help(
                        editor.isComposing || activeTextViewIsComposing
                            ? "Finish text composition before changing view"
                            : "Switch Markdown view"
                    )
                }

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

    private var markdownModeBinding: Binding<MarkdownReadingMode> {
        Binding(
            get: { markdownMode },
            set: { mode in
                guard !editor.isComposing, !activeTextViewIsComposing else { return }
                markdownMode = mode
            }
        )
    }

    private var activeTextViewIsComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private var isShowingMarkdownPreview: Bool {
        editor.kind == .markdown && markdownMode == .preview
    }

    private var canEditSource: Bool {
        !editor.isReadOnly && !workspace.isClosing && !isShowingMarkdownPreview
    }

    private var showsTypedPreview: Bool {
        LibraryContentPresentation.showsTypedPreview(
            isReadOnly: editor.isReadOnly,
            hasBody: editor.body != nil,
            kind: contentKind
        )
    }
}

enum LibraryContentPresentation {
    nonisolated static func showsTypedPreview(
        isReadOnly: Bool,
        hasBody: Bool,
        kind: ContentKind
    ) -> Bool {
        guard hasBody else { return true }
        guard isReadOnly else { return false }
        return kind == .url || kind == .image || kind == .file
    }
}

private struct ComposingTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let isEditable: Bool
    let font: NSFont
    let onChange: @MainActor (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        // Read-only NSTextFields otherwise insist on the full title's intrinsic
        // width, expanding the entire split-view detail beyond its visible column.
        return CGSize(width: width, height: proposal.height ?? nsView.fittingSize.height)
    }

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

/// What an empty list says.
private struct LibraryEmptyList {
    let title: String
    let message: String
    let symbol: String
    let identifier: String
    let offersNewSnippet: Bool

    static func make(for scope: LibraryScope, named name: String) -> LibraryEmptyList {
        switch scope {
        case .recentClips:
            LibraryEmptyList(title: "No Recent Clips", message: "New copies appear here while Keeptide is running.",
                             symbol: "clock", identifier: "RecentClipsEmptyState", offersNewSnippet: false)
        case .favorites:
            LibraryEmptyList(title: "No Favorites", message: "Snippets you mark as favorites appear here.",
                             symbol: "star", identifier: "FavoritesEmptyState", offersNewSnippet: false)
        case .uncategorized:
            LibraryEmptyList(title: "Nothing Unfiled", message: "Every snippet is in a collection.",
                             symbol: "tray", identifier: "UnfiledEmptyState", offersNewSnippet: false)
        case .collection:
            LibraryEmptyList(title: "No Snippets in “\(name)”", message: "Move snippets here, or write a new one.",
                             symbol: "folder", identifier: "CollectionEmptyState", offersNewSnippet: true)
        case .allSnippets, .recentlyDeleted:
            LibraryEmptyList(title: "No Snippets", message: "Save a clip with ⌘S, or write a new one.",
                             symbol: "bookmark", identifier: "SnippetsEmptyState", offersNewSnippet: true)
        }
    }
}
