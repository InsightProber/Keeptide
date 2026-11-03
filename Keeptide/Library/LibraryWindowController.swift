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
    @objc func saveDocument(_ sender: Any?) { commands.saveRequest += 1 }
    @objc func copyEntireItem(_ sender: Any?) { commands.copyRequest += 1 }
    @objc func searchLibrary(_ sender: Any?) { commands.requestSearch() }
    @objc func exportLibrary(_ sender: Any?) { commands.exportLibraryRequest &+= 1 }
    @objc func exportSelected(_ sender: Any?) { commands.exportSelectedRequest &+= 1 }
    func showIgnoredApplications() { commands.requestIgnoredApplications() }

    func open(_ ref: ContentRef) {
        commands.openRequest = LibraryOpenRequest(
            ref: ref,
            generation: (commands.openRequest?.generation ?? 0) + 1
        )
    }
}

extension LibraryWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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
    var saveRequest = 0
    var copyRequest = 0
    var exportLibraryRequest = 0
    var exportSelectedRequest = 0
    private(set) var searchRequest = 0
    private(set) var ignoredApplicationsRequest = 0
    private(set) var focusGeneration = 0
    private(set) var newSnippetFocusGeneration = 0
    private var searchFocus = SearchFocusRequestState()
    var pendingSearchFocus: SearchFocusIntent? { searchFocus.pending }
    var openRequest: LibraryOpenRequest?
    private(set) var selectedExportRefs: [ContentRef] = []
    private(set) var isRecentlyDeleted = false

    func requestNewSnippet() {
        focusGeneration &+= 1
        searchFocus.invalidate()
        newSnippetFocusGeneration = focusGeneration
        newSnippetRequest &+= 1
    }

    func requestSearch() {
        focusGeneration &+= 1
        searchRequest &+= 1
        searchFocus.request(searchRequest, generation: focusGeneration)
    }

    func isCurrentSearchFocus(_ intent: SearchFocusIntent) -> Bool {
        searchFocus.isCurrent(intent, generation: focusGeneration)
    }

    @discardableResult
    func consumeSearchFocus(_ intent: SearchFocusIntent) -> Bool {
        searchFocus.consume(intent, generation: focusGeneration)
    }

    func updateExportContext(refs: [ContentRef], isRecentlyDeleted: Bool) {
        selectedExportRefs = refs
        self.isRecentlyDeleted = isRecentlyDeleted
    }

    func requestIgnoredApplications() {
        ignoredApplicationsRequest &+= 1
    }
}

struct LibraryOpenRequest: Equatable {
    let ref: ContentRef
    let generation: Int
}
