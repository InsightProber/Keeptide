import Foundation
import Observation

/// The store-backed services quick access reads and acts through; nil while the
/// library is not open.
@MainActor
struct QuickAccessServices {
    let repository: ContentRepository
    let search: SearchService?
    let paste: PasteService
}

enum QuickAccessPhase: Equatable {
    case loading, results, noContent, noResults, libraryUnavailable
}

enum IndexNotice: Equatable {
    case rebuilding, searchUnavailable
}

enum PreviewContent: Equatable {
    case text(String, isTruncated: Bool)
    case info(kind: ContentKind, sourceApp: String?)
    case failed(PasteRefusal)
}

extension ContentKind {
    /// The kinds quick access filters by, in menu order.
    static let filters: [ContentKind] = [.text, .url, .image, .file]

    var filterTitle: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .image: "Image"
        case .file: "File"
        case .other: "Other"
        }
    }
}

/// What the quick access panel lists, which row is selected, and what an action may
/// touch. Every load belongs to one query generation of the panel's paste session, so
/// results that arrive after the query, filters or session changed are dropped.
@MainActor @Observable
final class QuickAccessState {
    static let recentLimit = 200
    static let pageSize = 60
    nonisolated static let previewByteLimit = 262_144

    private(set) var query = ""
    private(set) var kinds: Set<ContentKind> = []
    private(set) var selection = SelectionCoordinator()
    private(set) var phase = QuickAccessPhase.libraryUnavailable
    private(set) var indexNotice: IndexNotice?
    private(set) var isPreviewExpanded = false
    private(set) var preview: PreviewContent?
    private(set) var failure: PasteRefusal?
    @ObservationIgnored var onCopied: (@MainActor () -> Void)?
    /// Called when the state collapses the preview itself, so the panel can restore its frame.
    @ObservationIgnored var onPreviewCollapsed: (@MainActor () -> Void)?

    @ObservationIgnored private let services: @MainActor () -> QuickAccessServices?
    @ObservationIgnored private var session: PasteSession?
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var isCopying = false
    @ObservationIgnored private var totalMatches = 0
    @ObservationIgnored private var previewedRef: ContentRef?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var loadingMore: Task<Void, Never>?
    @ObservationIgnored private var previewing: Task<Void, Never>?

    init(services: @escaping @MainActor () -> QuickAccessServices?) {
        self.services = services
    }

    /// An empty or invisible query with no filters lists recent clips without the index.
    var showsRecentClips: Bool { ParsedQuery(query).isEmpty && kinds.isEmpty }

    var hasFiltersOrQuery: Bool { !query.isEmpty || !kinds.isEmpty }

    var scopeTitle: String {
        guard !showsRecentClips else { return "Recent Clips" }
        return (["All Content"] + ContentKind.filters.filter(kinds.contains).map(\.filterTitle))
            .joined(separator: " · ")
    }

    func open() {
        isOpen = true
        query = ""
        kinds = []
        isPreviewExpanded = false
        selection = SelectionCoordinator()
        startSession()
    }

    func close() {
        isOpen = false
        cancelLoads()
        session?.end()
        session = nil
        isPreviewExpanded = false
        preview = nil
        failure = nil
    }

    /// The library opened or closed; an open panel reloads its current query.
    func servicesDidChange() {
        guard isOpen else { return }
        startSession()
    }

    /// New clips arrived; the recent list reloads without moving the selection.
    func recentClipsChanged() {
        guard showsRecentClips, let repository = services()?.repository, let generation = currentGeneration else {
            return
        }
        refreshing?.cancel()
        refreshing = Task { await loadRecent(repository, generation: generation, isRefresh: true) }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        reload()
    }

    func toggleKind(_ kind: ContentKind) {
        if kinds.remove(kind) == nil { kinds.insert(kind) }
        reload()
    }

    func clearQueryAndFilters() {
        guard hasFiltersOrQuery else { return }
        query = ""
        kinds = []
        reload()
    }

    func select(_ ref: ContentRef) {
        selection.select(ref)
        selectionChanged()
    }

    @discardableResult
    func moveSelection(by offset: Int) -> SelectionMove {
        let move = selection.move(by: offset)
        guard move == .moved else { return move }
        selectionChanged()
        if let selected = selection.selection, let index = selection.rows.firstIndex(where: { $0.ref == selected }) {
            loadMoreIfNeeded(visibleRow: index)
        }
        return move
    }

    func togglePreview() {
        isPreviewExpanded.toggle()
        loadPreview()
    }

    func copySelection(_ mode: PasteMode) async {
        guard !isCopying, let ref = selection.executableSelection, let session,
              let paste = services()?.paste else { return }
        isCopying = true
        defer { isCopying = false }
        failure = nil
        let outcome = await paste.execute(PasteRequest(ref: ref, queryGeneration: selection.generation, mode: mode,
                                                       session: session))
        // A reopened panel or a newer selection owns the screen now.
        guard isOpen, self.session === session else { return }
        switch outcome {
        case .copied: onCopied?()
        case .refused(let refusal): if selection.selection == ref { failure = refusal }
        }
    }

    func loadMoreIfNeeded(visibleRow index: Int) {
        guard !showsRecentClips, loadingMore == nil, phase == .results,
              index >= selection.rows.count - 10, totalMatches > selection.rows.count,
              let search = services()?.search, let generation = currentGeneration else { return }
        let request = SearchRequest(query: query, kinds: kinds, generation: generation,
                                    offset: selection.rows.count, limit: Self.pageSize)
        loadingMore = Task {
            defer { if self.currentGeneration == generation { self.loadingMore = nil } }
            do {
                for try await page in search.search(request) where page.isComplete {
                    guard self.isCurrent(generation) else { return }
                    self.selection.append(page.results.map { Self.row(from: $0) }, generation: generation)
                    self.totalMatches = page.totalMatches
                }
            } catch {
                // The rows already shown stay usable; the next scroll asks again.
            }
        }
    }

    private var currentGeneration: UInt64? {
        guard isOpen, let session, session.queryGeneration == selection.generation else { return nil }
        return session.queryGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && currentGeneration == generation
    }

    private func startSession() {
        session?.end()
        session = services()?.paste.beginSession()
        reload()
    }

    private func reload() {
        cancelLoads()
        failure = nil
        preview = nil
        guard isOpen, let services = services(), let session else {
            selection = SelectionCoordinator()
            phase = .libraryUnavailable
            indexNotice = nil
            return
        }
        let generation = session.advanceQueryGeneration()
        selection.beginGeneration(generation)
        totalMatches = 0
        phase = .loading
        if showsRecentClips {
            indexNotice = nil
            loading = Task { await loadRecent(services.repository, generation: generation, isRefresh: false) }
        } else {
            let request = SearchRequest(query: query, kinds: kinds, generation: generation, limit: Self.pageSize)
            loading = Task { await loadSearch(services.search, request) }
        }
    }

    private func loadRecent(_ repository: ContentRepository, generation: UInt64, isRefresh: Bool) async {
        let summaries = try? await repository.recent(limit: Self.recentLimit)
        guard isCurrent(generation) else { return }
        // A refresh that fails keeps the clips already listed.
        if summaries == nil, isRefresh { return }
        let rows = (summaries ?? []).compactMap { Self.row(from: $0) }
        selection.apply(rows, generation: generation, isComplete: true)
        phase = summaries == nil ? .libraryUnavailable : (rows.isEmpty ? .noContent : .results)
        followSelection()
    }

    private func loadSearch(_ search: SearchService?, _ request: SearchRequest) async {
        let generation = request.generation
        guard let search else {
            if isCurrent(generation) { showSearchUnavailable(generation) }
            return
        }
        do {
            for try await page in search.search(request) {
                guard isCurrent(generation) else { return }
                selection.apply(page.results.map { Self.row(from: $0) }, generation: generation,
                                isComplete: page.isComplete, keepsChosenRow: true)
                totalMatches = page.totalMatches
                indexNotice = Self.notice(for: page.indexState)
                phase = !page.results.isEmpty ? .results : (page.isComplete ? .noResults : .loading)
                followSelection()
            }
        } catch {
            guard isCurrent(generation) else { return }
            showSearchUnavailable(generation)
        }
    }

    private func showSearchUnavailable(_ generation: UInt64) {
        selection.apply([], generation: generation, isComplete: true)
        indexNotice = .searchUnavailable
        phase = .noResults
    }

    private func selectionChanged() {
        failure = nil
        followSelection()
    }

    /// Keeps an open preview on the selected row; it never shows another row's content,
    /// and it collapses when the selected row is gone.
    private func followSelection() {
        guard isPreviewExpanded else { return }
        if selection.selectionLost {
            isPreviewExpanded = false
            loadPreview()
            onPreviewCollapsed?()
        } else if selection.selection != previewedRef {
            loadPreview()
        }
    }

    private func loadPreview() {
        previewing?.cancel()
        previewing = nil
        preview = nil
        previewedRef = nil
        guard isPreviewExpanded, let ref = selection.selection, let repository = services()?.repository else { return }
        previewedRef = ref
        let row = selection.rows.first { $0.ref == ref }
        let kind = row?.kind ?? .other
        // Only text is decoded; other kinds show what the row already knows.
        guard kind == .text || kind == .url else {
            preview = .info(kind: kind, sourceApp: row?.sourceApp)
            return
        }
        previewing = Task {
            let content: PreviewContent
            do {
                let resolved = try await repository.read(ref)
                content = await Task.detached(priority: .userInitiated) { Self.preview(of: resolved, row: row) }.value
            } catch {
                content = .failed(.contentUnavailable)
            }
            guard !Task.isCancelled, self.previewedRef == ref, self.isPreviewExpanded else { return }
            self.preview = content
        }
    }

    private func cancelLoads() {
        loading?.cancel()
        loading = nil
        refreshing?.cancel()
        refreshing = nil
        loadingMore?.cancel()
        loadingMore = nil
        previewing?.cancel()
        previewing = nil
        previewedRef = nil
    }

    nonisolated private static func preview(of content: ResolvedContent, row: QuickAccessRow?) -> PreviewContent {
        guard content.isActionable else { return .failed(.contentUnavailable) }
        guard let text = ClipboardTextDecoder.preview(content.representations, maximumBytes: previewByteLimit) else {
            return .info(kind: row?.kind ?? .other, sourceApp: row?.sourceApp)
        }
        return .text(text.text, isTruncated: text.isTruncated)
    }

    private static func notice(for state: SearchIndexState) -> IndexNotice? {
        switch state {
        case .rebuilding: .rebuilding
        case .unavailable: .searchUnavailable
        case .ready, .updating: nil
        }
    }

    private static func row(from summary: ItemSummary) -> QuickAccessRow? {
        guard let history = summary.history else { return nil }
        return QuickAccessRow(ref: history, title: summary.title, snippet: nil, kind: summary.kind,
                              sourceApp: summary.sourceApp, date: summary.lastCopiedAt,
                              savedAsMemo: summary.memo != nil, isPartiallyIndexed: false, isTextUnavailable: false)
    }

    private static func row(from result: SearchResult) -> QuickAccessRow {
        QuickAccessRow(ref: result.ref, title: result.title, snippet: result.snippet, kind: result.kind,
                       sourceApp: result.sourceApp, date: result.lastCopiedAt, savedAsMemo: result.savedAsMemo,
                       isPartiallyIndexed: result.isPartiallyIndexed, isTextUnavailable: result.isTextUnavailable)
    }
}
