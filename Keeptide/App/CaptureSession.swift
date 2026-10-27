import AppKit
import Observation

@MainActor @Observable
final class CaptureSession {
    private(set) var preferences = CapturePreferences()
    private(set) var recent: [ItemSummary] = []
    private(set) var selectedContent: ResolvedContent?
    private(set) var isReady = false
    private(set) var actionMessage: String?
    private var message: String?
    private var monitor: PasteboardMonitor?
    @ObservationIgnored private var controller: PersistenceController?
    @ObservationIgnored private var pasteboard: NSPasteboard?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var copyGeneration = 0
    @ObservationIgnored private var readContent: (@Sendable (ContentRef) async throws -> ResolvedContent)?

    var status: String { monitor?.status ?? message ?? "Not recording" }
    var isPausing: Bool { monitor?.isPausing ?? false }

    init(readContent: (@Sendable (ContentRef) async throws -> ResolvedContent)? = nil,
         pasteboard: NSPasteboard? = nil) {
        self.readContent = readContent
        self.pasteboard = pasteboard
    }

    func initialize(testSessionID: UUID? = nil) async {
        guard !isReady, !initializing else { return }
        initializing = true
        defer { initializing = false }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory: URL
            let board: NSPasteboard
            if let testSessionID {
                directory = support.appendingPathComponent("KeeptideTests/\(testSessionID.uuidString)")
                preferences = CapturePreferences(defaults: UserDefaults(suiteName: "KeeptideCaptureTest.\(testSessionID.uuidString)")!)
                board = NSPasteboard(name: .init("io.github.insightprober.Keeptide.capture-test.\(testSessionID.uuidString)"))
            } else {
                directory = support.appendingPathComponent("Keeptide/Library")
                board = .general
            }
            let store = try await Task.detached(priority: .userInitiated) {
                try PersistenceController(directory: directory)
            }.value
            controller = store
            readContent = { ref in try await ContentRepository(controller: store).read(ref) }
            pasteboard = board
            let monitor = PasteboardMonitor(reader: SnapshotReader(pasteboard: board),
                service: CaptureService(controller: store), preferences: preferences,
                sourceApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                matchesOwnWrite: { $0.matches(pasteboard: board) })
            monitor.onCapture = { [weak self] in await self?.refresh() }
            self.monitor = monitor
            isReady = true
            message = nil
            await refresh()
            monitor.start()
        } catch {
            message = "The local library could not be opened. Recording is unavailable."
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
            actionMessage = nil
        } catch {
            actionMessage = "Recent clips could not be loaded."
        }
    }

    func select(_ ref: ContentRef?) async {
        selectionGeneration += 1
        copyGeneration += 1
        actionMessage = nil
        let generation = selectionGeneration
        selectedContent = nil
        guard let ref, let readContent else { return }
        do {
            let content = try await readContent(ref)
            guard generation == selectionGeneration else { return }
            selectedContent = content
        } catch {
            if generation == selectionGeneration { actionMessage = "This clip is no longer available." }
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
            let token = try PasteboardWriter(pasteboard: pasteboard).write(content)
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
        monitor?.stop()
        monitor = nil
        try? await controller?.close()
        controller = nil
        readContent = nil
        isReady = false
    }
}
