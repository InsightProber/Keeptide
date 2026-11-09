import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    private static let defaultSize = NSSize(width: 1120, height: 740)
    private static let minimumSize = NSSize(width: 840, height: 560)
    let commands: LibraryWindowCommands
    private let session: CaptureSession
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    var shouldRestoreAccessory: () -> Bool
    private var closesAfterPreparation = false
    private var closePreparationTask: Task<Void, Never>?
    private var isOpen = false

    init(
        session: CaptureSession,
        autosaveName: String? = "KeeptideLibraryWindow",
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        shouldRestoreAccessory: @escaping () -> Bool = { true }
    ) {
        let commands = LibraryWindowCommands()
        self.commands = commands
        self.session = session
        self.setActivationPolicy = setActivationPolicy
        self.shouldRestoreAccessory = shouldRestoreAccessory
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Keeptide Library"
        window.identifier = NSUserInterfaceItemIdentifier("KeeptideLibraryWindow")
        window.setAccessibilityIdentifier("KeeptideLibraryWindow")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        // The title stays the app's; the subtitle names the list, as a document window names its document. The view
        // reports the list as soon as it exists, which can be while its content is made, so this comes first.
        commands.showListTitle = { [weak window] subtitle in window?.subtitle = subtitle }
        window.contentViewController = WindowContentController(
            rootView: LibraryView(session: session, commands: commands),
            size: Self.defaultSize,
            sceneBridgingOptions: .toolbars
        )
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("Close Library")
        window.center()
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        if !isOpen {
            isOpen = true
            setActivationPolicy(.regular)
        }
        session.libraryWorkspace?.resumeAfterCloseCancellation()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func newDocument(_ sender: Any?) { commands.requestNewSnippet() }
    @objc func newCollection(_ sender: Any?) { commands.requestNewCollection() }
    @objc func toggleLibrarySidebar(_ sender: Any?) { commands.requestSidebarToggle() }
    @objc func selectPreviousList(_ sender: Any?) { commands.requestListMove(-1) }
    @objc func selectNextList(_ sender: Any?) { commands.requestListMove(1) }
    @objc func saveDocument(_ sender: Any?) { commands.saveRequest += 1 }
    @objc func copyEntireItem(_ sender: Any?) { commands.copyRequest += 1 }
    /// ⇧⌘F, and ⌘F outside the editor. Presenting the search focuses its field once; when it is already open and
    /// the keyboard went elsewhere, SwiftUI leaves the keyboard there, so the field is focused directly.
    @objc func searchLibrary(_ sender: Any?) {
        // While an input method composes, the key would commit the composition and move the keyboard mid-word.
        if let text = window?.firstResponder as? NSTextView, text.hasMarkedText() { return }
        commands.requestSearch()
        if commands.searchIsPresented { focusSearchField() }
    }

    /// ⌘F (Find in Note…) reaches the window only when the editor is not in front, as with the list or the sidebar:
    /// there it searches the library. The editor's text view answers it first, with its find bar.
    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag
        guard tag == Int(NSFindPanelAction.showFindPanel.rawValue) else { return }
        searchLibrary(sender)
    }

    @objc func undoCollectionChange(_ sender: Any?) {
        Task { _ = await session.libraryWorkspace?.undoCollectionChange() }
    }

    @objc func undoSaveAsSnippet(_ sender: Any?) {
        Task { _ = try? await session.libraryWorkspace?.undoNewSave() }
    }

    // MARK: Item menu

    /// The types Item › Type lists, in its order; a menu item's tag is its index.
    static let snippetKinds: [MemoKind] = [.plainText, .prompt, .code, .markdown]

    @objc func toggleFavorite(_ sender: Any?) { commands.requestFavorite() }
    @objc func showLinkedItem(_ sender: Any?) { commands.requestShowLinked() }
    @objc func moveToRecentlyDeleted(_ sender: Any?) { commands.requestDelete() }
    @objc func toggleInspector(_ sender: Any?) { commands.requestInspectorToggle() }
    @objc func recoverDeletedItem(_ sender: Any?) { commands.requestRecover() }
    @objc func deleteDeletedItemPermanently(_ sender: Any?) { commands.requestPermanentDelete() }

    @objc func setSnippetKind(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, Self.snippetKinds.indices.contains(tag) else { return }
        commands.requestKind(Self.snippetKinds[tag])
    }

    @objc func removeFromCollection(_ sender: Any?) { commands.requestRemoveFromCollection() }

    /// ⇧⌘M: the collection menu, under the open item's title; a keyboard has no toolbar button to open it from.
    @objc func chooseCollection(_ sender: Any?) {
        guard let content = window?.contentView else { return }
        let menu = makeCollectionMenu()
        let titles: Set<String?> = ["Untitled Snippet", "Clipboard Item"]
        if let title = Self.views(NSTextField.self, in: content).first(where: { titles.contains($0.placeholderString) }) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: title.isFlipped ? title.bounds.maxY + 4 : -4), in: title)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: content.bounds.midX, y: content.bounds.midY), in: content)
        }
    }

    /// The same rows as the toolbar's collection menu: the collections, checked where all of the selection is, and
    /// New Collection….
    func makeCollectionMenu() -> NSMenu {
        let menu = NSMenu(title: commands.itemContext.selection.collectionTitle)
        for entry in commands.itemContext.collectionEntries {
            guard !entry.isSeparator else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(chooseCollectionItem(_:)), keyEquivalent: "")
            // The rows share one action; their own identifiers tell them apart for assistive apps.
            item.identifier = NSUserInterfaceItemIdentifier("CollectionMenu-\(entry.id)")
            item.target = self
            item.representedObject = entry
            item.state = entry.isChecked ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseCollectionItem(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? CollectionMenuEntry else { return }
        commands.requestCollection(entry.collectionID, creating: entry.isNewCollection)
    }

    private static func views<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    /// The toolbar's search field: the one search field outside the window's content, where the editor's find bar
    /// has its own.
    private func focusSearchField() {
        guard let window, let frame = window.contentView?.superview else { return }
        var queue = frame.subviews.filter { $0 !== window.contentView }
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let field = view as? NSSearchField {
                if (window.firstResponder as? NSTextView)?.delegate !== field { window.makeFirstResponder(field) }
                return
            }
            queue += view.subviews
        }
    }
    @objc func exportLibrary(_ sender: Any?) { commands.exportLibraryRequest &+= 1 }
    @objc func exportSelected(_ sender: Any?) { commands.exportSelectedRequest &+= 1 }

    /// Puts the keyboard on the lists: the sidebar while it shows; otherwise a menu of the lists opens under the
    /// toolbar's scope menu, as clicking it would.
    @objc func chooseList(_ sender: Any?) {
        if commands.sidebarIsVisible {
            commands.requestSidebarFocus()
        } else if let anchor = listMenuAnchor() {
            let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
            makeListMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
        }
    }

    /// The toolbar's scope menu, there only while the sidebar is hidden. SwiftUI's accessibility identifiers do
    /// not reach the toolbar items AppKit holds. Its help does on some systems; otherwise the scope menu is the
    /// item right after the system's sidebar button, which keeps its identifier.
    func listMenuAnchor(byHelp: Bool = true) -> NSView? {
        guard !commands.sidebarIsVisible, let items = window?.toolbar?.items else { return nil }
        if byHelp, let helped = items.first(where: { $0.toolTip == LibrarySidebar.chooseListHelp })?.view {
            return helped
        }
        guard let toggle = items.first(where: { $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar") })?.view,
              toggle.window != nil else { return nil }
        let toggleEnd = toggle.convert(toggle.bounds, to: nil).maxX
        return items.compactMap(\.view)
            .filter { $0 !== toggle && $0.window != nil && $0.convert($0.bounds, to: nil).minX >= toggleEnd - 1 }
            .min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The lists the toolbar's scope menu shows, in its order and sections, the list shown checked.
    func makeListMenu() -> NSMenu {
        let menu = NSMenu(title: "Choose List")
        for (index, section) in commands.listSections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for list in section {
                let item = NSMenuItem(title: list.title, action: #selector(chooseListItem(_:)), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: list.symbolName, accessibilityDescription: nil)
                item.identifier = NSUserInterfaceItemIdentifier(LibrarySidebar.menuIdentifier(for: list.scope))
                item.representedObject = list.scope
                item.state = list.scope == commands.listScope ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let create = NSMenuItem(title: "New Collection…", action: #selector(newCollection(_:)), keyEquivalent: "")
        create.target = self
        create.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(create)
        return menu
    }

    @objc private func chooseListItem(_ item: NSMenuItem) {
        guard let scope = item.representedObject as? LibraryScope else { return }
        commands.requestList(scope)
    }

    /// Shows `ref` in the list it is in, selected: a clip in Recent Clips, a snippet in its collection or All Snippets.
    /// With `showsSnippet`, a clip saved as a snippet shows as that snippet.
    func open(_ ref: ContentRef, showsSnippet: Bool = false) {
        commands.openRequest = LibraryOpenRequest(
            ref: ref,
            showsSnippet: showsSnippet,
            generation: (commands.openRequest?.generation ?? 0) + 1
        )
    }

    /// Starts a new snippet from quick access, in the list `scope` puts it (§6.2 of the redesign: a collection keeps
    /// it, any other list puts it in Unfiled and shows All Snippets).
    func newSnippet(in scope: LibraryScope) {
        commands.requestNewSnippet(in: scope)
    }
}

extension LibraryWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectPreviousList(_:)), #selector(selectNextList(_:)), #selector(chooseList(_:)):
            // ⌘[ and ⌘] indent in the body editor, and an input method owns the keys while it composes.
            if let text = window?.firstResponder as? NSTextView, !text.isFieldEditor || text.hasMarkedText() {
                return false
            }
            if menuItem.action == #selector(selectPreviousList(_:)) { return commands.canMoveList(-1) }
            if menuItem.action == #selector(selectNextList(_:)) { return commands.canMoveList(1) }
            return true
        case #selector(toggleLibrarySidebar(_:)):
            menuItem.title = commands.sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        case #selector(newCollection(_:)):
            return session.libraryWorkspace != nil
        case #selector(undoCollectionChange(_:)):
            return session.libraryWorkspace?.canUndoCollectionChange == true
        case #selector(undoSaveAsSnippet(_:)):
            return session.libraryWorkspace?.canUndoNewSave == true
        case #selector(saveDocument(_:)):
            menuItem.title = session.libraryWorkspace?.editor?.isReadOnly == true ? "Save as Snippet" : "Save"
            return session.libraryWorkspace != nil
        case #selector(toggleInspector(_:)):
            menuItem.title = commands.itemContext.inspectorIsPresented ? "Hide Inspector" : "Show Inspector"
            return true
        case #selector(toggleFavorite(_:)):
            let selection = commands.itemContext.selection
            menuItem.title = selection.favoriteTitle
            return selection.canFavorite && !selection.refs.isEmpty
        case #selector(chooseCollection(_:)):
            let selection = commands.itemContext.selection
            menuItem.title = selection.collectionTitle + "…"
            return !selection.refs.isEmpty
        case #selector(removeFromCollection(_:)):
            let collection = commands.itemContext.removableCollection
            menuItem.isHidden = collection == nil
            menuItem.title = collection.map { "Remove from “\($0.name)”" } ?? "Remove from Collection"
            return collection != nil && !commands.itemContext.selection.refs.isEmpty
        case #selector(setSnippetKind(_:)):
            let kind = commands.itemContext.selection.kind
            menuItem.state = kind != nil && Self.snippetKinds.firstIndex(of: kind!) == menuItem.tag ? .on : .off
            return kind != nil
        case #selector(showLinkedItem(_:)):
            let selection = commands.itemContext.selection
            menuItem.title = selection.linkedTitle
            return selection.linked != nil
        case #selector(recoverDeletedItem(_:)):
            return commands.itemContext.deleted?.canRestore == true
        case #selector(deleteDeletedItemPermanently(_:)):
            return commands.itemContext.deleted != nil
        case #selector(moveToRecentlyDeleted(_:)):
            // In the editor ⌘⌫ deletes to the start of the line; items move only from the list or the sidebar.
            guard window?.firstResponder is NSTableView else { return false }
            let selection = commands.itemContext.selection
            return selection.canDelete && !selection.refs.isEmpty
        default:
            break
        }
        if menuItem.action == #selector(exportSelected(_:)) {
            return session.exportCoordinator?.canStart == true
                && !commands.isRecentlyDeleted
                && !commands.selectedExportRefs.isEmpty
        }
        if menuItem.action == #selector(exportLibrary(_:)) {
            return session.exportCoordinator?.canStart == true && !commands.isRecentlyDeleted
        }
        return true
    }
}

extension LibraryWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closesAfterPreparation {
            closesAfterPreparation = false
            return true
        }
        guard let workspace = session.libraryWorkspace else { return true }
        guard closePreparationTask == nil else { return false }
        closePreparationTask = Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            let mayClose = await workspace.prepareToClose()
            closePreparationTask = nil
            guard mayClose else { return }
            closesAfterPreparation = true
            sender.performClose(nil)
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let workspace = session.libraryWorkspace else { return }
        Task { _ = try? await workspace.focusLost() }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        if shouldRestoreAccessory() { setActivationPolicy(.accessory) }
    }
}

@MainActor @Observable
final class LibraryWindowCommands {
    private(set) var newSnippetRequest = 0
    private(set) var newCollectionRequest = 0
    private(set) var sidebarToggleRequest = 0
    private(set) var previousListRequest = 0
    private(set) var nextListRequest = 0
    private(set) var sidebarFocusRequest = 0
    private(set) var listRequest: LibraryListRequest?
    var saveRequest = 0
    var copyRequest = 0
    var exportLibraryRequest = 0
    var exportSelectedRequest = 0
    private(set) var searchRequest = 0
    private(set) var favoriteRequest = 0
    private(set) var collectionRequest: LibraryCollectionRequest?
    private(set) var kindRequest: LibraryKindRequest?
    private(set) var showLinkedRequest = 0
    private(set) var deleteRequest = 0
    private(set) var removeFromCollectionRequest = 0
    private(set) var inspectorToggleRequest = 0
    private(set) var recoverRequest = 0
    private(set) var permanentDeleteRequest = 0
    private(set) var focusGeneration = 0
    private(set) var newSnippetFocusGeneration = 0
    /// Whether the search is open, as the view last reported it.
    @ObservationIgnored private(set) var searchIsPresented = false
    var openRequest: LibraryOpenRequest?
    private(set) var selectedExportRefs: [ContentRef] = []
    private(set) var isRecentlyDeleted = false
    /// The list shown, the collections listed and whether the sidebar shows, as the view last reported them; menu
    /// validation reads them, so changes are not observed.
    @ObservationIgnored private(set) var listScope: LibraryScope = .recentClips
    @ObservationIgnored private(set) var listSections = LibrarySidebar.sections(collections: [])
    @ObservationIgnored private(set) var sidebarIsVisible = true
    /// What the selection allows and whether the inspector shows, as the view last reported them, for the menus.
    @ObservationIgnored private(set) var itemContext = LibraryItemContext()
    /// Shows the chosen list's subtitle as the view words it; the window controller sets it to write the window's
    /// subtitle.
    @ObservationIgnored var showListTitle: @MainActor (String) -> Void = { _ in }

    /// The list a new snippet was asked for from outside the library, such as quick access; nil when the library's own
    /// list decides. It is read with the request it came with.
    @ObservationIgnored private(set) var newSnippetScope: LibraryScope?

    /// ⌘N and ⇧⌘F each take a newer focus generation; a new snippet's body asks for the keyboard only while its
    /// generation is current, so whichever came last keeps it.
    func requestNewSnippet(in scope: LibraryScope? = nil) {
        focusGeneration &+= 1
        newSnippetFocusGeneration = focusGeneration
        newSnippetScope = scope
        newSnippetRequest &+= 1
    }

    func requestSearch() {
        focusGeneration &+= 1
        searchRequest &+= 1
    }

    func updateSearchPresented(_ presented: Bool) {
        searchIsPresented = presented
    }

    func requestNewCollection() {
        newCollectionRequest &+= 1
    }

    func requestSidebarToggle() {
        sidebarToggleRequest &+= 1
    }

    /// ⌘[ (-1) or ⌘] (1).
    func requestListMove(_ offset: Int) {
        if offset < 0 { previousListRequest &+= 1 } else { nextListRequest &+= 1 }
    }

    func canMoveList(_ offset: Int) -> Bool {
        let collections = listSections.joined().compactMap(\.scope.collectionID)
        return LibrarySidebar.scope(offset, from: listScope, collections: collections) != nil
    }

    func requestSidebarFocus() {
        sidebarFocusRequest &+= 1
    }

    /// A list chosen from the menu ⌘L opens.
    func requestList(_ scope: LibraryScope) {
        listRequest = LibraryListRequest(scope: scope, generation: (listRequest?.generation ?? 0) + 1)
    }

    func updateListContext(scope: LibraryScope, sections: [[LibrarySidebar.ListEntry]], sidebarIsVisible: Bool) {
        listScope = scope
        listSections = sections
        self.sidebarIsVisible = sidebarIsVisible
    }

    func requestFavorite() { favoriteRequest &+= 1 }
    func requestShowLinked() { showLinkedRequest &+= 1 }
    func requestDelete() { deleteRequest &+= 1 }
    func requestRemoveFromCollection() { removeFromCollectionRequest &+= 1 }
    func requestInspectorToggle() { inspectorToggleRequest &+= 1 }
    func requestRecover() { recoverRequest &+= 1 }
    /// Delete Permanently… asks first; the view holds the question.
    func requestPermanentDelete() { permanentDeleteRequest &+= 1 }

    /// A row chosen from the collection menu ⇧⌘M opens: a collection to add the selection to, or take it out of, or
    /// a new collection (`collectionID` nil).
    func requestCollection(_ collectionID: CollectionID?, creating: Bool = false) {
        collectionRequest = LibraryCollectionRequest(
            collectionID: collectionID, createsCollection: creating,
            generation: (collectionRequest?.generation ?? 0) + 1
        )
    }

    func requestKind(_ kind: MemoKind) {
        kindRequest = LibraryKindRequest(kind: kind, generation: (kindRequest?.generation ?? 0) + 1)
    }

    func updateItemContext(_ context: LibraryItemContext) {
        itemContext = context
    }

    func updateExportContext(refs: [ContentRef], isRecentlyDeleted: Bool) {
        selectedExportRefs = refs
        self.isRecentlyDeleted = isRecentlyDeleted
    }
}

/// What the menus need of the library's selection.
struct LibraryItemContext: Equatable {
    var selection = LibrarySelectionState()
    /// The collection menu's rows for the selection.
    var collectionEntries: [CollectionMenuEntry] = []
    /// The collection being browsed, while the selection has a snippet in it: Item › Remove from “Prompts”.
    var removableCollection: CollectionValue?
    var inspectorIsPresented = false
    var isRecentlyDeleted = false
    /// The deleted facet selected in Recently Deleted.
    var deleted: TrashFacetSnapshot?
}

struct LibraryCollectionRequest: Equatable {
    let collectionID: CollectionID?
    let createsCollection: Bool
    let generation: Int
}

struct LibraryKindRequest: Equatable {
    let kind: MemoKind
    let generation: Int
}

struct LibraryListRequest: Equatable {
    let scope: LibraryScope
    let generation: Int
}

struct LibraryOpenRequest: Equatable {
    let ref: ContentRef
    /// A clip saved as a snippet shows as the snippet.
    var showsSnippet = false
    let generation: Int
}
