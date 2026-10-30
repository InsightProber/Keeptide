import CoreGraphics
import Foundation
import Observation

/// Where quick access gets its search pages: the search service, or a stand-in in tests.
protocol QuickAccessSearch: Sendable {
    func search(_ request: SearchRequest) -> AsyncThrowingStream<SearchPage, Error>
}

extension SearchService: QuickAccessSearch {}

/// Where quick access reads how often clips were used: the local usage store, or a stand-in in tests.
protocol QuickAccessUsage: Sendable {
    func frequent(minimumCount: Int64, since: Date, limit: Int) async throws -> [UsageSummary]
}

extension LocalUsageStore: QuickAccessUsage {}

/// The store-backed services quick access reads and acts through; nil while the
/// library is not open.
@MainActor
struct QuickAccessServices {
    let repository: ContentRepository
    let search: (any QuickAccessSearch)?
    let paste: PasteService
    /// What the strip frames and the image preview show comes from here; without it they show only what a
    /// row already knows.
    var preview: PreviewService? = nil
    /// How often clips were used, for the frequent wing; without it there is no wing.
    var usage: (any QuickAccessUsage)? = nil
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
    /// A clip joins the frequent wing once it was used this many times, the last time within `frequentWindow`.
    static let frequentMinimumUses: Int64 = 2
    static let frequentWindow: TimeInterval = 7_776_000      // 90 days
    /// The frequent wing lists at most this many clips.
    static let frequentLimit = 20
    /// The frequent clips read as a session starts, so that a type filter can take its first twenty from them.
    static let frequentCandidateLimit = 200

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
    /// The app window this session would paste into, recorded as the panel opened. nil without a session.
    private(set) var pasteTarget: PasteTarget?
    /// What the checks allowed for the session's target when the session started: a paste, or why not. nil without
    /// a library.
    private(set) var directPaste: DirectPasteAvailability?
    /// Whether Enable Direct Paste… asked for access in this run of Keeptide. The system shows a grant to Keeptide
    /// only once it reopens, so every later showing says so. Closing the panel keeps it.
    private(set) var hasRequestedDirectPasteAccess = false
    /// The command the selected clip's last action is waiting on. Nothing has been written or sent for it.
    private(set) var commandReview: CommandReview?
    /// Called once an action has written the clipboard, whether it pasted, copied or copied instead.
    @ObservationIgnored var onCompleted: (@MainActor (QuickAccessCompletion) -> Void)?
    /// Called when a command review appears, is replaced or is dropped. An action that completes clears the review
    /// without this call, since the panel closes.
    @ObservationIgnored var onCommandReviewChanged: (@MainActor () -> Void)?
    /// Hides the panel for a paste, before the keystroke, without ending its session. Every action passes it on.
    @ObservationIgnored var dismissForPaste: (@MainActor () -> Void)?
    /// Whether Return or keypad Enter is down in the panel now. Every action passes it on: a paste asks just before
    /// the panel would hide, and copies instead while one is.
    @ObservationIgnored var returnIsDown: (@MainActor () -> Bool)?
    /// Called when the state collapses the preview itself, so the panel can restore its frame.
    @ObservationIgnored var onPreviewCollapsed: (@MainActor () -> Void)?

    @ObservationIgnored private let services: @MainActor () -> QuickAccessServices?
    @ObservationIgnored private var session: PasteSession?
    @ObservationIgnored private var isOpen = false
    /// The session a copy is running for; a reopened panel's session can copy at once.
    @ObservationIgnored private var copying: PasteSession?
    /// The action `commandReview` is for. Confirming sends it again with the review's confirmation.
    @ObservationIgnored private var reviewedAction: (target: CopyTarget, mode: PasteMode, delivery: PasteDelivery)?
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
    /// How many cards the band showed whole as the panel opened, which the frequent wing leaves out of its clips; nil
    /// lists no wing.
    @ObservationIgnored private var frequentWingFirstScreen: Int?
    /// The session's one read of the frequent wing's candidates, in rank order: each the row of its clip, or nil where
    /// the clip cannot show. nil without a wing to read.
    @ObservationIgnored private var frequentRead: Task<[QuickAccessRow?], Never>?

    init(services: @escaping @MainActor () -> QuickAccessServices?) {
        self.services = services
    }

    /// An empty or invisible query with no filters lists recent clips without the index.
    var showsRecentClips: Bool { ParsedQuery(query).isEmpty && kinds.isEmpty }

    var hasFiltersOrQuery: Bool { !query.isEmpty || !kinds.isEmpty }

    /// The search shows as its field rather than its icon while there is a query, and once it was unfolded until it
    /// is folded again.
    var isSearchExpanded: Bool { !query.isEmpty || isSearchUnfolded }

    /// A search has another page to fetch, so the last row listed is not the last there is. The frequent wing is no
    /// page of the search, so only the rows after it count.
    var hasMoreRows: Bool {
        !showsRecentClips && !pagingStopped && totalMatches > selection.rows.count - selection.frequentCount
    }

    /// What the panel offers for the selected row.
    var actions: QuickAccessActions { actions(for: selection.selection) }

    /// What the panel offers for a listed row, such as the one a right-click is on, which need not be the selected one.
    func actions(for ref: ContentRef?) -> QuickAccessActions {
        QuickAccessActions.make(target: pasteTarget, availability: directPaste,
                                kind: ref.flatMap { ref in selection.rows.first { $0.ref == ref } }?.kind,
                                accessRequested: hasRequestedDirectPasteAccess)
    }

    /// The delivery Return and ⇧Return ask for. It is a paste only when the session started able to paste, so a
    /// panel that opened offering Copy keeps copying even once access arrives (decision 2). The paste service checks
    /// everything again before it sends.
    var preferredDelivery: PasteDelivery {
        if case .paste? = directPaste { .paste } else { .copy }
    }

    /// Records the front app window as the target, before the panel takes the keys, and lists recent clips.
    /// `firstScreen` is how many cards the band shows whole (`StripLayout.firstScreenCount`). With it the frequent wing
    /// leads the recent clips, without the clips among the first `firstScreen` of them; nil lists no wing.
    func open(frequentWingFirstScreen firstScreen: Int? = nil) {
        isOpen = true
        frequentWingFirstScreen = firstScreen
        query = ""
        kinds = []
        isSearchUnfolded = false
        isPreviewExpanded = false
        selection = SelectionCoordinator()
        dropDetailsOfUnlistedRows()
        startSession(recordingTarget: true)
    }

    func close() {
        isOpen = false
        cancelLoads()
        frequentRead?.cancel()
        frequentRead = nil
        detailLoads.values.forEach { $0.cancel() }
        detailLoads = [:]
        waitingDetails = []
        details = [:]
        session?.end()
        session = nil
        pasteTarget = nil
        directPaste = nil
        isPreviewExpanded = false
        preview = nil
        failure = nil
        dropCommandReview()
    }

    /// The library opened or closed; an open panel reloads its current query. The new session keeps the target
    /// recorded as the panel opened, and the front window is not read again (decision 1). It reads the frequent wing
    /// again, from the library it now has.
    func servicesDidChange() {
        guard isOpen else { return }
        startSession(recordingTarget: false)
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

    /// Selects a listed row. A clip listed in both wings is two rows, and each is selected on its own.
    func select(_ id: QuickAccessRow.ID) {
        selection.select(id)
        selectionChanged()
    }

    @discardableResult
    func moveSelection(by offset: Int) -> SelectionMove {
        let move = selection.move(by: offset)
        guard move == .moved else { return move }
        selectionChanged()
        if let selected = selection.selectedID, let index = selection.rows.firstIndex(where: { $0.id == selected }) {
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

    /// Acts on what was selected when the key was pressed, never a row selected later: writes the clipboard and, for
    /// a paste whose checks pass, sends ⌘V once the panel hides. A command that needs a review writes nothing; it
    /// opens the review instead. `confirmation` is the review's, once the user confirms it.
    func act(on target: CopyTarget, mode: PasteMode, delivery requested: PasteDelivery,
             confirmation: CommandConfirmation? = nil) async {
        guard let session, copying !== session, let paste = services()?.paste else { return }
        // A showing that opened offering Copy only copies, whatever is asked for (decision 2).
        let delivery = preferredDelivery == .paste ? requested : .copy
        copying = session
        defer { if copying === session { copying = nil } }
        failure = nil
        let outcome = await paste.execute(PasteRequest(ref: target.ref, queryGeneration: target.generation, mode: mode,
                                                       session: session, delivery: delivery, dismiss: dismissForPaste,
                                                       returnIsDown: returnIsDown, confirmation: confirmation))
        // A reopened panel or a newer selection owns the screen now.
        guard isOpen, self.session === session else { return }
        switch outcome {
        case .copied: complete(.copied)
        case .copiedInstead(let fallback): complete(.copiedInstead(fallback))
        case .dispatched: complete(.dispatched)
        case .needsConfirmation(let review):
            // A review is for the selected row: one that comes back after the selection moved on is not shown.
            guard selection.selection == target.ref else { return }
            reviewedAction = (target, mode, delivery)
            commandReview = review
            onCommandReviewChanged?()
        case .refused(let refusal):
            if selection.selection == target.ref { failure = refusal }
        }
    }

    /// Sends the reviewed action again, with the review's confirmation. The paste service checks the clip, the
    /// target and the delivery again, so any change comes back as a new review.
    func confirmCommand() async {
        guard let commandReview, let reviewedAction else { return }
        await act(on: reviewedAction.target, mode: reviewedAction.mode, delivery: reviewedAction.delivery,
                  confirmation: commandReview.confirmation)
    }

    func cancelCommandReview() {
        dropCommandReview()
    }

    /// Enable Direct Paste…: asks for access, and opens Accessibility settings when the system no longer asks. The
    /// request is remembered for the rest of this run. What the panel offers to do stays as it was when it opened.
    func requestDirectPasteAccess() {
        guard let paste = services()?.paste else { return }
        paste.requestDirectPasteAccess()
        hasRequestedDirectPasteAccess = true
    }

    /// Copies what was selected when the key was pressed, never a row selected later.
    func copy(_ target: CopyTarget, mode: PasteMode) async {
        await act(on: target, mode: mode, delivery: .copy)
    }

    func copySelection(_ mode: PasteMode) async {
        guard let target = copyTarget else { return }
        await copy(target, mode: mode)
    }

    func loadMoreIfNeeded(visibleRow index: Int) {
        guard hasMoreRows, loadingMore == nil, phase == .results, index >= selection.rows.count - 10,
              let search = services()?.search, let generation = currentGeneration else { return }
        // The search's own rows follow the frequent wing, which is no page of it.
        let request = SearchRequest(query: query, kinds: kinds, generation: generation,
                                    offset: selection.rows.count - selection.frequentCount, limit: Self.pageSize)
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

    /// Starts a paste session and reloads. Only an opening panel records the front app window as the target; a
    /// later session keeps the previous session's target, or has none. Each session's checks run once, here, and
    /// never ask for access.
    private func startSession(recordingTarget: Bool) {
        let previousTarget = pasteTarget
        session?.end()
        if let paste = services()?.paste {
            let session = recordingTarget ? paste.beginSession() : paste.beginSession(target: previousTarget)
            self.session = session
            pasteTarget = session.target
            directPaste = paste.availability(for: session)
        } else {
            session = nil
            pasteTarget = nil
            directPaste = nil
        }
        readFrequentWing()
        reload()
    }

    /// Starts the session's one read of the frequent wing's candidates, which every list of the session takes its wing
    /// from: uses recorded while the panel is open show the next time it opens. A read that fails finds none, and the
    /// recent clips are listed without a wing.
    private func readFrequentWing() {
        frequentRead?.cancel()
        frequentRead = nil
        guard frequentWingFirstScreen != nil, let services = services(), let usage = services.usage else { return }
        let repository = services.repository
        frequentRead = Task {
            do {
                let uses = try await usage.frequent(minimumCount: Self.frequentMinimumUses,
                                                    since: Date(timeIntervalSinceNow: -Self.frequentWindow),
                                                    limit: Self.frequentCandidateLimit)
                try Task.checkCancellation()
                let items = try await repository.summaries(for: uses.map(\.itemID))
                return Self.frequentCandidates(uses, items)
            } catch {
                return []
            }
        }
    }

    private func reload() {
        cancelLoads()
        failure = nil
        preview = nil
        // A review belongs to the query it was made under, even when the new one keeps the clip selected.
        dropCommandReview()
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
        guard let rows = await ledByFrequentWing((summaries ?? []).compactMap { Self.row(from: $0) },
                                                 generation: generation) else { return }
        applyRows(rows, generation: generation, isComplete: true)
        phase = summaries == nil ? .libraryUnavailable : (rows.isEmpty ? .noContent : .results)
    }

    private func loadSearch(_ search: (any QuickAccessSearch)?, _ request: SearchRequest) async {
        let generation = request.generation
        guard let search else {
            if isCurrent(generation) { showSearchUnavailable(generation) }
            return
        }
        do {
            for try await page in search.search(request) {
                guard isCurrent(generation),
                      let rows = await ledByFrequentWing(page.results.map { Self.row(from: $0) },
                                                         generation: generation) else { return }
                applyRows(rows, generation: generation, isComplete: page.isComplete, keepsChosenRow: true)
                totalMatches = page.totalMatches
                indexNotice = Self.notice(for: page.indexState)
                phase = !rows.isEmpty ? .results : (page.isComplete ? .noResults : .loading)
            }
        } catch {
            guard isCurrent(generation) else { return }
            showSearchUnavailable(generation)
        }
    }

    /// `rows` led by the frequent wing, once the session's read of it is done, so that the two show together and the
    /// film does not jump. Without a filter the wing lists those of the first `frequentLimit` candidates that can show,
    /// and leaves a rank that cannot show empty; with one, the first `frequentLimit` of every candidate that match it.
    /// Either way it leaves out the clips among the first screen of `rows`. A query with words lists its results
    /// alone, without waiting for the read, and there is no wing over no rows. nil once `generation` is not current.
    private func ledByFrequentWing(_ rows: [QuickAccessRow], generation: UInt64) async -> [QuickAccessRow]? {
        guard !rows.isEmpty, let firstScreen = frequentWingFirstScreen, let read = frequentRead,
              ParsedQuery(query).isEmpty else { return rows }
        let candidates = await read.value
        guard isCurrent(generation) else { return nil }
        let pool = kinds.isEmpty ? Array(candidates.prefix(Self.frequentLimit)) : candidates
        let shown = pool.compactMap { $0 }.filter { kinds.isEmpty || kinds.contains($0.kind) }
            .prefix(Self.frequentLimit)
        let firstScreenClips = Set(rows.prefix(firstScreen).map(\.ref))
        return shown.filter { !firstScreenClips.contains($0.ref) } + rows
    }

    private func showSearchUnavailable(_ generation: UInt64) {
        applyRows([], generation: generation, isComplete: true)
        indexNotice = .searchUnavailable
        phase = .noResults
    }

    /// Lists a page of rows. Every page goes through here, so that what the panel shows for a row stays with the
    /// selection whatever the page did to it: details of clips no longer listed go, and so does a review or a preview
    /// of a row that is no longer selected.
    private func applyRows(_ rows: [QuickAccessRow], generation: UInt64, isComplete: Bool,
                           keepsChosenRow: Bool = false) {
        selection.apply(rows, generation: generation, isComplete: isComplete, keepsChosenRow: keepsChosenRow)
        dropDetailsOfUnlistedRows()
        followSelection()
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

    /// The clipboard is written, so the review, if any, is done with. The panel closes on `onCompleted`.
    private func complete(_ completion: QuickAccessCompletion) {
        commandReview = nil
        reviewedAction = nil
        onCompleted?(completion)
    }

    private func dropCommandReview() {
        guard commandReview != nil else { return }
        commandReview = nil
        reviewedAction = nil
        onCommandReviewChanged?()
    }

    /// Keeps what the panel shows for a row on the selected row. A command review of another row, or of a row that
    /// is gone, is dropped. An open preview never shows another row's content, and it collapses when the selected
    /// row is gone.
    private func followSelection() {
        if let reviewedAction, selection.selection != reviewedAction.target.ref { dropCommandReview() }
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

    /// The frequent wing's candidates in rank order: each the row of its clip with its use count, or nil where the clip
    /// cannot show, as when it was deleted or left the history. An item ranked twice keeps its first place.
    private static func frequentCandidates(_ uses: [UsageSummary], _ items: [ItemSummary]) -> [QuickAccessRow?] {
        let itemsByID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        var ranked = Set<ItemID>()
        return uses.filter { ranked.insert($0.itemID).inserted }.map { use in
            guard var row = itemsByID[use.itemID].flatMap({ Self.row(from: $0) }) else { return nil }
            row.frequentUses = use.useCount
            return row
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

    /// What the toolbar says over rows that are on screen, in place of Return's hint. An index that is rebuilding
    /// takes no such place: the toolbar says so at its left end.
    static func line(selectionLost: Bool, phase: QuickAccessPhase, isComplete: Bool) -> String? {
        if selectionLost { return "The selected item is no longer in the results" }
        if phase == .loading || !isComplete { return "Searching…" }
        return nil
    }
}
