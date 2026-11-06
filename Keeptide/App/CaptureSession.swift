import AppKit
import Observation

@MainActor @Observable
final class CaptureSession {
    private(set) var preferences: CapturePreferences
    private(set) var recent: [ItemSummary] = []
    private(set) var isReady = false
    private(set) var libraryWorkspace: LibraryWorkspace?
    private(set) var maintenance: LibraryMaintenance?
    private(set) var libraryInitializationError: String?
    private(set) var actionMessage: String?
    private var message: String?
    private var monitor: PasteboardMonitor?
    @ObservationIgnored private var controller: PersistenceController?
    @ObservationIgnored private var pasteboard: NSPasteboard?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    /// Every copy goes through this service; nil until the store opens.
    @ObservationIgnored private(set) var pasteService: PasteService?
    /// What the strip shows of each clip is read through this; nil until the store opens.
    @ObservationIgnored private(set) var previewService: PreviewService?
    /// Local file authorization belongs to the exact store generation opened by this session.
    @ObservationIgnored private(set) var fileAccessStore: FileAccessStore?
    @ObservationIgnored private(set) var fileAccessIdentity: StoreIdentity?
    @ObservationIgnored private(set) var usageStore: LocalUsageStore?
    /// Local export is bound to the exact store identity opened by this session.
    private(set) var exportCoordinator: ExportCoordinator?
    /// Called when the store-backed services appear or go away.
    @ObservationIgnored var onServicesChanged: (@MainActor () -> Void)?
    /// Called after recent clips are reloaded, for example after a new capture.
    @ObservationIgnored var onRecentClipsChanged: (@MainActor () -> Void)?
    /// Called after the Library changed the collections.
    @ObservationIgnored var onCollectionsChanged: (@MainActor () -> Void)?
    /// Search over the local index; nil until the store opens. No UI uses it yet.
    @ObservationIgnored private(set) var searchService: SearchService?
    @ObservationIgnored private var searchIndex: SQLiteSearchIndex?
    @ObservationIgnored private var searchStatus: SearchIndexStatus?
    @ObservationIgnored private var historyConsumer: HistoryConsumer?
    /// What direct paste asks of the system. Every paste service this session makes uses it.
    @ObservationIgnored private let directPaste: DirectPasteSystem
    /// A clipboard a test gives in place of the real one. Without it, the session reads the clipboard its library
    /// records.
    @ObservationIgnored private let clipboardReader: (any SnapshotReading)?
    /// An app-level preference object is injected before asynchronous store initialization so Settings, onboarding,
    /// and the monitor keep one identity. Legacy tests that do not inject one still adopt the selected test/QA suite.
    @ObservationIgnored private var keepsPreferenceIdentity: Bool
    #if DEBUG
    /// The manual paste QA run's throwaway library and preferences, removed at shutdown.
    @ObservationIgnored private var manualPasteQASession: ManualPasteQASession?
    #endif

    /// Why new copies are not kept, while that is so, which quick access, the menu bar and the Library say; nil while
    /// they are kept, and while the library is still opening, since Keeptide keeps them as it opens. The system may
    /// deny Keeptide the clipboard, or the disk be full, until a new copy is kept; or the library could not open, or
    /// stopped working, until Keeptide reopens.
    var captureNotice: String? {
        #if DEBUG
        // The QA session keeps no copies, and says so, so that it is never taken for the user's own.
        if manualPasteQASession != nil { return "Manual paste QA — new copies are not kept" }
        #endif
        switch monitor?.state {
        case .interrupted(let reason)?, .failed(let reason)?: return reason
        default: return isReady ? nil : message
        }
    }

    var contentRepository: ContentRepository? { controller.map { ContentRepository(controller: $0) } }
    var libraryService: LibraryService? { controller.map { LibraryService(controller: $0) } }
    var collectionService: CollectionService? { controller.map { CollectionService(controller: $0) } }

    /// `directPaste` stays `.unavailable` everywhere but in the app delegate, and `clipboardReader` reads the real
    /// clipboard everywhere but in tests: tests use fakes.
    init(preferences: CapturePreferences? = nil,
         pasteboard: NSPasteboard? = nil,
         directPaste: DirectPasteSystem = .unavailable,
         clipboardReader: (any SnapshotReading)? = nil) {
        self.preferences = preferences ?? CapturePreferences()
        keepsPreferenceIdentity = preferences != nil
        self.pasteboard = pasteboard
        self.directPaste = directPaste
        self.clipboardReader = clipboardReader
    }

    /// Once application-level UI observes this session, its preference reference must remain stable. Launch wiring
    /// injects the correct user/test/QA suite before calling this; direct legacy test sessions can still adopt a suite.
    func preservePreferenceIdentity() {
        keepsPreferenceIdentity = true
    }

    /// Opens the library that the launch chooses (`CaptureLibrary.choose`).
    func initialize(testSessionID: UUID? = nil, cleanupTestSession: Bool = false,
                    seedSyntheticClips: Bool = false, manualPasteQA: Bool = false) async {
        guard !isReady, !initializing else { return }
        let library: CaptureLibrary?
        do {
            library = try CaptureLibrary.choose(testSessionID: testSessionID, manualPasteQA: manualPasteQA,
                                                userLibrary: CaptureLibrary.userLibraryDirectory())
        } catch {
            message = "The local library could not be opened."
            return
        }
        // A Release build asked for the manual paste QA session chooses nothing, and nothing opens; nor does a test
        // process without a test session.
        guard let library else { return }
        await open(library, cleanupTestSession: cleanupTestSession, seedSyntheticClips: seedSyntheticClips)
    }

    #if DEBUG
    /// Opens a manual paste QA library without choosing from launch flags, as a test does. It is the only library a
    /// test can open directly: the user's library records the general clipboard. It copies to the clipboard the
    /// session was made with, if any, which a test gives it, and otherwise to the general one.
    func open(manualPasteQA session: ManualPasteQASession) async {
        await open(.manualPasteQA(session))
    }
    #endif

    /// Opens `library`: its store, search index and paste service, and the recording of the clipboard where the
    /// library records.
    private func open(_ library: CaptureLibrary, cleanupTestSession: Bool = false,
                      seedSyntheticClips: Bool = false) async {
        guard !isReady, !initializing else { return }
        initializing = true
        defer { initializing = false }
        do {
            let directory = library.directory
            let board: NSPasteboard
            switch library {
            case .test(let configuration):
                let defaults = UserDefaults(suiteName: configuration.preferencesSuite)!
                board = NSPasteboard(name: .init(configuration.pasteboardName))
                if cleanupTestSession {
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                    defaults.removePersistentDomain(forName: configuration.preferencesSuite)
                    board.releaseGlobally()
                    message = "Test session removed"
                    return
                }
                if !keepsPreferenceIdentity {
                    preferences = CapturePreferences(defaults: defaults)
                }
            #if DEBUG
            case .manualPasteQA(let qa):
                // Its own library and preferences, never the user's. Pastes go to the general clipboard, where the
                // app in front reads them; nothing records it in this session. A test gives the session a clipboard
                // of its own when it makes it.
                manualPasteQASession = qa
                if !keepsPreferenceIdentity {
                    preferences = CapturePreferences(defaults: UserDefaults(suiteName: qa.preferencesSuite)!)
                }
                board = pasteboard ?? .general
            #endif
            case .user:
                board = .general
            }
            let store = try await Task.detached(priority: .userInitiated) {
                try PersistenceController(directory: directory)
            }.value
            do { _ = try await StoreSafetyGate(controller: store).permit(.write) }
            catch {
                try? await store.close()
                message = "The library requires recovery before it can keep new copies."
                return
            }
            let storeIdentity: StoreIdentity
            do {
                storeIdentity = try await store.identity()
            } catch {
                try? await store.close()
                throw error
            }
            #if DEBUG
            switch library {
            case .test where seedSyntheticClips: try await SyntheticClipSeeder.seed(into: store)
            case .manualPasteQA: try await SyntheticClipSeeder.seed(ManualPasteQASession.clips(), into: store)
            default: break
            }
            #endif
            controller = store
            let read: @Sendable (ContentRef) async throws -> ResolvedContent = { ref in
                try Task.checkCancellation()
                return try await ContentRepository(controller: store).read(ref)
            }
            pasteboard = board
            let monitor = library.recordsClipboard
                ? PasteboardMonitor(reader: clipboardReader ?? SnapshotReader(pasteboard: board),
                                    service: CaptureService(controller: store), preferences: preferences,
                                    sourceApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                                    matchesOwnWrite: { $0.matches(pasteboard: board) })
                : nil
            monitor?.onCapture = { [weak self] in await self?.refresh() }
            // Only reopening Keeptide brings the library back. Until then, the monitor says why it stopped.
            monitor?.onUnavailable = { [weak self] in self?.isReady = false }
            monitor?.onStorageFull = { [weak self] in await self?.recoverFromDiskPressure() }
            if let monitor {
                foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
                ) { [weak monitor] notification in
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let identifier = application?.bundleIdentifier
                    MainActor.assumeIsolated { monitor?.foregroundApplicationChanged(to: identifier) }
                }
            }
            self.monitor = monitor
            let usage = LocalUsageStore(controller: store)
            let fileAccess = FileAccessStore(controller: store)
            usageStore = usage
            fileAccessStore = fileAccess
            fileAccessIdentity = storeIdentity
            exportCoordinator = .production(
                exporter: ExportService(controller: store, expecting: storeIdentity)
            )
            pasteService = PasteService(pasteboard: board, read: read, recordUse: { try await usage.record($0) },
                                        didWrite: { [weak monitor] in monitor?.suppressOwnWrite($0) },
                                        system: directPaste, directPasteOnlyTo: library.directPasteOnlyTo)
            previewService = PreviewService(
                read: read,
                fileReferences: { ref in
                    try await fileAccess.filePreviewReferences(for: ref, expecting: storeIdentity)
                }
            )
            await startSearch(store: store, directory: directory)
            let consumer = historyConsumer
            do {
                libraryWorkspace = try await LibraryWorkspace.make(
                    controller: store, draftDirectory: directory.appendingPathComponent("Drafts"),
                    searchService: searchService, pasteService: pasteService,
                    refreshSearch: { try await consumer?.synchronize() }
                )
                libraryWorkspace?.onCollectionsChanged = { [weak self] in self?.onCollectionsChanged?() }
                libraryInitializationError = nil
            } catch {
                libraryInitializationError = "The editor could not be opened. Your saved content is preserved."
            }
            let lifecycleDefaults = library.preferencesSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            let maintenance = LibraryMaintenance(
                controller: store, identity: storeIdentity, directory: directory,
                preferences: LifecyclePreferences(defaults: lifecycleDefaults),
                didChange: { [weak self] in await self?.refresh() }
            )
            self.maintenance = maintenance
            isReady = true
            message = nil
            await refresh()
            maintenance.start()
            monitor?.start()
            onServicesChanged?()
        } catch {
            message = "The local library could not be opened."
        }
    }

    /// A search index failure leaves capture and the library usable; searches
    /// then report the index as unavailable.
    private func startSearch(store: PersistenceController, directory: URL) async {
        let status = SearchIndexStatus()
        searchStatus = status
        let searchDirectory = directory.appendingPathComponent("Search", isDirectory: true)
        guard let index = try? await Task.detached(priority: .utility, operation: {
            try SQLiteSearchIndex(directory: searchDirectory)
        }).value else {
            status.update(.unavailable)
            searchService = SearchService(index: nil, status: status)
            return
        }
        let consumer = HistoryConsumer(controller: store, index: index, status: status)
        searchIndex = index
        historyConsumer = consumer
        searchService = SearchService(index: index, status: status)
        await consumer.start()
    }

    /// Keep primary stores and drafts intact. Search remains unavailable until
    /// restart rebuilds it, so a full disk cannot cause a rebuild/eviction loop.
    /// The monitor asks as the disk fills, not for each copy that finds it
    /// still full.
    private func recoverFromDiskPressure() async {
        guard let index = searchIndex else { return }
        let consumer = historyConsumer
        searchStatus?.suspend()
        await consumer?.stopAndDrain()
        guard searchIndex === index else { return }
        historyConsumer = nil
        do {
            try await Task.detached(priority: .utility) { try index.evictForDiskPressure() }.value
            guard searchIndex === index else { return }
            actionMessage = "Search cache cleared. Your content and drafts are preserved. Restart after freeing space to rebuild search."
        } catch {
            guard searchIndex === index else { return }
            actionMessage = "Your content and drafts are preserved; the search cache could not be cleared."
        }
    }

    func refresh() async {
        guard let controller else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let rows = try await ContentRepository(controller: controller).recent(limit: 200)
            guard generation == refreshGeneration else { return }
            recent = rows.filter { $0.history != nil }
            await libraryWorkspace?.reload()
            actionMessage = nil
            onRecentClipsChanged?()
        } catch {
            actionMessage = "Recent clips could not be loaded."
        }
    }

    func shutdown() async {
        // Export owns a pinned snapshot and a security-scoped destination. Drain it before any store service closes.
        await exportCoordinator?.stopAndDrain()
        exportCoordinator = nil
        await maintenance?.stopAndDrain()
        maintenance = nil
        if let foregroundObserver { NSWorkspace.shared.notificationCenter.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        await monitor?.stopAndDrain()
        monitor = nil
        await historyConsumer?.stopAndDrain()
        historyConsumer = nil
        // Stop publishing generation-bound local authorization before the store closes.
        previewService = nil
        fileAccessStore = nil
        fileAccessIdentity = nil
        try? await controller?.close()
        controller = nil
        searchIndex?.close()
        searchIndex = nil
        #if DEBUG
        // Only once its store and search index are closed.
        manualPasteQASession?.remove()
        manualPasteQASession = nil
        #endif
        searchService = nil
        searchStatus = nil
        libraryWorkspace = nil
        pasteService = nil
        usageStore = nil
        isReady = false
        onServicesChanged?()
    }
}

/// The library a capture session opens: the user's own, a UI test session's, or in a Debug build the manual paste QA
/// session's. Choosing one opens nothing.
enum CaptureLibrary {
    case user(directory: URL)
    case test(CaptureTestConfiguration)
    #if DEBUG
    case manualPasteQA(ManualPasteQASession)
    #endif

    /// A test session wins over the manual paste QA session, which is chosen only when asked for. `userLibrary` is
    /// looked up only when neither is chosen. A Release build has no QA session: asked for one, it chooses nothing
    /// (nil), so nothing opens; it never falls back to the user's library. Nor does a test process ever choose the
    /// user's library, which records the general clipboard: where XCTest runs, as in the app that hosts the unit
    /// tests, it chooses nothing. A test of the choice itself says it is not one with `isRunningTests`.
    static func choose(testSessionID: UUID?, manualPasteQA: Bool,
                       isRunningTests: Bool = LaunchConfiguration.isRunningTests(ProcessInfo.processInfo.environment),
                       userLibrary: @autoclosure () throws -> URL) rethrows -> CaptureLibrary? {
        if let testSessionID { return .test(CaptureTestConfiguration(id: testSessionID)) }
        if manualPasteQA {
            #if DEBUG
            return .manualPasteQA(ManualPasteQASession(id: UUID()))
            #else
            return nil
            #endif
        }
        guard !isRunningTests else { return nil }
        return .user(directory: try userLibrary())
    }

    /// Application Support/Keeptide/Library. Looking it up creates Application Support when it is missing.
    static func userLibraryDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                    create: true).appendingPathComponent("Keeptide/Library")
    }

    var directory: URL {
        switch self {
        case .user(let directory): return directory
        case .test(let configuration): return configuration.directory
        #if DEBUG
        case .manualPasteQA(let session): return session.directory
        #endif
        }
    }

    /// nil is the standard defaults, the user's own.
    var preferencesSuite: String? {
        switch self {
        case .user: return nil
        case .test(let configuration): return configuration.preferencesSuite
        #if DEBUG
        case .manualPasteQA(let session): return session.preferencesSuite
        #endif
        }
    }

    /// The manual paste QA session never records the clipboard.
    var recordsClipboard: Bool {
        #if DEBUG
        if case .manualPasteQA = self { return false }
        #endif
        return true
    }

    /// The one app that direct paste may reach, if any. A test session pastes only into the system test host: any
    /// other app would paste from the general clipboard, not from the session's.
    var directPasteOnlyTo: String? {
        if case .test = self { return CaptureTestConfiguration.systemTestHostBundleIdentifier }
        return nil
    }
}
