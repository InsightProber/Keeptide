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
    /// The rows selected in every list but Recently Deleted. Exactly one opens in the editor.
    @State private var selectedEntryIDs: Set<ItemID> = []
    @State private var inspectorPresented = false
    @State private var applicationNames = ApplicationNames()
    /// A snippet or clip to select once its list shows: Show Snippet, Show in Recent Clips and quick access's Show in
    /// Library switch lists first.
    @State private var pendingReveal: ContentRef?
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
                    .inspector(isPresented: $inspectorPresented) {
                        inspector
                            .inspectorColumnWidth(min: 220, ideal: 250, max: 320)
                    }
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
        .onChange(of: selectedScope) { previous, scope in
            // A list cannot be deselected: the one chosen stays, and so do the subtitle and the library's list.
            guard let scope else {
                selectedScope = previous
                return
            }
            guard previous != nil else { return }
            selectedEntryIDs.removeAll()
            updateExportContext()
            session.libraryWorkspace?.updateScope(scope)
            revealPending()
        }
        .onChange(of: selectedEntryIDs) { _, _ in updateExportContext() }
        .onChange(of: session.libraryWorkspace?.entries.map(\.ref) ?? []) { _, _ in
            updateExportContext()
        }
    }

    /// The sidebar's commands, and what the window and its menus show of the list chosen.
    private var listLibrary: some View {
        selectionLibrary
        // The window's subtitle names the list. SwiftUI's toolbar bridge writes the subtitle from this, when the view
        // joins the window and as its bars change, and the controller writes it as the list changes: both the same.
        .navigationSubtitle(listSubtitle)
        .onChange(of: listSubtitle, initial: true) { _, subtitle in commands.showListTitle(subtitle) }
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
            // The library changed lists itself: it left a deleted collection, or Unfiled with the last collection, or it
            // went to the list a new snippet or Show in Library shows.
            guard previous != nil, let scope, scope != selectedScope else { return }
            selectedScope = scope
        }
        .onChange(of: session.libraryWorkspace?.revealed) { _, reveal in
            // Show in Library from quick access: the sidebar takes the item's list first, then the list takes its row.
            guard let reveal else { return }
            pendingReveal = reveal.ref
            if selectedScope == reveal.scope { revealPending() } else { selectedScope = reveal.scope }
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

    /// The item commands from the menus act on the selection; the menus show what it allows.
    private var itemLibrary: some View {
        listLibrary
        .onChange(of: itemContext, initial: true) { _, context in commands.updateItemContext(context) }
        .onChange(of: commands.favoriteRequest) { _, _ in toggleFavorite() }
        .onChange(of: commands.collectionRequest) { _, request in
            guard let request else { return }
            if request.createsCollection {
                collectionEditorMode = .create
            } else {
                file(into: request.collectionID)
            }
        }
        .onChange(of: commands.kindRequest) { _, request in
            guard let request else { return }
            session.libraryWorkspace?.editor?.setKind(request.kind)
        }
        .onChange(of: commands.showLinkedRequest) { _, _ in
            if let linked = selectionState.linked { show(linked) }
        }
        .onChange(of: commands.deleteRequest) { _, _ in
            guard let workspace = session.libraryWorkspace else { return }
            moveToRecentlyDeleted(selectedEntries(workspace), workspace: workspace)
        }
        .onChange(of: commands.inspectorToggleRequest) { _, _ in inspectorPresented.toggle() }
    }

    var body: some View {
        itemLibrary
        .onChange(of: commands.newSnippetRequest) { _, _ in
            startNewSnippet(focusGeneration: commands.newSnippetFocusGeneration)
        }
        .onChange(of: commands.saveRequest) { _, _ in saveCurrentEditor() }
        .onChange(of: commands.copyRequest) { _, _ in copyCurrentEditor() }
        .onChange(of: commands.openRequest) { _, request in
            guard let request else { return }
            Task { await session.libraryWorkspace?.open(request) }
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
        return selectedEntries(workspace).map(\.ref)
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
        } else if let workspace = session.libraryWorkspace {
            snippetList(workspace, recentStyle: selectedScope == .recentClips)
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

    /// The open item, or what the selection is when no single item is open: several items, one that could not be read,
    /// or none.
    @ViewBuilder
    private var detailColumn: some View {
        if selectedScope == .recentlyDeleted {
            ContentUnavailableView { Text("No Item Selected") }
                .accessibilityIdentifier("RecentlyDeletedDetail")
        } else if let workspace = session.libraryWorkspace, selectedEntryIDs.count > 1 {
            ContentUnavailableView { Text(multipleSelectionTitle(workspace)) }
                .accessibilityIdentifier("LibraryMultipleSelection")
        } else if let workspace = session.libraryWorkspace, let selected = selectedEntryIDs.first,
                  workspace.unavailableItemID == selected {
            ContentUnavailableView {
                Label(selectedScope == .recentClips ? "Clip Unavailable" : "Item Unavailable",
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text("It may have been deleted or changed elsewhere.")
            }
            .accessibilityIdentifier("LibraryItemUnavailable")
        } else if let workspace = session.libraryWorkspace, let editor = workspace.editor {
            let focusRequest = bodyFocus.request(for: editor.sessionID, documentID: editor.draftID)
            MemoEditorView(
                editor: editor,
                workspace: workspace,
                contentKind: editorContentKind(editor, in: workspace),
                previewService: session.previewService,
                fileAccessStore: session.fileAccessStore,
                fileAccessIdentity: session.fileAccessIdentity,
                applicationNames: applicationNames,
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
                },
                onShowInspector: { inspectorPresented = true },
                onShow: { ref in show(ref) }
            )
            .id(editor.sessionID)
        } else {
            ContentUnavailableView { Text(selectedScope == .recentClips ? "No Clip Selected" : "No Snippet Selected") }
        }
    }

    /// Info (⌃⌘I): the open snippet's type, collection, favorite mark and note, and the open item's details.
    @ViewBuilder
    private var inspector: some View {
        if let workspace = session.libraryWorkspace, selectedScope != .recentlyDeleted {
            LibraryInspector(workspace: workspace, selectionCount: selectedEntryIDs.count,
                             applicationNames: applicationNames, onShow: { show($0) })
        } else {
            Form {
                Text("No Item Selected").foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("LibraryInspector")
        }
    }

    /// "3 Clips Selected", "2 Snippets Selected", or "4 Items Selected" for clips and snippets found together.
    private func multipleSelectionTitle(_ workspace: LibraryWorkspace) -> String {
        let facets = Set(selectedEntries(workspace).map(\.ref.facet))
        let noun = facets == [.history] ? "Clips" : facets == [.memo] ? "Snippets" : "Items"
        return "\(selectedEntryIDs.count) \(noun) Selected"
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
            // From Recently Deleted too: the new snippet goes to Unfiled, and All Snippets shows it.
            .disabled(session.libraryWorkspace == nil)
        }
    }

    /// Over the detail: what acts on the selection, the same four items whatever is selected, then Info and the
    /// system's search item, which the system keeps last.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        let state = selectionState
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            Button { copySelection() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help(state.copyHelp)
            .accessibilityIdentifier("CopyLibraryItem")
            .disabled(!state.canCopy)

            Button { saveSelection() } label: {
                Label("Save as Snippet", systemImage: "bookmark")
            }
            .help(state.saveHelp)
            .accessibilityIdentifier("SaveHistoryAsSnippet")
            .disabled(!state.canSave)

            Button { toggleFavorite() } label: {
                Label(state.favoriteTitle, systemImage: state.isFavorite ? "star.fill" : "star")
            }
            .help(state.favoriteTitle)
            .accessibilityIdentifier("SnippetFavoriteToggle")
            .disabled(!state.canFavorite)

            Menu {
                collectionMenu(current: state.currentCollections)
            } label: {
                Label(state.collectionTitle, systemImage: "folder")
            }
            .help(state.hasCollections ? state.collectionTitle : "Create a collection first.")
            .accessibilityIdentifier("CollectionMenu")
            .disabled(!state.canFile)
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { inspectorPresented.toggle() } label: {
                Label("Info", systemImage: "info.circle")
            }
            .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
            .accessibilityIdentifier("ToggleInspector")
        }
        DefaultToolbarItem(kind: .search)
    }

    /// Unfiled, the collections and New Collection…, the place of the selection checked. Choosing files it there;
    /// a clip not yet saved is saved into it.
    @ViewBuilder
    private func collectionMenu(current: Set<CollectionID?>) -> some View {
        let collections = session.libraryWorkspace?.collections.map(\.value) ?? []
        ForEach(CollectionMenu.make(collections: collections, current: current)) { entry in
            switch entry.role {
            case .separator:
                Divider()
            case .newCollection:
                Button(entry.title) { collectionEditorMode = .create }
            case .unfiled, .collection:
                Toggle(entry.title, isOn: Binding(
                    get: { entry.isChecked },
                    set: { _ in if !entry.isChecked { file(into: entry.collectionID) } }
                ))
            }
        }
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

    private var listSubtitle: String {
        LibrarySidebar.listSubtitle(for: selectedScope ?? .recentClips, named: currentScopeTitle)
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

    /// ⌘N, here or from quick access: the new snippet goes where the list asked for, or the list shown, puts it, and
    /// that list is shown (`LibraryScope.newSnippetScope`).
    private func startNewSnippet(focusGeneration: Int) {
        let requestedScope = commands.newSnippetScope ?? selectedScope ?? .recentClips
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

    /// ⌘S: saves the snippet being edited, or saves the selected clips as snippets.
    private func saveCurrentEditor() {
        guard let workspace = session.libraryWorkspace else { return }
        guard workspace.editor?.isReadOnly == true else {
            Task { _ = try? await workspace.flush() } // The workspace keeps the draft and says why it failed.
            return
        }
        saveSelection()
    }

    /// ⇧⌘C: the open item, saved first.
    private func copyCurrentEditor() {
        Task { _ = await session.libraryWorkspace?.copyCurrent(mode: .original) }
    }

    // MARK: The selection's actions

    private func selectedEntries(_ workspace: LibraryWorkspace) -> [LibraryEntry] {
        workspace.entries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var selectionState: LibrarySelectionState {
        guard selectedScope != .recentlyDeleted, let workspace = session.libraryWorkspace else {
            return LibrarySelectionState()
        }
        let open = workspace.editor.flatMap { editor in
            editor.ref.map {
                LibrarySelectionState.OpenItem(ref: $0, details: editor.details, kind: editor.kind,
                                               isReadOnly: editor.isReadOnly)
            }
        }
        var entries = selectedEntries(workspace)
        if selectedEntryIDs.isEmpty, let open {
            // Nothing selected, as after writing a new snippet: the actions apply to the item the detail shows.
            entries = [workspace.entries.first { $0.ref == open.ref } ?? LibraryEntry(
                id: open.ref.itemID, ref: open.ref, title: "", snippet: nil, lastCopiedAt: Date(), kind: .text,
                isMemo: open.ref.facet == .memo
            )]
        }
        // Only selected rows move to Recently Deleted, from the list.
        return .make(entries: entries, open: open, hasCollections: !workspace.collections.isEmpty,
                     canDelete: session.maintenance != nil && !selectedEntryIDs.isEmpty)
    }

    private var itemContext: LibraryItemContext {
        let state = selectionState
        return LibraryItemContext(
            selection: state,
            collectionEntries: CollectionMenu.make(
                collections: session.libraryWorkspace?.collections.map(\.value) ?? [],
                current: state.currentCollections
            ),
            inspectorIsPresented: inspectorPresented,
            isRecentlyDeleted: selectedScope == .recentlyDeleted
        )
    }

    private func copySelection() {
        guard let workspace = session.libraryWorkspace, let ref = selectionState.refs.first else { return }
        Task { _ = await workspace.copy(ref) }
    }

    private func saveSelection() {
        guard let workspace = session.libraryWorkspace else { return }
        let refs = selectionState.refs.isEmpty ? [workspace.editor?.ref].compactMap { $0 } : selectionState.refs
        Task { await workspace.saveAsSnippets(refs) }
    }

    /// ⌘D and the toolbar's star: a clip not yet saved is saved as a favorite snippet.
    private func toggleFavorite() {
        let state = selectionState
        guard state.canFavorite, !state.refs.isEmpty, let workspace = session.libraryWorkspace else { return }
        Task { await workspace.setFavorite(of: state.refs, to: !state.isFavorite) }
    }

    private func file(into collectionID: CollectionID?) {
        guard let workspace = session.libraryWorkspace else { return }
        let refs = selectionState.refs
        let collection = collectionID.flatMap { id in workspace.collections.first { $0.value.id == id } }
        guard !refs.isEmpty, collectionID == nil || collection != nil else { return }
        Task { await workspace.file(refs, into: collection) }
    }

    /// Show Snippet and Show in Recent Clips: the list that holds `ref`, with it selected and open.
    private func show(_ ref: ContentRef) {
        let scope: LibraryScope = ref.facet == .memo ? .allSnippets : .recentClips
        pendingReveal = ref
        if selectedScope == scope { revealPending() } else { selectedScope = scope }
    }

    private func revealPending() {
        guard let ref = pendingReveal else { return }
        pendingReveal = nil
        selectedEntryIDs = [ref.itemID]
        Task { await session.libraryWorkspace?.open(ref) }
    }

    /// ⌫ in a list: in a collection the selection leaves the collection, as an album's photos leave the album;
    /// elsewhere it moves to Recently Deleted.
    private func deleteFromList(_ workspace: LibraryWorkspace) {
        let entries = selectedEntries(workspace)
        guard !entries.isEmpty else { return }
        if selectedScope?.collectionID != nil {
            Task { await workspace.removeFromCollection(entries.map(\.ref)) }
        } else {
            moveToRecentlyDeleted(entries, workspace: workspace)
        }
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
            actionStatusLine(workspace)
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
                emptyList(workspace, recentStyle: recentStyle)
            } else {
                List(workspace.entries, selection: entrySelection(workspace)) { entry in
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
                .onDeleteCommand { deleteFromList(workspace) }
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

    /// Every list selects several rows; exactly one opens in the editor.
    private func entrySelection(_ workspace: LibraryWorkspace) -> Binding<Set<ItemID>> {
        Binding(
            get: { selectedEntryIDs },
            set: { itemIDs in
                selectedEntryIDs = itemIDs
                if itemIDs.count == 1, let itemID = itemIDs.first {
                    Task { await workspace.select(itemID) }
                }
            }
        )
    }

    /// A row's context menu acts on the selection when the row is in it, and on the row alone otherwise.
    @ViewBuilder
    private func entryActions(for entries: [LibraryEntry], workspace: LibraryWorkspace) -> some View {
        let refs = entries.map(\.ref)
        let open = workspace.editor.flatMap { editor in
            editor.ref.map {
                LibrarySelectionState.OpenItem(ref: $0, details: editor.details, kind: editor.kind,
                                               isReadOnly: editor.isReadOnly)
            }
        }
        let state = LibrarySelectionState.make(entries: entries, open: open,
                                               hasCollections: !workspace.collections.isEmpty,
                                               canDelete: session.maintenance != nil)
        Button("Copy") {
            guard let ref = refs.first else { return }
            Task { _ = await workspace.copy(ref) }
        }
        .disabled(!state.canCopy)
        if state.savesIntoCollection {
            Button("Save as Snippet") { Task { await workspace.saveAsSnippets(refs) } }
                .disabled(!state.canSave)
        }
        Menu(state.collectionTitle) {
            ForEach(CollectionMenu.make(collections: workspace.collections.map(\.value),
                                        current: state.currentCollections)) { entry in
                switch entry.role {
                case .separator:
                    Divider()
                case .newCollection:
                    Button(entry.title) { collectionEditorMode = .create }
                case .unfiled, .collection:
                    Toggle(entry.title, isOn: Binding(get: { entry.isChecked }, set: { _ in
                        guard !entry.isChecked else { return }
                        let collection = entry.collectionID.flatMap { id in
                            workspace.collections.first { $0.value.id == id }
                        }
                        Task { await workspace.file(refs, into: collection) }
                    }))
                }
            }
        }
        .disabled(entries.isEmpty)
        Button(state.favoriteTitle) {
            Task { await workspace.setFavorite(of: refs, to: !state.isFavorite) }
        }
        .disabled(!state.canFavorite)
        if let linked = state.linked {
            Divider()
            Button(state.linkedTitle) { show(linked) }
        }
        Divider()
        Button("Move to Recently Deleted", role: .destructive) {
            moveToRecentlyDeleted(entries, workspace: workspace)
        }
        .disabled(!state.canDelete)
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
        }
    }

    private func contextEntries(_ entry: LibraryEntry, workspace: LibraryWorkspace) -> [LibraryEntry] {
        if selectedEntryIDs.contains(entry.id) {
            let selected = selectedEntries(workspace)
            if !selected.isEmpty { return selected }
        }
        return [entry]
    }

    /// What the last action did ("Copied", "Saved to “Prompts”"), or why the clips could not be read, at the top of
    /// every list but Recently Deleted.
    @ViewBuilder
    private func actionStatusLine(_ workspace: LibraryWorkspace) -> some View {
        if let actionMessage = workspace.actionMessage ?? session.actionMessage {
            VStack(spacing: 0) {
                Label(actionMessage, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("CaptureActionStatus")
                Divider()
            }
        }
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
    let applicationNames: ApplicationNames
    let bodyFocusRequest: Int
    let shouldFocusBody: @MainActor () -> Bool
    let onBodyFocusAccepted: @MainActor (UUID, UUID, Int) -> Void
    /// Opens the inspector: the header's type, collection and note answer a click there.
    let onShowInspector: () -> Void
    /// Show Snippet and Show in Recent Clips.
    let onShow: (ContentRef) -> Void
    @State private var markdownMode = MarkdownReadingMode.source

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let integrity = editor.details?.integrity, integrity != .complete {
                LibraryItemText.unavailableContent(integrity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let ref = editor.ref, showsTypedPreview {
                LibraryContentPreview(
                    ref: ref,
                    kind: contentKind,
                    service: previewService,
                    fileAccessStore: fileAccessStore,
                    fileAccessIdentity: fileAccessIdentity,
                    applicationName: editor.details?.sourceApp.flatMap { applicationNames.name(for: $0) }
                )
            } else if let body = editor.body {
                if editor.kind == .markdown {
                    markdownBar
                    Divider()
                }
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
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: editor.kind) { _, kind in
            if kind != .markdown { markdownMode = .source }
        }
    }

    /// The title, and one line about the item under it. Actions are in the toolbar and the menus, not here.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ComposingTextField(
                text: editor.title,
                placeholder: editor.ref?.facet == .history ? "Clipboard Item" : "Untitled Snippet",
                isEditable: !editor.isReadOnly,
                font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold),
                onChange: editor.setTitle
            )
            .frame(height: 30)
            .accessibilityIdentifier("SnippetTitleEditor")

            metadataLine
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A clip: "Text · Safari · 3 formats · Copied 2 hours ago", and Show Snippet once it is saved. A snippet:
    /// "★ Markdown snippet · ● Prompts · Created yesterday", its note, Show in Recent Clips while its clip is there,
    /// and how saving goes.
    private var metadataLine: some View {
        HStack(spacing: 8) {
            if editor.ref?.facet == .history {
                Text(clipMetadata)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let snippet = editor.details?.savedSnippet {
                    Button("Show Snippet") { onShow(snippet.ref) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("OpenSavedSnippet")
                }
            } else {
                Button(action: onShowInspector) {
                    Text(snippetMetadata)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Show Inspector")
                .accessibilityIdentifier("SnippetMetadata")
                if !editor.note.isEmpty {
                    Button(action: onShowInspector) {
                        Label("Note", systemImage: "note.text")
                    }
                    .buttonStyle(.plain)
                    .help(editor.note)
                    .accessibilityIdentifier("SnippetNoteLink")
                }
                if case .available(let clip)? = editor.details?.originalClip {
                    Button("Show in Recent Clips") { onShow(clip) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("ShowInRecentClips")
                }
            }
            Spacer(minLength: 0)
            statusLabel
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(minHeight: 18)
    }

    private var clipMetadata: String {
        var parts = [contentKind.accessibilityName]
        if let details = editor.details {
            if let app = details.sourceApp.flatMap({ applicationNames.name(for: $0) }) { parts.append(app) }
            parts.append(details.integrity == .complete
                ? LibraryItemText.formats(details.formatCount)
                : LibraryItemText.integritySummary(details.integrity))
            parts.append("Copied \(details.lastCopiedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var snippetMetadata: AttributedString {
        let details = editor.details
        var line = AttributedString((details?.isFavorite == true ? "★ " : "") + LibraryItemText.snippetName(editor.kind))
        let collectionID = editor.ref == nil ? editor.collectionID : details?.collectionID
        if let collection = workspace.collections.first(where: { $0.value.id == collectionID })?.value {
            var dot = AttributedString(" · ● ")
            dot.foregroundColor = Color.collection(collection.color)
            line += dot + AttributedString(collection.name)
        }
        if let created = details?.createdAt {
            line += AttributedString(" · Created \(created.formatted(.relative(presentation: .named)))")
        }
        return line
    }

    /// Source or Preview for a Markdown snippet, over its body, apart from the header.
    private var markdownBar: some View {
        HStack {
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
            .controlSize(.small)
            .frame(width: 160)
            .disabled(editor.isComposing || activeTextViewIsComposing)
            .accessibilityIdentifier("MarkdownModePicker")
            .help(
                editor.isComposing || activeTextViewIsComposing
                    ? "Finish text composition before changing view"
                    : "Switch Markdown view"
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(height: 28)
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

/// The inspector's grouped form. Type, collection, favorite and note belong to the open snippet; Details describe
/// the open item. Several selected items have no single set of details.
private struct LibraryInspector: View {
    @Bindable var workspace: LibraryWorkspace
    let selectionCount: Int
    let applicationNames: ApplicationNames
    let onShow: (ContentRef) -> Void

    var body: some View {
        Form {
            if selectionCount > 1 {
                Text("Select one snippet to edit its details.")
                    .foregroundStyle(.secondary)
            } else if let editor = workspace.editor {
                if !editor.isReadOnly { snippetSection(editor) }
                detailsSection(editor)
            } else {
                Text("No Item Selected")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("LibraryInspector")
    }

    private func snippetSection(_ editor: MemoEditorSession) -> some View {
        Section("Snippet") {
            Picker("Type", selection: Binding(get: { editor.kind }, set: { editor.setKind($0) })) {
                Text("Text").tag(MemoKind.plainText)
                Text("Prompt").tag(MemoKind.prompt)
                Text("Code").tag(MemoKind.code)
                Text("Markdown").tag(MemoKind.markdown)
            }
            .accessibilityIdentifier("SnippetKindPicker")

            Picker("Collection", selection: collectionBinding(editor)) {
                Text(CollectionMenu.unfiledTitle).tag(CollectionID?.none)
                ForEach(workspace.collections, id: \.value.id) { collection in
                    Text(collection.value.name).tag(CollectionID?.some(collection.value.id))
                }
            }
            .accessibilityIdentifier("CollectionPicker")

            // A new snippet is marked once it is saved.
            Toggle("Favorite", isOn: Binding(
                get: { editor.details?.isFavorite == true },
                set: { value in
                    guard let ref = editor.ref else { return }
                    Task { await workspace.setFavorite(of: [ref], to: value) }
                }
            ))
            .disabled(editor.ref == nil)
            .accessibilityIdentifier("InspectorFavoriteToggle")

            LabeledContent("Note") {
                ComposingTextField(
                    text: editor.note,
                    placeholder: "Optional note",
                    isEditable: true,
                    font: .preferredFont(forTextStyle: .body),
                    isBezeled: true,
                    onChange: editor.setNote
                )
                .frame(height: 22)
                .accessibilityIdentifier("SnippetNoteEditor")
            }
        }
    }

    /// A new snippet is created in the collection chosen; a saved one moves there.
    private func collectionBinding(_ editor: MemoEditorSession) -> Binding<CollectionID?> {
        Binding(
            get: { editor.ref == nil ? editor.collectionID : editor.details?.collectionID },
            set: { id in
                guard let ref = editor.ref else {
                    editor.setCollectionID(id)
                    return
                }
                let collection = id.flatMap { id in workspace.collections.first { $0.value.id == id } }
                Task { await workspace.file([ref], into: collection) }
            }
        )
    }

    @ViewBuilder
    private func detailsSection(_ editor: MemoEditorSession) -> some View {
        if let details = editor.details {
            Section("Details") {
                if editor.ref?.facet == .history {
                    if let app = details.sourceApp {
                        LabeledContent("Source", value: applicationNames.name(for: app) ?? app)
                    }
                    LabeledContent("Created", value: details.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Last Copied",
                                   value: details.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Copies", value: details.copyCount.formatted())
                    if details.integrity == .complete {
                        LabeledContent("Formats", value: details.formatCount.formatted())
                        LabeledContent("Size",
                                       value: ByteCountFormatter.string(fromByteCount: details.byteCount, countStyle: .file))
                    } else {
                        LabeledContent("Formats", value: LibraryItemText.integritySummary(details.integrity))
                    }
                } else {
                    LabeledContent("Created", value: details.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let original = details.originalClip {
                        LabeledContent("Original Clip") { originalClip(original) }
                    }
                    if editor.richSourceWarning {
                        Text("Edits are saved as plain text. The original clip keeps its formats.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func originalClip(_ state: LibraryItemDetails.OriginalClip) -> some View {
        switch state {
        case .available(let clip):
            VStack(alignment: .trailing, spacing: 2) {
                Text("Formats kept in Recent Clips")
                Button("Show in Recent Clips") { onShow(clip) }
                    .buttonStyle(.link)
            }
        case .recentlyDeleted(let until):
            Text("Clip in Recently Deleted until \(until.formatted(date: .abbreviated, time: .omitted))")
        case .gone:
            Text("Clip expired")
        }
    }
}

/// What the library says about an item's content: in the header, the inspector and in place of a body.
enum LibraryItemText {
    static func integritySummary(_ integrity: ContentIntegrity) -> String {
        switch integrity {
        case .complete: "Original formats available"
        case .requiresRelocation: "File access required"
        case .recovering: "Content is still recovering"
        case .corrupt: "Content is unavailable"
        }
    }

    static func formats(_ count: Int) -> String {
        count == 1 ? "1 format" : "\(count) formats"
    }

    static func snippetName(_ kind: MemoKind) -> String {
        switch kind {
        case .plainText: "Text snippet"
        case .prompt: "Prompt snippet"
        case .code: "Code snippet"
        case .markdown: "Markdown snippet"
        }
    }

    @MainActor @ViewBuilder
    static func unavailableContent(_ integrity: ContentIntegrity) -> some View {
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
}

/// What the selection allows. The toolbar's current-item group, the Item menu and a row's context menu all read
/// this one answer. The editor speaks for the selection only while it holds the one item selected.
struct LibrarySelectionState: Equatable {
    struct OpenItem: Equatable {
        var ref: ContentRef
        var details: LibraryItemDetails?
        var kind: MemoKind
        var isReadOnly: Bool
    }

    var refs: [ContentRef] = []
    var canCopy = false
    var copyHelp = "Copy Entire Item"
    var canSave = false
    var saveHelp = "Save as Snippet"
    var canFavorite = false
    var isFavorite = false
    var hasCollections = false
    /// The toolbar's collection menu needs a collection to offer; the context menu also offers New Collection….
    var canFile = false
    /// A clip not yet saved is saved into the collection chosen.
    var savesIntoCollection = false
    /// Where the selected snippets are, nil for unfiled: one place is checked in the collection menus.
    var currentCollections: Set<CollectionID?> = []
    /// The open snippet's type; nil when no type can be chosen.
    var kind: MemoKind?
    /// The open clip's snippet, or the open snippet's clip while it is in Recent Clips.
    var linked: ContentRef?
    var canDelete = false

    var favoriteTitle: String { isFavorite ? "Remove from Favorites" : "Add to Favorites" }
    var collectionTitle: String { savesIntoCollection ? "Save to Collection" : "Move to Collection" }
    var linkedTitle: String { linked?.facet == .history ? "Show in Recent Clips" : "Show Snippet" }

    static func make(
        entries: [LibraryEntry], open: OpenItem?, hasCollections: Bool, canDelete: Bool
    ) -> LibrarySelectionState {
        var state = LibrarySelectionState()
        state.refs = entries.map(\.ref)
        state.hasCollections = hasCollections
        guard !entries.isEmpty else { return state }
        let open = entries.count == 1 && open?.ref.itemID == entries[0].id ? open : nil
        let details = open?.details
        // A clip whose formats cannot all be read is neither copied nor saved.
        let unreadable = (details?.integrity ?? .complete) != .complete
        let clips = entries.filter { $0.ref.facet == .history }
        let unsavedClips = clips.filter { clip in
            guard let open, open.ref.itemID == clip.id else { return !clip.isMemo }
            return open.ref.facet == .history && details?.savedSnippet == nil
        }

        state.canCopy = entries.count == 1 && !unreadable
        state.copyHelp = entries.count > 1 ? "Select one item to copy."
            : unreadable ? "This clip can't be copied until its content is available." : "Copy Entire Item"
        state.canSave = clips.count == entries.count && !unsavedClips.isEmpty && !unreadable
        state.saveHelp = unreadable ? "This clip can't be saved until its content is available."
            : clips.count == entries.count && unsavedClips.isEmpty ? "Already in Snippets" : "Save as Snippet"
        state.canFavorite = !unreadable
        state.canFile = hasCollections && !unreadable
        state.savesIntoCollection = !unsavedClips.isEmpty
        state.canDelete = canDelete
        if let open {
            switch open.ref.facet {
            case .history:
                state.isFavorite = details?.savedSnippet?.isFavorite == true
                if let snippet = details?.savedSnippet {
                    state.currentCollections = [snippet.collectionID]
                    state.linked = snippet.ref
                }
            case .memo:
                state.isFavorite = details?.isFavorite == true
                state.currentCollections = [details?.collectionID]
                if !open.isReadOnly { state.kind = open.kind }
                if case .available(let clip)? = details?.originalClip { state.linked = clip }
            }
        } else {
            state.isFavorite = entries.allSatisfy { $0.ref.facet == .memo && $0.isFavorite }
            state.currentCollections = Set(entries.filter { $0.ref.facet == .memo }.map(\.collectionID))
        }
        return state
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
    /// A bordered field, as the inspector's rows have; the header's title is plain text that can be edited.
    var isBezeled = false
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
        field.isBordered = isBezeled
        field.isBezeled = isBezeled
        if isBezeled { field.bezelStyle = .roundedBezel }
        field.drawsBackground = isBezeled
        field.focusRingType = isBezeled ? .default : .none
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
