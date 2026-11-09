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

/// Where quick access moves a clip or snippet to Recently Deleted and back: the library's maintenance, which keeps one
/// library's lifetime and takes one action at a time, or a stand-in in tests.
@MainActor
protocol QuickAccessLifecycle: AnyObject, Sendable {
    /// Moves exactly this facet generation to Recently Deleted; nil when it could not.
    func moveToRecentlyDeleted(_ ref: ContentRef) async -> DeletedFacetIdentity?
    /// Puts back what a move took; false when it could not.
    func recover(_ target: DeletedFacetIdentity) async -> Bool
}

/// What one Move to Recently Deleted from quick access took off the strip, for its undo.
struct QuickAccessDeletion: Sendable {
    /// What went to Recently Deleted.
    let moved: DeletedFacetIdentity
    let ref: ContentRef
    let title: String
    let rows: SelectionCoordinator.RemovedRows
    /// The library it was moved in, held so that it is told apart from any library opened since: an undo puts back
    /// only what this one moved.
    let lifecycle: any QuickAccessLifecycle
}

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
    /// Saving a capture as a snippet uses the same service and transaction rules as the library.
    var library: LibraryService? = nil
    /// Local-only file authorization. These never leave the active store generation.
    var fileAccess: FileAccessStore? = nil
    var fileAccessIdentity: StoreIdentity? = nil
    /// The collections the memo lists can narrow to; without it there are none.
    var collections: (any QuickAccessCollections)? = nil
    /// Moving snippets between collections and marking them as favorites; without it a saved clip can only be saved.
    var collectionChanges: (any QuickAccessCollectionChanges)? = nil
    /// Moving clips and snippets to Recently Deleted and back; without it nothing can be moved there from the panel.
    var lifecycle: (any QuickAccessLifecycle)? = nil
    /// Recognizing the text in images and reading what was recognized before; without it the preview has no text
    /// column.
    var derivedText: DerivedTextCoordinator? = nil
}

/// A column of derived text beside the preview. Only an image has one now: the text recognized in it.
enum ResultColumn: Equatable, Sendable {
    case text
}

/// What the text column shows for the selected image.
enum TextColumn: Equatable {
    /// What was made before is still being read.
    case loading
    /// Nothing has been made of the image's text yet: the column offers to extract it.
    case notStarted
    /// Recognition is waiting or under way.
    case recognizing(GenerationSnapshot)
    /// The image's text, made now or kept from before.
    case text(String, status: DerivedTextStatus)
    /// The text was made, but the library couldn't keep it.
    case unsaved(String)
    /// The image has no text.
    case noText
    case failed(GenerationError)
}

enum QuickAccessPhase: Equatable {
    case loading, results, noContent, noResults, libraryUnavailable
}

enum IndexNotice: Equatable {
    case rebuilding, searchUnavailable
}

enum PreviewContent: Equatable {
    case text(String, isTruncated: Bool)
    case markdown(MarkdownPreviewDocument, isTruncated: Bool)
    case url(title: String?, address: String)
    case image(CGImage, pixelSize: CGSize)
    case files([FilePreviewReference])
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
    nonisolated static let previewByteLimit = PreviewService.fullPreviewByteLimit
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
    /// Which rows are listed; every opening starts on `.all`.
    private(set) var list: QuickAccessList = .all
    /// Lists only favorite memos; never on under `.all`.
    private(set) var favoritesOnly = false
    /// The collections in the sidebar's order, as read for this opening.
    private(set) var collections: [CollectionSummary] = []
    /// The collections could not be read for this opening.
    private(set) var collectionsUnavailable = false
    private(set) var selection = SelectionCoordinator()
    private(set) var phase = QuickAccessPhase.libraryUnavailable
    private(set) var indexNotice: IndexNotice?
    private(set) var isPreviewExpanded = false {
        // A column belongs to the preview, and closes with it however the preview closes.
        didSet { if !isPreviewExpanded { resultColumn = nil } }
    }
    /// The column beside the preview, while one is chosen. It shows only for a clip that has one, and stays chosen
    /// while the selection moves through clips that don't.
    private(set) var resultColumn: ResultColumn?
    /// Whether text recognized in an image keeps the image's line breaks or joins lines into paragraphs. The panel
    /// sets it from the person's choice as it opens.
    var keepsLineBreaks = true
    /// The image the saved text below was read for. Until it is the previewed image, the column is still reading.
    private var savedTextRef: ContentRef?
    /// What an earlier job saved of the previewed image's text, if anything.
    private var savedText: DerivedText?
    @ObservationIgnored private var readingSavedText: Task<Void, Never>?
    /// The image whose text the person asked for: once what was saved for it has been read, it is recognized if
    /// nothing was.
    @ObservationIgnored private var recognizesOnceRead: ContentRef?
    private(set) var preview: PreviewContent?
    private(set) var isLoadingOriginalPreview = false
    private(set) var previewMessage: String?
    private(set) var failure: PasteRefusal?
    /// What the selected clip's last Save as Snippet, or its undo, came to. It belongs to that clip as `failure` does,
    /// and goes with it when the selection, the query or the filters change.
    private(set) var saveMessage: String?
    /// Whether the selected clip's last save made a snippet that Undo Save as Snippet may still remove.
    private(set) var canUndoSave = false
    /// What strip frames show of a clip beyond its title. Only clips still in the list keep one.
    private(set) var details: [ContentRef: ClipDetail] = [:]
    /// Whether the search was unfolded by hand or by typing, and has not been folded since.
    private(set) var isSearchUnfolded = false
    /// The app window this session would paste into, recorded as the panel opened. nil without a session.
    private(set) var pasteTarget: PasteTarget?
    /// What the checks allowed for the session's target when the session started: a paste, or why not. nil without
    /// a library.
    private(set) var directPaste: DirectPasteAvailability?
    /// Whether the session started without permission after this run asked for access: the system lets Keeptide send
    /// keystrokes only once it reopens, so the panel says so. Closing the panel keeps the request.
    private(set) var directPasteAwaitsReopen = false
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
    /// Says a short message aloud for VoiceOver, such as when the listed collection goes away.
    @ObservationIgnored var announce: (@MainActor (String) -> Void)?

    @ObservationIgnored private let services: @MainActor () -> QuickAccessServices?
    @ObservationIgnored private var session: PasteSession?
    @ObservationIgnored private var isOpen = false
    /// The session a copy is running for; a reopened panel's session can copy at once.
    @ObservationIgnored private var copying: PasteSession?
    /// The action `commandReview` is for. Confirming sends it again with the review's confirmation.
    @ObservationIgnored private var reviewedAction: (target: CopyTarget, mode: PasteMode, delivery: PasteDelivery)?
    private var totalMatches = 0
    @ObservationIgnored private var previewedRef: ContentRef?
    @ObservationIgnored private var previewGeneration: UInt64 = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var loadingMore: Task<Void, Never>?
    /// Set once a page of the current generation added no rows; the generation asks for no more pages.
    private var pagingStopped = false
    @ObservationIgnored private var previewing: Task<Void, Never>?
    @ObservationIgnored private var loadingOriginalPreview: Task<Void, Never>?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var savedUndo: (
        ref: ContentRef,
        itemID: ItemID,
        memoID: UUID,
        fingerprint: Data,
        identity: StoreIdentity
    )?
    /// One read per clip whose detail is wanted, running or finished. A load that has finished stays listed
    /// while its clip is still requested, so a clip that cannot be read is not read again on every request.
    @ObservationIgnored private var detailLoads: [ContentRef: Task<Void, Never>] = [:]
    /// Requested clips that wait for a read, nearest the middle first, at the frame size in `detailFrameSize`.
    @ObservationIgnored private var waitingDetails: [ContentRef] = []
    @ObservationIgnored private var detailFrameSize = CGSize.zero
    /// Reads started and not yet returned. One that was cancelled still counts until it returns, since it
    /// keeps its place on the writer context until then.
    @ObservationIgnored private var detailReadsRunning = 0
    /// How many of the newest clips the band shows whole as the panel opens, for a frequent wing of so many clips
    /// before them: the wing leaves those clips out. nil lists no wing.
    @ObservationIgnored private var frequentWingFirstScreen: ((Int) -> Int)?
    /// The session's one read of the frequent wing's candidates, in rank order: each the row of its clip, or nil where
    /// the clip cannot show. nil without a wing to read.
    @ObservationIgnored private var frequentRead: Task<[QuickAccessRow?], Never>?
    /// The opening's read of the collections, or one asked for since.
    @ObservationIgnored private var collectionsRead: Task<Void, Never>?
    /// The list was changed, and VoiceOver is to hear which once its first page is in.
    @ObservationIgnored private var announcesList = false
    /// The clips and snippets moved to Recently Deleted from this showing, or on their way there. Every page leaves
    /// them out: a refresh that read the store before a move, the frequent wing read as the panel opened and an index
    /// that has not caught up yet would otherwise list them again.
    @ObservationIgnored private var hiddenFacets: Set<HiddenFacet> = []
    /// The snippets taken out of a collection in this showing, by collection: that collection's list leaves them out,
    /// for an index that has not caught up yet.
    @ObservationIgnored private var leftCollections: [CollectionID: Set<HiddenFacet>] = [:]

    private struct HiddenFacet: Hashable {
        let itemID: ItemID
        let facet: ContentFacet

        init(_ ref: ContentRef) {
            itemID = ref.itemID
            facet = ref.facet
        }
    }

    init(services: @escaping @MainActor () -> QuickAccessServices?) {
        self.services = services
    }

    /// An empty or invisible query with no filters, under `.all`, lists recent clips without the index.
    var showsRecentClips: Bool { list == .all && !favoritesOnly && ParsedQuery(query).isEmpty && kinds.isEmpty }

    var hasFiltersOrQuery: Bool { !query.isEmpty || !kinds.isEmpty || favoritesOnly }

    /// A list other than `.all` is listed.
    var hasList: Bool { list != .all }

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

    /// What Return can do in this session, whatever clip is selected: the toolbar keeps room for the widest.
    var possibleActions: [QuickAccessActions] {
        ([nil] + [ContentKind.text, .url, .image, .file, .other]).map { kind in
            QuickAccessActions.make(target: pasteTarget, availability: directPaste, kind: kind,
                                    awaitsReopen: directPasteAwaitsReopen)
        }
    }

    /// What the panel offers for a listed row, such as the one a right-click is on, which need not be the selected one.
    func actions(for ref: ContentRef?) -> QuickAccessActions {
        QuickAccessActions.make(target: pasteTarget, availability: directPaste,
                                kind: ref.flatMap { ref in selection.rows.first { $0.ref == ref } }?.kind,
                                awaitsReopen: directPasteAwaitsReopen)
    }

    /// The delivery Return and ⇧Return ask for. It is a paste only when the session started able to paste, so a
    /// panel that opened offering Copy keeps copying even once access arrives (decision 2). The paste service checks
    /// everything again before it sends.
    var preferredDelivery: PasteDelivery {
        if case .paste? = directPaste { .paste } else { .copy }
    }

    /// Records the front app window as the target, before the panel takes the keys, and lists recent clips.
    /// `firstScreen` says how many of the newest clips the band shows whole as it opens with a frequent wing of so
    /// many clips before them (`StripLayout.recentShownWhole`). With it the frequent wing leads the recent clips,
    /// without the clips the band shows whole; nil lists no wing.
    func open(frequentWingFirstScreen firstScreen: ((Int) -> Int)? = nil) {
        clearSaveStatus()
        hiddenFacets = []
        leftCollections = [:]
        isOpen = true
        frequentWingFirstScreen = firstScreen
        query = ""
        kinds = []
        list = .all
        favoritesOnly = false
        announcesList = false
        isSearchUnfolded = false
        isPreviewExpanded = false
        selection = SelectionCoordinator()
        dropDetailsOfUnlistedRows()
        startSession(recordingTarget: true)
    }

    func close() {
        isOpen = false
        // A list changed just before closing is not announced later.
        announcesList = false
        cancelLoads()
        frequentRead?.cancel()
        frequentRead = nil
        collectionsRead?.cancel()
        collectionsRead = nil
        detailLoads.values.forEach { $0.cancel() }
        detailLoads = [:]
        waitingDetails = []
        details = [:]
        session?.end()
        session = nil
        pasteTarget = nil
        directPaste = nil
        directPasteAwaitsReopen = false
        isPreviewExpanded = false
        preview = nil
        previewMessage = nil
        isLoadingOriginalPreview = false
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

    /// Clears the type filter, as All Types does.
    func clearKinds() {
        guard !kinds.isEmpty else { return }
        kinds = []
        reload()
    }

    /// The name of the collection listed, for the toolbar and the empty states; nil for the other lists.
    var collectionName: String? {
        guard case .collection(let id) = list else { return nil }
        return collections.first { $0.id == id }?.name
    }

    /// Lists another set of rows. The query and the type filter stay and run again over it; Favorites Only is
    /// cleared on the way to `.all`. The preview folds, the save status goes, and the first row is selected.
    func setList(_ list: QuickAccessList) {
        guard isOpen, list != self.list else { return }
        self.list = list
        if list == .all { favoritesOnly = false }
        collapsePreview()
        reload()
        // VoiceOver hears the list and how many it holds once its first page is in.
        announcesList = true
    }

    /// Lists only favorite memos, or every memo again. Under `.all` the list changes to `.snippets` first, since
    /// only memos can be favorites.
    func toggleFavoritesOnly() {
        guard isOpen else { return }
        if !favoritesOnly, list == .all {
            list = .snippets
            // The list changed, so VoiceOver hears which and how many it holds, as after any change of list.
            announcesList = true
        }
        favoritesOnly.toggle()
        collapsePreview()
        reload()
    }

    /// The Library changed the collections: they are read again, and a listed collection that is gone gives way
    /// to `.snippets`.
    func collectionsDidChange() {
        guard isOpen else { return }
        readCollections()
    }

    /// Changes what a listed clip's rows say, such as that it was saved, without reloading the list.
    func updateRow(ref: ContentRef, _ change: (inout QuickAccessRow) -> Void) {
        selection.updateRows(of: ref, change)
    }

    /// Folds the preview, as a change of list does, and tells the panel.
    private func collapsePreview() {
        guard isPreviewExpanded else { return }
        isPreviewExpanded = false
        onPreviewCollapsed?()
    }

    /// Reads the collections for this opening, or again after the Library changed them. A listed collection that is
    /// gone gives way to `.snippets`, and VoiceOver hears why.
    private func readCollections() {
        collectionsRead?.cancel()
        guard let reader = services()?.collections else {
            collections = []
            collectionsUnavailable = false
            collectionsRead = nil
            return
        }
        collectionsRead = Task {
            let read = try? await reader.collections()
            guard !Task.isCancelled, isOpen else { return }
            collections = read ?? []
            collectionsUnavailable = read == nil
            // A read that fails says nothing about the listed collection; only one that succeeds without it does.
            if let read, case .collection(let id) = list, !read.contains(where: { $0.id == id }) {
                setList(.snippets)
                // Why the list changed is what VoiceOver says, without the new list's count after it.
                announcesList = false
                announce?("Collection removed")
            }
        }
    }

    func unfoldSearch() {
        isSearchUnfolded = true
    }

    /// Folding an empty search changes nothing in the list.
    func foldSearch() {
        isSearchUnfolded = false
    }

    /// Clears the query, the filters and the list, and folds the search, as Escape does.
    func clearQueryAndFilters() {
        isSearchUnfolded = false
        guard hasFiltersOrQuery || hasList else { return }
        query = ""
        kinds = []
        list = .all
        favoritesOnly = false
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

    /// Selects a listed row. A clip listed in both wings is two rows, and each is selected on its own. Selecting the
    /// row already selected, as a second click on its card does, keeps what its save came to.
    func select(_ id: QuickAccessRow.ID) {
        let selected = selection.selectedID
        selection.select(id)
        guard selection.selectedID == selected else { return selectionChanged() }
        failure = nil
        followSelection()
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

    /// The image whose text the column shows: the selected clip, while the preview is open with the text column
    /// chosen and the clip is an image.
    var textColumnRef: ContentRef? {
        guard resultColumn == .text, isPreviewExpanded, let row = selection.selectedRow, row.kind == .image else {
            return nil
        }
        return row.ref
    }

    /// Whether the selected clip is an image whose text the preview can show beside it.
    var offersTextInImage: Bool {
        selection.selectedRow?.kind == .image && services()?.derivedText != nil
    }

    /// What the text column shows, while it shows: a job under way, then how the latest job ended, and otherwise what
    /// an earlier one saved.
    var textColumn: TextColumn? {
        guard let ref = textColumnRef, let derivedText = services()?.derivedText else { return nil }
        if let job = derivedText.job(for: ref, operation: .extractText) { return .recognizing(job.snapshot) }
        switch derivedText.outcome(for: ref, operation: .extractText) {
        // Recognition on this Mac ends whole or not at all, so the text being saved is whole.
        case .saving(let made)?: return .text(made, status: .complete)
        case .saved(let result)?: return .text(result.text, status: result.status)
        case .noText?: return .noText
        case .notSaved(let made)?: return .unsaved(made)
        case .failed(let error)?: return .failed(error)
        case nil: break
        }
        guard savedTextRef == ref else { return .loading }
        return savedText.map { .text($0.text, status: $0.status) } ?? .notStarted
    }

    /// Opens the preview with the text in the selected image beside it, and recognizes the text when nothing has been
    /// made of it yet. Nothing happens for a clip that isn't an image.
    func showTextInImage() {
        guard let row = selection.selectedRow, row.kind == .image, services()?.derivedText != nil else { return }
        resultColumn = .text
        recognizesOnceRead = row.ref
        if isPreviewExpanded {
            recognizeIfNothingMade()
        } else {
            isPreviewExpanded = true
            loadPreview()
        }
    }

    func closeResultColumn() {
        resultColumn = nil
        recognizesOnceRead = nil
    }

    /// Recognizes the text in the image the column shows, again if it was made before.
    func extractText() {
        guard let ref = textColumnRef else { return }
        services()?.derivedText?.extractText(from: ref, keepingLineBreaks: keepsLineBreaks)
    }

    func stopTextRecognition() {
        guard let ref = textColumnRef else { return }
        services()?.derivedText?.stop(ref, operation: .extractText)
    }

    /// Lays out recognized text line by line or as paragraphs. Text shown or being made is recognized again in the new
    /// layout.
    func setKeepsLineBreaks(_ keeps: Bool) {
        guard keeps != keepsLineBreaks else { return }
        keepsLineBreaks = keeps
        switch textColumn {
        case .text?, .unsaved?, .recognizing?: extractText()
        default: break
        }
    }

    /// Reads what an earlier job saved of the previewed image's text, for the text column.
    private func readSavedText() {
        readingSavedText?.cancel()
        readingSavedText = nil
        savedTextRef = nil
        savedText = nil
        guard isPreviewExpanded, let row = selection.selectedRow, row.kind == .image,
              let derivedText = services()?.derivedText else { return }
        let ref = row.ref
        readingSavedText = Task { [weak self] in
            let saved = await derivedText.savedResult(for: ref, operation: .extractText)
            guard !Task.isCancelled, let self, selection.selection == ref else { return }
            savedTextRef = ref
            savedText = saved
            recognizeIfNothingMade()
        }
    }

    /// Recognizes the image the person asked about, once what was saved for it has been read and nothing was.
    private func recognizeIfNothingMade() {
        guard let ref = recognizesOnceRead, ref == textColumnRef, savedTextRef == ref else { return }
        recognizesOnceRead = nil
        if textColumn == .notStarted { extractText() }
    }

    func togglePreview() {
        isPreviewExpanded.toggle()
        loadPreview()
    }

    var fileAccessStore: FileAccessStore? { services()?.fileAccess }
    var fileAccessIdentity: StoreIdentity? { services()?.fileAccessIdentity }

    /// Explicitly requests source-resolution decoding for the image currently in
    /// the open preview. A failure leaves the fitted preview in place.
    func loadOriginalPreview() {
        guard isPreviewExpanded,
              !isLoadingOriginalPreview,
              case .image = preview,
              let ref = previewedRef,
              let service = services()?.preview else { return }
        let generation = previewGeneration
        isLoadingOriginalPreview = true
        previewMessage = nil
        loadingOriginalPreview?.cancel()
        loadingOriginalPreview = Task {
            defer {
                if self.previewedRef == ref, self.previewGeneration == generation {
                    self.isLoadingOriginalPreview = false
                    self.loadingOriginalPreview = nil
                }
            }
            do {
                guard let loaded = try await service.originalImage(for: ref) else {
                    guard !Task.isCancelled,
                          self.previewedRef == ref,
                          self.previewGeneration == generation,
                          self.isPreviewExpanded else { return }
                    self.previewMessage = "The original image could not be decoded."
                    return
                }
                guard !Task.isCancelled,
                      self.previewedRef == ref,
                      self.previewGeneration == generation,
                      self.selection.selection == ref,
                      self.isPreviewExpanded else { return }
                self.preview = .image(loaded.image, pixelSize: loaded.pixelSize)
            } catch is CancellationError {
                // Selection, closing, or a newer preview owns the result.
            } catch PreviewLoadError.originalImageTooLarge {
                guard !Task.isCancelled,
                      self.previewedRef == ref,
                      self.previewGeneration == generation,
                      self.isPreviewExpanded else { return }
                self.previewMessage = "This image is too large to load at full resolution. The fitted preview remains available."
            } catch {
                guard !Task.isCancelled,
                      self.previewedRef == ref,
                      self.previewGeneration == generation,
                      self.isPreviewExpanded else { return }
                self.previewMessage = "The original image could not be loaded. The fitted preview remains available."
            }
        }
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
    /// paste service remembers the request for the rest of this run. What the panel offers to do stays as it was when
    /// it opened.
    func requestDirectPasteAccess() {
        services()?.paste.requestDirectPasteAccess()
    }

    /// Whether Keeptide can paste directly now, for Settings to say; nil without a library.
    func directPasteAccessState() -> DirectPasteAccessState? {
        services()?.paste.accessState()
    }

    /// Copies what was selected when the key was pressed, never a row selected later.
    func copy(_ target: CopyTarget, mode: PasteMode) async {
        await act(on: target, mode: mode, delivery: .copy)
    }

    func copySelection(_ mode: PasteMode) async {
        guard let target = copyTarget else { return }
        await copy(target, mode: mode)
    }

    /// Saves the captured selection without changing or duplicating its immutable payload.
    /// Every await is fenced by the panel session and captured selection. A clip whose content is not all there, such
    /// as a file reference that has to be found again, is not saved, and the message says why.
    func saveSelection(_ target: CopyTarget) async {
        await save(target, placing: nil)
    }

    /// ⇧⌘M: the selected clip saved straight into `collection` in one transaction, or the snippet it was saved as
    /// added to it. A snippet's card knows its collections: choosing one it is in takes it out, and any other adds it.
    /// Adding one that is in it already writes nothing.
    func saveSelection(_ target: CopyTarget, into collection: CollectionSummary) async {
        await save(target, placing: .collection(collection))
    }

    /// ⌘D: a snippet's favorite mark turns over. A clip is saved as a favorite snippet, or the snippet it was saved as
    /// becomes a favorite: the card does not know whether it is one already, so ⌘D never takes the mark away there.
    func toggleFavoriteSelection(_ target: CopyTarget) async {
        await save(target, placing: .favorite)
    }

    private enum Placement: Equatable {
        case collection(CollectionSummary)
        case favorite
    }

    private func save(_ target: CopyTarget, placing placement: Placement?) async {
        guard isOpen, !saving, copyTarget == target, let currentSession = session,
              let services = services(), let library = services.library else { return }
        saving = true
        defer { saving = false }
        // The save is what was done last: a refused copy's reason before it no longer answers it.
        failure = nil
        func stillAsked() -> Bool { isOpen && session === currentSession && copyTarget == target }
        // A snippet's card knows its favorite mark and its collections as the key was pressed.
        let card = selection.rows.first { $0.ref == target.ref }
        let cardIsFavorite = card?.isFavorite ?? false
        let cardCollections = Set(card?.collectionIDs ?? [])
        do {
            let identity = try await library.controller.identity()
            guard stillAsked() else { return }
            // A snippet is placed or marked as it is; only a clip is saved first.
            if target.ref.facet == .memo {
                guard let placement, let changes = services.collectionChanges else {
                    saveMessage = "Already in Snippets"
                    return
                }
                try await place([target.ref], placement, by: changes, onSnippet: true, wasFavorite: cardIsFavorite,
                                wasIn: cardCollections, identity: identity, stillAsked: stillAsked)
                return
            }
            let content = try await services.repository.read(target.ref)
            guard stillAsked() else { return }
            guard content.integrity == .complete else {
                savedUndo = nil
                canUndoSave = false
                saveMessage = "This clip can't be saved as a snippet until its content is available."
                return
            }
            var collection: CollectionSummary?
            if case .collection(let chosen)? = placement { collection = chosen }
            let favorite = placement == .favorite
            let outcome = try await library.saveAsMemo(target.ref.itemID,
                                                       collectionIDs: collection.map { [$0.id] } ?? [],
                                                       isFavorite: favorite, expecting: identity)
            guard stillAsked() else { return }
            switch outcome {
            case .created(let ref):
                let snapshot = try await library.editingSnapshot(ref)
                guard stillAsked() else { return }
                savedUndo = (target.ref, target.ref.itemID, snapshot.memoID, snapshot.memoFingerprint, identity)
                canUndoSave = true
                saveMessage = favorite ? "Saved as Snippet · Added to Favorites"
                    : collection.map { "Saved to “\($0.name)”" } ?? "Saved to Snippets"
                updateRow(ref: target.ref) {
                    $0.savedAsMemo = true
                    if favorite { $0.isFavorite = true }
                }
            case .existing(let memoRef):
                // ⌘S again lets an earlier save's undo go; placing the snippet keeps it.
                guard let placement, let changes = services.collectionChanges else {
                    savedUndo = nil
                    canUndoSave = false
                    saveMessage = "Already in Snippets"
                    return
                }
                try await place([memoRef], placement, by: changes, onSnippet: false, wasFavorite: false,
                                wasIn: [], identity: identity, stillAsked: stillAsked)
                if placement == .favorite, stillAsked() { updateRow(ref: target.ref) { $0.isFavorite = true } }
            }
        } catch {
            guard stillAsked() else { return }
            var gone = false
            if case .collection(let collection)? = placement { gone = await isGone(collection, in: services) }
            guard stillAsked() else { return }
            if gone {
                explainCollectionGone()
            } else {
                saveMessage = "This item could not be saved. Try again."
            }
        }
    }

    /// Places or marks snippets that exist already, and says what came of it: on a snippet's own card as it is, on a
    /// clip's card after "Already in Snippets". `wasIn` holds the collections the card showed the snippet in.
    private func place(_ refs: [ContentRef], _ placement: Placement, by changes: any QuickAccessCollectionChanges,
                       onSnippet: Bool, wasFavorite: Bool, wasIn: Set<CollectionID>, identity: StoreIdentity,
                       stillAsked: () -> Bool) async throws {
        let prefix = onSnippet ? "" : "Already in Snippets · "
        switch placement {
        case .collection(let collection):
            let place = "“\(collection.name)”"
            // A snippet's card knows its collections, and choosing one it is in takes it out; a clip's only adds.
            if onSnippet, wasIn.contains(collection.id) {
                _ = try await changes.removeSnippets(refs, from: collection.id, expecting: identity)
                guard stillAsked() else { return }
                for ref in refs { updateRow(ref: ref) { $0.collectionIDs.removeAll { $0 == collection.id } } }
                leftCollections[collection.id, default: []].formUnion(refs.map(HiddenFacet.init))
                // In that collection's own list its card leaves with it, as the library's row does.
                if list == .collection(collection.id) {
                    for ref in refs {
                        if let removed = selection.removeRows(of: ref) { rowsWereTakenOff(removed) }
                    }
                }
                saveMessage = "Removed from \(place)"
                return
            }
            let added = try await changes.addSnippets(refs, to: collection.id, expecting: identity)
            leftCollections[collection.id]?.subtract(refs.map(HiddenFacet.init))
            guard stillAsked() else { return }
            saveMessage = added ? "\(prefix)Added to \(place)" : "Already in \(place)"
            if onSnippet {
                let order = collections.map(\.id)
                for ref in refs {
                    updateRow(ref: ref) { row in
                        if !row.collectionIDs.contains(collection.id) {
                            row.collectionIDs = CollectionBadge.ordered(row.collectionIDs + [collection.id], by: order)
                        }
                    }
                }
            }
        case .favorite:
            // A snippet's card knows its mark and turns it over; a clip's only adds it.
            let favorite = onSnippet ? !wasFavorite : true
            try await changes.markSnippets(refs, favorite: favorite, expecting: identity)
            guard stillAsked() else { return }
            saveMessage = "\(prefix)\(favorite ? "Added to" : "Removed from") Favorites"
            if onSnippet { for ref in refs { updateRow(ref: ref) { $0.isFavorite = favorite } } }
        }
    }

    /// ⇧⌘M with no collection to choose: the toolbar says what it takes.
    func explainNoCollections() {
        failure = nil
        saveMessage = ActionMenu.noCollectionsHelp
    }

    /// A collection chosen from a menu that went while the menu was open: the toolbar says so, and the collections are
    /// read again.
    func explainCollectionGone() {
        failure = nil
        saveMessage = "This collection no longer exists."
        collectionsDidChange()
    }

    /// Whether `collection` is no longer among the collections, read again; a read that fails says nothing.
    private func isGone(_ collection: CollectionSummary, in services: QuickAccessServices) async -> Bool {
        guard let reader = services.collections, let read = try? await reader.collections() else { return false }
        return !read.contains { $0.id == collection.id }
    }

    func undoSaveSelection() async {
        guard isOpen, !saving, let savedUndo, let currentSession = session,
              let library = services()?.library else { return }
        saving = true
        defer { saving = false }
        failure = nil
        do {
            try await library.undoSaveAsMemo(
                savedUndo.itemID,
                memoID: savedUndo.memoID,
                expectedFingerprint: savedUndo.fingerprint,
                expecting: savedUndo.identity
            )
            guard isOpen, session === currentSession else { return }
            self.savedUndo = nil
            canUndoSave = false
            saveMessage = "Save undone"
            updateRow(ref: savedUndo.ref) { $0.savedAsMemo = false }
        } catch {
            guard isOpen, session === currentSession else { return }
            saveMessage = "This snippet changed and cannot be undone safely."
        }
    }

    // MARK: Recently Deleted

    /// Whether the selected row can go to Recently Deleted: there is a library to move it in, and it can be acted on.
    var canMoveToRecentlyDeleted: Bool { services()?.lifecycle != nil && selection.executableSelection != nil }

    /// The collection the list shows, while the selected row is a snippet in it.
    var listedCollectionOfSelection: CollectionSummary? { listedCollection(of: selection.selectedRow) }

    /// The collection the list shows, while `row` is a snippet in it: Remove from “Prompts” takes it out.
    func listedCollection(of row: QuickAccessRow?) -> CollectionSummary? {
        guard case .collection(let id) = list, let row, row.facet == .memo, row.collectionIDs.contains(id) else {
            return nil
        }
        return collections.first { $0.id == id }
    }

    /// ⌘⌫ and the actions menu's Move to Recently Deleted: the clip or snippet selected when asked goes to Recently
    /// Deleted, a manual deletion the library keeps recoverable for a while. Its card leaves the strip at once, so that
    /// ⌘⌫ pressed again acts on the clip that took its place, and the task returned moves it in the library, after any
    /// move still under way there. A clip's snippet stays, as does a snippet's clip: each is a facet of its own.
    ///
    /// A move the library refuses puts the card back and says so, and VoiceOver hears it. The card is selected again
    /// only while the selection is still where the move left it: a person who stepped on meanwhile keeps the clip they
    /// chose, so Return never acts on one they moved away from. A move that succeeds says so, and VoiceOver hears what
    /// went; the task gives what an undo needs. A showing closed meanwhile gets no undo: the move stands, in Recently
    /// Deleted.
    func moveToRecentlyDeleted(_ target: CopyTarget) -> Task<QuickAccessDeletion?, Never>? {
        guard isOpen, copyTarget == target, let currentSession = session,
              let lifecycle = services()?.lifecycle else { return nil }
        let title = selection.rows.first { $0.ref == target.ref }?.title ?? ""
        guard let removed = selection.removeRows(of: target.ref) else { return nil }
        let hidden = HiddenFacet(target.ref)
        hiddenFacets.insert(hidden)
        rowsWereTakenOff(removed)
        return Task {
            let moved = await lifecycle.moveToRecentlyDeleted(target.ref)
            guard let moved else {
                // A refused move takes nothing away, from this list or any other.
                hiddenFacets.remove(hidden)
                guard isOpen, session === currentSession else { return nil }
                putRowsBackInOrder(removed, reselectingWhileSelectionIs: removed.successorID)
                saveMessage = "This item could not be moved to Recently Deleted."
                announce?("“\(title)” could not be moved to Recently Deleted")
                return nil
            }
            guard isOpen, session === currentSession else { return nil }
            saveMessage = "Moved to Recently Deleted"
            announce?("Moved “\(title)” to Recently Deleted")
            return QuickAccessDeletion(moved: moved, ref: target.ref, title: title, rows: removed, lifecycle: lifecycle)
        }
    }

    /// Undo Move to Recently Deleted, as ⌘Z or the actions menu asks: what the move took comes back from Recently
    /// Deleted, to where it was in the strip while the strip lists what it listed then, or with the list read again
    /// otherwise. It is selected again only while the selection is where it was when the undo was asked for. Nothing
    /// comes back from a library other than the one it was moved in, nor into a closed showing.
    func undoMoveToRecentlyDeleted(_ deletion: QuickAccessDeletion) async -> Bool {
        guard isOpen, let currentSession = session else { return false }
        guard let lifecycle = services()?.lifecycle, lifecycle === deletion.lifecycle else {
            saveMessage = "The library changed. This item is still in Recently Deleted there."
            announce?("“\(deletion.title)” could not be recovered here")
            return false
        }
        failure = nil
        let askedFrom = selection.selectedID
        let recovered = await lifecycle.recover(deletion.moved)
        guard isOpen, session === currentSession else { return recovered }
        guard recovered else {
            saveMessage = "This item could not be recovered. It is still in Recently Deleted."
            announce?("“\(deletion.title)” could not be recovered")
            return false
        }
        hiddenFacets.remove(HiddenFacet(deletion.ref))
        putRowsBackInOrder(deletion.rows, reselectingWhileSelectionIs: askedFrom)
        saveMessage = "Recovered from Recently Deleted"
        announce?("Recovered “\(deletion.title)”")
        return true
    }

    /// The actions menu's Remove from “Prompts”, in that collection's list: the snippet selected when asked leaves the
    /// collection, keeping its others and staying in Snippets, and its card leaves the list. Nothing is deleted.
    func removeFromListedCollection(_ target: CopyTarget) async {
        guard let collection = listedCollection(of: selection.rows.first { $0.ref == target.ref }) else { return }
        await save(target, placing: .collection(collection))
    }

    /// After rows left the list: a selection that moved takes the save status and its undo along; an emptied list
    /// says why it is empty; a preview follows the selection, and closes with nothing left to select.
    private func rowsWereTakenOff(_ removed: SelectionCoordinator.RemovedRows) {
        if removed.selectedID != nil {
            failure = nil
            clearSaveStatus()
        }
        if !showsRecentClips { totalMatches = max(0, totalMatches - removed.entries.filter { !$0.row.isFrequent }.count) }
        if selection.rows.isEmpty { phase = showsRecentClips ? .noContent : emptyPhase }
        dropDetailsOfUnlistedRows()
        if isPreviewExpanded, selection.selection == nil {
            isPreviewExpanded = false
            loadPreview()
            onPreviewCollapsed?()
        } else {
            followSelection()
        }
    }

    /// Rows a move took, back where they were while the list is the one they left; false when it is another, which
    /// lists them, if they belong there, once it is read again. The one that was selected is selected again only while
    /// the selection is still `expected`.
    @discardableResult
    private func putRowsBack(_ removed: SelectionCoordinator.RemovedRows,
                             reselectingWhileSelectionIs expected: QuickAccessRow.ID?) -> Bool {
        let selected = selection.selectedID
        guard selection.restore(removed, reselectingWhileSelectionIs: expected) else { return false }
        if !showsRecentClips { totalMatches += removed.entries.filter { !$0.row.isFrequent }.count }
        if !selection.rows.isEmpty, phase == .noContent || phase == .noResults { phase = .results }
        if selection.selectedID != selected {
            failure = nil
            clearSaveStatus()
        }
        followSelection()
        return true
    }

    /// The list read again, for a clip that came back to a list read without it: the recent clips without moving the
    /// selection, any other list from its start.
    private func relist() {
        if showsRecentClips { recentClipsChanged() } else { reload() }
    }

    /// Rows put back where they were, and then, for the recent clips, read again from the store: a place remembered
    /// can be out of date by then, after other moves or a refresh, and the store holds their order.
    private func putRowsBackInOrder(_ removed: SelectionCoordinator.RemovedRows,
                                    reselectingWhileSelectionIs expected: QuickAccessRow.ID?) {
        guard putRowsBack(removed, reselectingWhileSelectionIs: expected) else { return relist() }
        if showsRecentClips { recentClipsChanged() }
    }

    func loadMoreIfNeeded(visibleRow index: Int) {
        guard hasMoreRows, loadingMore == nil, phase == .results, index >= selection.rows.count - 10,
              let search = services()?.search, let generation = currentGeneration else { return }
        // The search's own rows follow the frequent wing, which is no page of it.
        let request = searchRequest(generation: generation, offset: selection.rows.count - selection.frequentCount)
        loadingMore = Task {
            defer { if self.currentGeneration == generation { self.loadingMore = nil } }
            do {
                for try await page in search.search(request) where page.isComplete {
                    guard self.isCurrent(generation) else { return }
                    let listed = self.selection.rows.count
                    let order = self.collections.map(\.id)
                    self.selection.append(self.listable(page.results.map { Self.row(from: $0, order: order) }),
                                          generation: generation)
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
            directPasteAwaitsReopen = directPaste == .copy(.notPermitted) && paste.accessState() == .awaitsReopen
        } else {
            session = nil
            pasteTarget = nil
            directPaste = nil
            directPasteAwaitsReopen = false
        }
        readFrequentWing()
        readCollections()
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
        clearSaveStatus()
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
            let request = searchRequest(generation: generation, offset: 0)
            loading = Task { await loadSearch(services.search, request) }
        }
    }

    /// The search for the list: `.all` searches every clip and memo; the memo lists search memos, within a collection
    /// or among the favorites when asked, listed by their last use.
    private func searchRequest(generation: UInt64, offset: Int) -> SearchRequest {
        var request = SearchRequest(query: query, kinds: kinds, generation: generation, offset: offset,
                                    limit: Self.pageSize)
        switch list {
        case .all:
            break
        case .snippets:
            request.scope = .memo
            request.order = .lastUsed
        case .collection(let id):
            request.scope = .memo
            request.collection = .collection(id)
            request.order = .lastUsed
        }
        request.favoritesOnly = favoritesOnly
        return request
    }

    /// Whether only the index can tell the list: a collection, or the favorites. Clips, and memos browsed bare,
    /// can be read from the store.
    private var listNeedsTheIndex: Bool {
        switch list {
        case .all: false
        case .snippets: favoritesOnly
        case .collection: true
        }
    }

    /// Whether the list can be read from the store while the index cannot serve it: memos browsed bare.
    private var listReadsFromTheStore: Bool {
        list == .snippets && !favoritesOnly && ParsedQuery(query).isEmpty && kinds.isEmpty
    }

    /// What an empty page means: under `.all`, or with a query or a type filter, nothing matched; a memo list
    /// browsed bare is empty because there is nothing in it yet.
    private var emptyPhase: QuickAccessPhase {
        list != .all && ParsedQuery(query).isEmpty && kinds.isEmpty ? .noContent : .noResults
    }

    private func loadRecent(_ repository: ContentRepository, generation: UInt64, isRefresh: Bool) async {
        // The wing's candidates come before the clips are read, and nothing waits between a read and its page: an
        // opening's first page and a refresh started while it waits then apply in the order they read the clips, so
        // the later read, which has the newer clips, applies last.
        let candidates = await frequentCandidates()
        let summaries = try? await repository.recent(limit: Self.recentLimit)
        guard isCurrent(generation) else { return }
        // A refresh that fails keeps the clips already listed.
        if summaries == nil, isRefresh { return }
        let rows = ledByFrequentWing(listable((summaries ?? []).compactMap { Self.row(from: $0) }),
                                     candidates: candidates)
        applyRows(rows, generation: generation, isComplete: true)
        phase = summaries == nil ? .libraryUnavailable : (rows.isEmpty ? .noContent : .results)
        announceListIfNeeded()
    }

    private func loadSearch(_ search: (any QuickAccessSearch)?, _ request: SearchRequest) async {
        let generation = request.generation
        guard let search else {
            if isCurrent(generation) { await showListWithoutTheIndex(generation, notice: .searchUnavailable) }
            return
        }
        let candidates = await frequentCandidates()
        do {
            for try await page in search.search(request) {
                guard isCurrent(generation) else { return }
                if let notice = Self.notice(for: page.indexState), listReadsFromTheStore || listNeedsTheIndex {
                    await showListWithoutTheIndex(generation, notice: notice)
                    return
                }
                let order = collections.map(\.id)
                let found = page.results.map { Self.row(from: $0, order: order) }
                let listed = listable(found)
                let rows = ledByFrequentWing(listed, candidates: candidates)
                applyRows(rows, generation: generation, isComplete: page.isComplete, keepsChosenRow: true)
                // What an index that has not caught up still finds is no match any more.
                totalMatches = max(0, page.totalMatches - (found.count - listed.count))
                indexNotice = Self.notice(for: page.indexState)
                phase = !rows.isEmpty ? .results : (page.isComplete ? emptyPhase : .loading)
                if page.isComplete { announceListIfNeeded() }
            }
        } catch {
            guard isCurrent(generation) else { return }
            await showListWithoutTheIndex(generation, notice: .searchUnavailable)
        }
    }

    /// Lists what can be listed without the index: memos from the store for Snippets browsed bare, and otherwise
    /// nothing, with the notice saying why.
    private func showListWithoutTheIndex(_ generation: UInt64, notice: IndexNotice) async {
        if listReadsFromTheStore, let repository = services()?.repository {
            let summaries = try? await repository.recent(limit: Self.recentLimit)
            guard isCurrent(generation) else { return }
            if let summaries {
                let rows = listable(summaries.compactMap(Self.memoRow(from:)))
                applyRows(rows, generation: generation, isComplete: true)
                totalMatches = rows.count
                indexNotice = notice
                phase = rows.isEmpty ? .noContent : .results
                announceListIfNeeded()
                return
            }
        }
        applyRows([], generation: generation, isComplete: true)
        indexNotice = notice
        phase = .noResults
        announceListIfNeeded()
    }

    /// "Snippets, 4 items": the list a change of list shows, and how many it holds, once its first page is in. The
    /// recent clips count without the frequent wing, which repeats some of them.
    private func announceListIfNeeded() {
        guard announcesList, isOpen, phase != .loading else { return }
        announcesList = false
        let name: String
        switch list {
        case .all: name = "All"
        case .snippets: name = "Snippets"
        case .collection: name = collectionName ?? "Collection"
        }
        let count = showsRecentClips ? selection.rows.count - selection.frequentCount : totalMatches
        let items = switch count {
        case 0: "no items"
        case 1: "1 item"
        default: "\(count) items"
        }
        announce?("\(name), \(items)")
    }

    /// The session's frequent candidates, once its one read of them is done, for a list that has a frequent wing. A
    /// list loads them before its rows, so that the two show together and the film does not jump. nil, without
    /// waiting, when the list has no wing: a query with words lists its results alone, and a session without a first
    /// screen or without usage reads none.
    private func frequentCandidates() async -> [QuickAccessRow?]? {
        guard let read = frequentRead, list == .all, ParsedQuery(query).isEmpty else { return nil }
        return await read.value
    }

    /// `rows` led by the frequent wing drawn from `candidates`. Without a filter the wing lists those of the first
    /// `frequentLimit` candidates that can show, and leaves a rank that cannot show empty; with one, the first
    /// `frequentLimit` of every candidate that match it. Either way it leaves out the clips among the first of `rows`
    /// that the band shows whole as it opens beside the wing. It lists them from the least used to the most used, which
    /// stands beside the newest clip. There is no wing without candidates, nor over no rows.
    private func ledByFrequentWing(_ rows: [QuickAccessRow], candidates: [QuickAccessRow?]?) -> [QuickAccessRow] {
        guard let candidates, let shownWhole = frequentWingFirstScreen, !rows.isEmpty else { return rows }
        let pool = kinds.isEmpty ? Array(candidates.prefix(Self.frequentLimit)) : candidates
        let ranked = pool.compactMap { $0 }.filter { isListable($0) && (kinds.isEmpty || kinds.contains($0.kind)) }
            .prefix(Self.frequentLimit)
        // How many of the newest clips the band shows whole depends on the wing before them: a wing that reaches the
        // middle puts the newest clip there, and a shorter one leaves it further left, with more of them whole. So the
        // wing is first taken without as many as the band shows beside every ranked clip, the fewest, and taken again
        // without as many as its own length leaves whole while those are more. A wing that shrinks never shows fewer,
        // so this ends, within a round for each length the wing can have.
        var firstScreen = -1
        var wing: [QuickAccessRow] = []
        var shown = max(0, shownWhole(ranked.count))
        while shown > firstScreen {
            firstScreen = shown
            let firstScreenClips = Set(rows.prefix(firstScreen).map(\.ref))
            wing = ranked.filter { !firstScreenClips.contains($0.ref) }
            shown = max(0, shownWhole(wing.count))
        }
        return wing.reversed() + rows
    }

    /// Lists a page of rows. Every page goes through here, so that what the panel shows for a row stays with the
    /// selection whatever the page did to it: details of clips no longer listed go, and so does a review or a preview
    /// of a row that is no longer selected.
    private func applyRows(_ rows: [QuickAccessRow], generation: UInt64, isComplete: Bool,
                           keepsChosenRow: Bool = false) {
        let selected = selection.selectedID
        selection.apply(listable(rows), generation: generation, isComplete: isComplete, keepsChosenRow: keepsChosenRow)
        // A page that moves the selection to another row, or loses it, as a refresh without the clip does, takes the
        // save of the row that was selected along.
        if selection.selectedID != selected { clearSaveStatus() }
        dropDetailsOfUnlistedRows()
        followSelection()
    }

    /// `rows` without those moved to Recently Deleted from this showing, nor, in a collection's list, the snippets taken
    /// out of it.
    private func listable(_ rows: [QuickAccessRow]) -> [QuickAccessRow] {
        hiddenFacets.isEmpty && leftCollections.isEmpty ? rows : rows.filter(isListable)
    }

    private func isListable(_ row: QuickAccessRow) -> Bool {
        let facet = HiddenFacet(row.ref)
        if hiddenFacets.contains(facet) { return false }
        guard case .collection(let id) = list else { return true }
        return leftCollections[id]?.contains(facet) != true
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
        clearSaveStatus()
        followSelection()
    }

    /// A save's message and its undo belong to the clip selected when it was saved. Once another clip, query or filter
    /// takes its place, Undo Save as Snippet would remove a snippet the user is no longer looking at, so both go.
    private func clearSaveStatus() {
        saveMessage = nil
        savedUndo = nil
        canUndoSave = false
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

    /// Keeps what the panel shows for a row on the selected row. A command review of another clip, or of a clip that
    /// is gone, is dropped; a clip listed in both wings keeps its review from one copy to the other, since both hold
    /// the same content. An open preview never shows another clip's content, and it collapses when the selected row is
    /// gone.
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
        previewGeneration &+= 1
        let generation = previewGeneration
        previewing?.cancel()
        previewing = nil
        readSavedText()
        loadingOriginalPreview?.cancel()
        loadingOriginalPreview = nil
        isLoadingOriginalPreview = false
        previewMessage = nil
        preview = nil
        previewedRef = nil
        guard isPreviewExpanded, let ref = selection.selection, let repository = services()?.repository else { return }
        previewedRef = ref
        let row = selection.rows.first { $0.ref == ref }
        let kind = row?.kind ?? .other
        let previewService = services()?.preview
        // A store-backed preview service handles every supported type. The fallback
        // preserves text preview for lightweight test sessions without one.
        guard kind == .text || kind == .url || previewService != nil else {
            preview = .info(kind: kind, sourceApp: row?.sourceApp)
            return
        }
        previewing = Task {
            let content: PreviewContent
            do {
                if let previewService {
                    let loaded = try await previewService.preview(
                        for: ref,
                        kind: kind,
                        maximumImagePixels: Self.previewImagePixels
                    )
                    if case .info(let loadedKind, nil) = loaded {
                        content = .info(kind: loadedKind, sourceApp: row?.sourceApp)
                    } else {
                        content = loaded
                    }
                } else {
                    let resolved = try await repository.read(ref)
                    content = await Task.detached(priority: .userInitiated) { Self.preview(of: resolved, row: row) }.value
                }
            } catch {
                content = .failed(.contentUnavailable)
            }
            guard !Task.isCancelled,
                  self.previewedRef == ref,
                  self.previewGeneration == generation,
                  self.isPreviewExpanded else { return }
            self.preview = content
        }
    }

    private func cancelLoads() {
        previewGeneration &+= 1
        readingSavedText?.cancel()
        readingSavedText = nil
        loading?.cancel()
        loading = nil
        refreshing?.cancel()
        refreshing = nil
        loadingMore?.cancel()
        loadingMore = nil
        previewing?.cancel()
        previewing = nil
        loadingOriginalPreview?.cancel()
        loadingOriginalPreview = nil
        isLoadingOriginalPreview = false
        previewMessage = nil
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

    /// `order` is the collections' order in the sidebar, which a snippet's own collections are put in.
    private static func row(from result: SearchResult, order: [CollectionID]) -> QuickAccessRow {
        QuickAccessRow(ref: result.ref, title: result.title, snippet: result.snippet, kind: result.kind,
                       sourceApp: result.sourceApp, date: result.lastCopiedAt, savedAsMemo: result.savedAsMemo,
                       isPartiallyIndexed: result.isPartiallyIndexed, isTextUnavailable: result.isTextUnavailable,
                       collectionIDs: CollectionBadge.ordered(result.collectionIDs, by: order),
                       isFavorite: result.isFavorite)
    }

    /// A memo's row from the store, for when the index cannot serve Snippets; its collection and favorite are not
    /// known there.
    private static func memoRow(from summary: ItemSummary) -> QuickAccessRow? {
        guard let memo = summary.memo else { return nil }
        return QuickAccessRow(ref: memo, title: summary.title, snippet: nil, kind: summary.kind,
                              sourceApp: summary.sourceApp, date: summary.lastCopiedAt,
                              savedAsMemo: false, isPartiallyIndexed: false, isTextUnavailable: false)
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
    static func empty(phase: QuickAccessPhase, notice: IndexNotice?, list: QuickAccessList = .all,
                      favoritesOnly: Bool = false, collectionName: String? = nil) -> Message {
        let place = list == .snippets ? "Snippets" : (collectionName ?? "this collection")
        switch phase {
        case .noContent:
            switch list {
            case .all:
                return Message(text: "No clips yet. Copy something and it shows up here.", detail: nil)
            case .snippets:
                return Message(text: favoritesOnly ? "No favorites yet. Mark a snippet with ⌘D."
                                                   : "No snippets yet. Save a clip with ⌘S.", detail: nil)
            case .collection:
                return Message(text: favoritesOnly ? "No favorites in \(place) yet."
                                                   : "Nothing in \(place) yet. Switch to All (⌘[), pick a clip and press ⇧⌘M.",
                               detail: nil)
            }
        case .libraryUnavailable:
            return Message(text: "Library unavailable", detail: "Recent clips appear here once the library opens.")
        case .noResults:
            if list == .all {
                if notice == .searchUnavailable { return Message(text: "Search is unavailable — recent clips are still here", detail: nil) }
                return Message(text: "No results", detail: notice == .rebuilding ? rebuilding : nil)
            }
            // A collection or the favorites can be told only by the index; Snippets can be searched while it rebuilds.
            let onlyTheIndexTells = favoritesOnly || list != .snippets
            if onlyTheIndexTells, notice == .rebuilding {
                return Message(text: favoritesOnly ? "Index is rebuilding — favorites are unavailable for a moment."
                                                   : "Index is rebuilding — this list is unavailable for a moment.", detail: nil)
            }
            if notice == .searchUnavailable {
                return Message(text: favoritesOnly ? "Search is unavailable — favorites need the index."
                                                   : "Search is unavailable — this list needs the index.", detail: nil)
            }
            return Message(text: "No results in \(place)",
                           detail: notice == .rebuilding ? rebuilding : "Switch to All to search everything.")
        default:
            return Message(text: "Searching…", detail: nil)
        }
    }

    /// What the toolbar says over rows that are on screen, in place of Return's hint. An index that is rebuilding
    /// takes no such place: the toolbar says so after the filters.
    static func line(selectionLost: Bool, phase: QuickAccessPhase, isComplete: Bool) -> String? {
        if selectionLost { return "The selected item is no longer in the results" }
        if phase == .loading || !isComplete { return "Searching…" }
        return nil
    }
}
