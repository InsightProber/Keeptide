import CoreGraphics
import Foundation
import Observation

/// The store-backed services quick access reads and acts through; nil while the
/// library is not open.
@MainActor
struct QuickAccessServices {
    let repository: ContentRepository
    let search: SearchService?
    let paste: PasteService
    /// What the strip frames and the image preview show comes from here; without it they show only what a
    /// row already knows.
    var preview: PreviewService? = nil
}

enum QuickAccessPhase: Equatable {
    case loading, results, noContent, noResults, libraryUnavailable
}

enum IndexNotice: Equatable {
    case rebuilding, searchUnavailable
}

enum PreviewContent: Equatable {
    case text(String, isTruncated: Bool)
    case image(CGImage, pixelSize: CGSize)
    case info(kind: ContentKind, sourceApp: String?)
    case failed(PasteRefusal)
}

extension ContentKind {
    /// The kinds quick access filters by, in the toolbar's order.
    static let filters: [ContentKind] = [.text, .url, .image, .file]

    /// The kind's name in the toolbar.
    var filterTitle: String {
        switch self {
        case .text: "Text"
        case .url: "Links"
        case .image: "Images"
        case .file: "Files"
        case .other: "Other"
        }
    }
}

/// What the quick access panel lists, which row is selected, and what an action may
/// touch. Every load belongs to one query generation of the panel's paste session, so
/// results that arrive after the query, filters or session changed are dropped. Clip
/// details are the exception: they belong to the clip, not to a generation.
@MainActor @Observable
final class QuickAccessState {
    static let recentLimit = 200
    static let pageSize = 60
    nonisolated static let previewByteLimit = 262_144
    /// The preview card is at most 760 pt wide, which is 1520 px at 2x.
    static let previewImagePixels = 1520
    /// Clip details read at once. Each read takes the whole clip through the store's one writer context, which a
    /// copy reads through as well, so a copy made just after the panel opens waits behind these few reads and
    /// not behind one for every frame.
    static let detailReadLimit = 2

    private(set) var query = ""
    private(set) var kinds: Set<ContentKind> = []
    private(set) var selection = SelectionCoordinator()
    private(set) var phase = QuickAccessPhase.libraryUnavailable
    private(set) var indexNotice: IndexNotice?
    private(set) var isPreviewExpanded = false
    private(set) var preview: PreviewContent?
    private(set) var failure: PasteRefusal?
    /// What strip frames show of a clip beyond its title. Only clips still in the list keep one.
    private(set) var details: [ContentRef: ClipDetail] = [:]
    /// Whether the search was unfolded by hand or by typing, and has not been folded since.
    private(set) var isSearchUnfolded = false
    @ObservationIgnored var onCopied: (@MainActor () -> Void)?
    /// Called when the state collapses the preview itself, so the panel can restore its frame.
    @ObservationIgnored var onPreviewCollapsed: (@MainActor () -> Void)?

    @ObservationIgnored private let services: @MainActor () -> QuickAccessServices?
    @ObservationIgnored private var session: PasteSession?
    @ObservationIgnored private var isOpen = false
    /// The session a copy is running for; a reopened panel's session can copy at once.
    @ObservationIgnored private var copying: PasteSession?
    private var totalMatches = 0
    @ObservationIgnored private var previewedRef: ContentRef?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var loadingMore: Task<Void, Never>?
    /// Set once a page of the current generation added no rows; the generation asks for no more pages.
    private var pagingStopped = false
    @ObservationIgnored private var previewing: Task<Void, Never>?
    /// One read per clip whose detail is wanted, running or finished. A load that has finished stays listed
    /// while its clip is still requested, so a clip that cannot be read is not read again on every request.
    @ObservationIgnored private var detailLoads: [ContentRef: Task<Void, Never>] = [:]
    /// Requested clips that wait for a read, nearest the middle first, at the frame size in `detailFrameSize`.
    @ObservationIgnored private var waitingDetails: [ContentRef] = []
    @ObservationIgnored private var detailFrameSize = CGSize.zero
    /// Reads started and not yet returned. One that was cancelled still counts until it returns, since it
    /// keeps its place on the writer context until then.
    @ObservationIgnored private var detailReadsRunning = 0

    init(services: @escaping @MainActor () -> QuickAccessServices?) {
        self.services = services
    }

    /// An empty or invisible query with no filters lists recent clips without the index.
    var showsRecentClips: Bool { ParsedQuery(query).isEmpty && kinds.isEmpty }

    var hasFiltersOrQuery: Bool { !query.isEmpty || !kinds.isEmpty }

    /// The search shows as its field rather than its icon while there is a query, and once it was unfolded until it
    /// is folded again.
    var isSearchExpanded: Bool { !query.isEmpty || isSearchUnfolded }

    /// A search has another page to fetch, so the last row listed is not the last there is.
    var hasMoreRows: Bool { !showsRecentClips && !pagingStopped && totalMatches > selection.rows.count }

    func open() {
        isOpen = true
        query = ""
        kinds = []
        isSearchUnfolded = false
        isPreviewExpanded = false
        selection = SelectionCoordinator()
        dropDetailsOfUnlistedRows()
        startSession()
    }

    func close() {
        isOpen = false
        cancelLoads()
        detailLoads.values.forEach { $0.cancel() }
        detailLoads = [:]
        waitingDetails = []
        details = [:]
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

    func unfoldSearch() {
        isSearchUnfolded = true
    }

    /// Folding an empty search changes nothing in the list.
    func foldSearch() {
        isSearchUnfolded = false
    }

    /// Clears the query and the filters and folds the search, as Escape does.
    func clearQueryAndFilters() {
        isSearchUnfolded = false
        guard hasFiltersOrQuery else { return }
        query = ""
        kinds = []
        reload()
    }

    /// Reads the detail of each requested clip that has none yet, `detailReadLimit` at a time in the order
    /// given, which is nearest the middle first, and stops reading the clips no longer requested. `frameSize`
    /// is in pixels. A clip's stored content never changes, so its detail belongs to the clip and not to the
    /// query generation it was asked for under: it applies for as long as the row is in the list. A clip
    /// that is not in the list is ignored.
    func loadDetails(for refs: [ContentRef], frameSize: CGSize) {
        guard isOpen, services()?.preview != nil else { return }
        let requested = Set(refs)
        for ref in detailLoads.keys where !requested.contains(ref) {
            detailLoads.removeValue(forKey: ref)?.cancel()
        }
        waitingDetails = refs.filter { details[$0] == nil && detailLoads[$0] == nil }
        detailFrameSize = frameSize
        startDetailReads()
    }

    /// Starts the next waiting reads while fewer than `detailReadLimit` run; each read starts the next as it
    /// returns.
    private func startDetailReads() {
        guard isOpen, let service = services()?.preview else { return }
        while detailReadsRunning < Self.detailReadLimit, !waitingDetails.isEmpty {
            let ref = waitingDetails.removeFirst()
            guard details[ref] == nil, detailLoads[ref] == nil,
                  let kind = selection.rows.first(where: { $0.ref == ref })?.kind else { continue }
            detailReadsRunning += 1
            let frameSize = detailFrameSize
            detailLoads[ref] = Task {
                let detail = try? await service.detail(for: ref, kind: kind, frameSize: frameSize)
                self.detailReadsRunning -= 1
                if let detail, !Task.isCancelled, self.selection.rows.contains(where: { $0.ref == ref }) {
                    self.details[ref] = detail
                }
                self.startDetailReads()
            }
        }
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

    /// What a key press may act on, captured when the key is pressed.
    struct CopyTarget: Equatable {
        let ref: ContentRef
        let generation: UInt64
    }

    var copyTarget: CopyTarget? {
        selection.executableSelection.map { CopyTarget(ref: $0, generation: selection.generation) }
    }

    /// Copies what was selected when the key was pressed, never a row selected later.
    func copy(_ target: CopyTarget, mode: PasteMode) async {
        guard let session, copying !== session, let paste = services()?.paste else { return }
        copying = session
        defer { if copying === session { copying = nil } }
        failure = nil
        let outcome = await paste.execute(PasteRequest(ref: target.ref, queryGeneration: target.generation, mode: mode,
                                                       session: session))
        // A reopened panel or a newer selection owns the screen now.
        guard isOpen, self.session === session else { return }
        switch outcome {
        case .copied: onCopied?()
        case .refused(let refusal): if selection.selection == target.ref { failure = refusal }
        }
    }

    func copySelection(_ mode: PasteMode) async {
        guard let target = copyTarget else { return }
        await copy(target, mode: mode)
    }

    func loadMoreIfNeeded(visibleRow index: Int) {
        guard hasMoreRows, loadingMore == nil, phase == .results, index >= selection.rows.count - 10,
              let search = services()?.search, let generation = currentGeneration else { return }
        let request = SearchRequest(query: query, kinds: kinds, generation: generation,
                                    offset: selection.rows.count, limit: Self.pageSize)
        loadingMore = Task {
            defer { if self.currentGeneration == generation { self.loadingMore = nil } }
            do {
                for try await page in search.search(request) where page.isComplete {
                    guard self.isCurrent(generation) else { return }
                    let listed = self.selection.rows.count
                    self.selection.append(page.results.map { Self.row(from: $0) }, generation: generation)
                    self.totalMatches = page.totalMatches
                    // A page whose rows are all listed already, as when a clip copied again moved up into the
                    // list, would come back the same however often it is asked for.
                    if self.selection.rows.count == listed { self.pagingStopped = true }
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
            dropDetailsOfUnlistedRows()
            phase = .libraryUnavailable
            indexNotice = nil
            return
        }
        let generation = session.advanceQueryGeneration()
        selection.beginGeneration(generation)
        totalMatches = 0
        pagingStopped = false
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
        dropDetailsOfUnlistedRows()
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
                dropDetailsOfUnlistedRows()
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
        dropDetailsOfUnlistedRows()
        indexNotice = .searchUnavailable
        phase = .noResults
    }

    /// A clip that left the list takes its detail, and any read of it, along.
    private func dropDetailsOfUnlistedRows() {
        let listed = Set(selection.rows.map(\.ref))
        for ref in detailLoads.keys where !listed.contains(ref) {
            detailLoads.removeValue(forKey: ref)?.cancel()
        }
        for ref in details.keys where !listed.contains(ref) {
            details[ref] = nil
        }
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
        let imageService = kind == .image ? services()?.preview : nil
        // Text is decoded, and so is an image when there is a preview service; other kinds show what the
        // row already knows.
        guard kind == .text || kind == .url || imageService != nil else {
            preview = .info(kind: kind, sourceApp: row?.sourceApp)
            return
        }
        previewing = Task {
            let content: PreviewContent
            do {
                if let imageService {
                    if let loaded = try await imageService.image(for: ref, maximumPixels: Self.previewImagePixels) {
                        content = .image(loaded.image, pixelSize: loaded.pixelSize)
                    } else {
                        content = .info(kind: kind, sourceApp: row?.sourceApp)
                    }
                } else {
                    let resolved = try await repository.read(ref)
                    content = await Task.detached(priority: .userInitiated) { Self.preview(of: resolved, row: row) }.value
                }
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

/// The status text quick access shows, kept apart from the view so it can be tested.
enum QuickAccessStatus {
    struct Message: Equatable {
        let text: String
        let detail: String?
    }

    static let rebuilding = "Index is rebuilding — results may be incomplete"

    /// What an empty result area says.
    static func empty(phase: QuickAccessPhase, notice: IndexNotice?) -> Message {
        switch phase {
        case .noContent:
            return Message(text: "No clips yet. Copy something and it shows up here.", detail: nil)
        case .libraryUnavailable:
            return Message(text: "Library unavailable", detail: "Recent clips appear here once the library opens.")
        case .noResults:
            if notice == .searchUnavailable { return Message(text: "Search is unavailable — recent clips are still here", detail: nil) }
            return Message(text: "No results", detail: notice == .rebuilding ? rebuilding : nil)
        default:
            return Message(text: "Searching…", detail: nil)
        }
    }

    /// The line above rows that are on screen.
    static func line(selectionLost: Bool, phase: QuickAccessPhase, isComplete: Bool, notice: IndexNotice?) -> String? {
        if selectionLost { return "The selected item is no longer in the results" }
        if phase == .loading || !isComplete { return "Searching…" }
        if notice == .rebuilding { return rebuilding }
        return nil
    }
}
