import AppKit
import Observation

@MainActor @Observable
final class CaptureSession {
    private(set) var preferences = CapturePreferences()
    private(set) var recent: [ItemSummary] = []
    private(set) var selectedContent: ResolvedContent?
    private(set) var selectedPreview: ClipTextPreview?
    private(set) var selectionIsLoading = false
    private(set) var selectionError: String?
    private(set) var isReady = false
    private(set) var actionMessage: String?
    private var message: String?
    private var monitor: PasteboardMonitor?
    @ObservationIgnored private var controller: PersistenceController?
    @ObservationIgnored private var pasteboard: NSPasteboard?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var selectionRead: Task<(ResolvedContent, ClipTextPreview?), Error>?
    @ObservationIgnored private var copyGeneration = 0
    @ObservationIgnored private var readContent: (@Sendable (ContentRef) async throws -> ResolvedContent)?
    /// Search over the local index; nil until the store opens. No UI uses it yet.
    @ObservationIgnored private(set) var searchService: SearchService?
    @ObservationIgnored private var searchIndex: SQLiteSearchIndex?
    @ObservationIgnored private var historyConsumer: HistoryConsumer?

    var status: String { monitor?.status ?? message ?? "Not recording" }
    var isPausing: Bool { monitor?.isPausing ?? false }
    var isRecording: Bool { isReady && (monitor?.isRecording ?? false) }

    init(readContent: (@Sendable (ContentRef) async throws -> ResolvedContent)? = nil,
         pasteboard: NSPasteboard? = nil) {
        self.readContent = readContent
        self.pasteboard = pasteboard
    }

    func initialize(testSessionID: UUID? = nil, cleanupTestSession: Bool = false) async {
        guard !isReady, !initializing else { return }
        initializing = true
        defer { initializing = false }
        do {
            let directory: URL
            let board: NSPasteboard
            if let testSessionID {
                let configuration = CaptureTestConfiguration(id: testSessionID)
                directory = configuration.directory
                let defaults = UserDefaults(suiteName: configuration.preferencesSuite)!
                board = NSPasteboard(name: .init(configuration.pasteboardName))
                if cleanupTestSession {
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                    defaults.removePersistentDomain(forName: configuration.preferencesSuite)
                    board.releaseGlobally()
                    message = "Test session removed"
                    return
                }
                preferences = CapturePreferences(defaults: defaults)
            } else {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                directory = support.appendingPathComponent("Keeptide/Library")
                board = .general
            }
            let store = try await Task.detached(priority: .userInitiated) {
                try PersistenceController(directory: directory)
            }.value
            do { _ = try await StoreSafetyGate(controller: store).permit(.write) }
            catch {
                try? await store.close()
                message = "The library requires recovery before recording can resume."
                return
            }
            controller = store
            readContent = { ref in
                try Task.checkCancellation()
                return try await ContentRepository(controller: store).read(ref)
            }
            pasteboard = board
            let monitor = PasteboardMonitor(reader: SnapshotReader(pasteboard: board),
                service: CaptureService(controller: store), preferences: preferences,
                sourceApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                matchesOwnWrite: { $0.matches(pasteboard: board) })
            monitor.onCapture = { [weak self] in await self?.refresh() }
            monitor.onUnavailable = { [weak self] in self?.isReady = false }
            foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak monitor] notification in
                let identifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { monitor?.foregroundApplicationChanged(to: identifier) }
            }
            self.monitor = monitor
            await startSearch(store: store, directory: directory)
            isReady = true
            message = nil
            await refresh()
            monitor.start()
        } catch {
            message = "The local library could not be opened. Recording is unavailable."
        }
    }

    /// A search index failure leaves recording and the library usable; searches
    /// then report the index as unavailable.
    private func startSearch(store: PersistenceController, directory: URL) async {
        let status = SearchIndexStatus()
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

    func refresh() async {
        guard let controller else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let rows = try await ContentRepository(controller: controller).recent(limit: 200)
            guard generation == refreshGeneration else { return }
            recent = rows.filter { $0.history != nil }
            actionMessage = nil
        } catch {
            actionMessage = "Recent clips could not be loaded."
        }
    }

    func select(_ ref: ContentRef?) async {
        selectionRead?.cancel()
        selectionGeneration += 1
        copyGeneration += 1
        actionMessage = nil; selectionError = nil; selectedContent = nil; selectedPreview = nil
        selectionIsLoading = false
        let generation = selectionGeneration
        guard let ref, let readContent else { return }
        selectionIsLoading = true
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let content = try await readContent(ref)
            try Task.checkCancellation()
            return (content, ClipboardTextDecoder.preview(content.representations))
        }
        selectionRead = operation
        defer {
            if generation == selectionGeneration { selectionIsLoading = false; selectionRead = nil }
        }
        do {
            let (content, preview) = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard generation == selectionGeneration, !Task.isCancelled else { return }
            selectedContent = content
            selectedPreview = preview
        } catch is CancellationError {
            // A newer selection or shutdown owns the detail pane.
        } catch {
            if generation == selectionGeneration { selectionError = "This clip is no longer available." }
        }
    }

    func copy(_ ref: ContentRef) async {
        guard let readContent, let pasteboard else { return }
        copyGeneration += 1
        let generation = copyGeneration
        actionMessage = nil
        do {
            let content = try await readContent(ref)
            guard generation == copyGeneration else { return }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try PasteboardWriter.prepare(content)
            }.value
            guard generation == copyGeneration, !Task.isCancelled else { return }
            let token = try PasteboardWriter(pasteboard: pasteboard).write(prepared)
            monitor?.suppressOwnWrite(token)
            actionMessage = "Copied"
        } catch {
            guard generation == copyGeneration else { return }
            actionMessage = "This clip could not be copied. Its original formats must all be available."
        }
    }

    func shutdown() async {
        copyGeneration += 1
        selectionGeneration += 1
        selectionRead?.cancel()
        selectionRead = nil
        selectionIsLoading = false
        selectedContent = nil
        selectedPreview = nil
        selectionError = nil
        if let foregroundObserver { NSWorkspace.shared.notificationCenter.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        await monitor?.stopAndDrain()
        monitor = nil
        await historyConsumer?.stopAndDrain()
        historyConsumer = nil
        try? await controller?.close()
        controller = nil
        searchIndex?.close()
        searchIndex = nil
        searchService = nil
        readContent = nil
        isReady = false
    }
}
