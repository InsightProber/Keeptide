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
    /// The text recognized in an image.
    case text
    /// A translation of a clip's text.
    case translation
}

/// What the text column shows for the selected image.
enum TextColumn: Equatable {
    /// What was made before is still being read.
    case loading
    /// Nothing has been made of the image's text yet: the column offers to extract it.
    case notStarted
    /// Recognition is waiting or under way.
    case recognizing(GenerationSnapshot)
    /// The image's text, made now or kept from before, line by line or in paragraphs as `keepsLineBreaks` says.
    case text(String, keepsLineBreaks: Bool, status: DerivedTextStatus)
    /// The text was made, but the library couldn't keep it.
    case unsaved(String, keepsLineBreaks: Bool)
    /// The image has no text.
    case noText
    case failed(GenerationError)
    /// Recognizing the image again failed and left what the column had: text, text the library couldn't keep, or that
    /// there was none. The column says so, and why.
    indirect case failedAgain(TextColumn, GenerationError)
}

extension TextColumn {
    /// How the text shown is laid out; nil without text.
    var keepsLineBreaks: Bool? {
        switch self {
        case .text(_, let keeps, _), .unsaved(_, let keeps): keeps
        case .failedAgain(let kept, _): kept.keepsLineBreaks
        case .loading, .notStarted, .recognizing, .noText, .failed: nil
        }
    }

    /// The whole text shown, made now or kept from before, whether or not the library could keep it. Nil for part of a
    /// text, as a stopped or cut-off one is, and without text.
    var wholeText: String? {
        switch self {
        case .text(let text, _, .complete), .unsaved(let text, _): text
        case .failedAgain(let kept, _): kept.wholeText
        case .text, .loading, .notStarted, .recognizing, .noText, .failed: nil
        }
    }
}

/// What the translation column shows for the selected clip.
enum TranslationColumn: Equatable {
    /// What was made before is still being read.
    case loading
    /// Nothing was translated yet: the column offers to translate.
    case notStarted
    /// Translation is waiting or under way, into the language with this code.
    case translating(GenerationSnapshot, into: String?)
    /// The translation, made now or kept from before, into the language with this code: whole, or as far as it got
    /// before it was stopped or cut off.
    case translation(String, into: String?, status: DerivedTextStatus)
    /// The text was translated, whole or as far as it got, but the library couldn't keep it.
    case unsaved(String, into: String?, status: DerivedTextStatus)
    /// There was nothing in the text to translate into the language with this code.
    case nothingToTranslate(into: String?)
    /// The text in an image is recognized first, to be translated into the language with this code: under way, or
    /// waiting its turn.
    case recognizingText(into: String?, hasStarted: Bool)
    /// A recognition found no text in the image to translate into the language with this code.
    case noTextInImage(into: String?)
    /// Nothing was made, and why, with the language it was asked for.
    case failed(GenerationError, asked: String?)
    /// Translating again came to nothing and left what the column had: why, and the language it was asked for.
    indirect case failedAgain(TranslationColumn, GenerationError, asked: String?)
}

extension TranslationColumn {
    /// The language the translation shown is in, or is being made in, by its code; nil without one.
    var language: String? {
        switch self {
        case .translating(_, let into), .translation(_, let into, _), .unsaved(_, let into, _),
             .nothingToTranslate(let into), .recognizingText(let into, _), .noTextInImage(let into),
             .failed(_, let into): into
        case .failedAgain(let kept, _, _): kept.language
        case .loading, .notStarted: nil
        }
    }

    /// The whole translation shown, made now or kept from before, whether or not the library could keep it. Nil for
    /// part of one, as a stopped one is, and without one.
    var wholeText: String? {
        switch self {
        case .translation(let text, _, .complete), .unsaved(let text, _, .complete): text
        case .failedAgain(let kept, _, _): kept.wholeText
        case .translation, .unsaved, .loading, .notStarted, .translating, .nothingToTranslate, .recognizingText,
             .noTextInImage, .failed: nil
        }
    }

    /// Translation is waiting or under way, the text in an image being recognized first included: it can be stopped.
    var isTranslating: Bool {
        switch self {
        case .translating, .recognizingText: true
        case .loading, .notStarted, .translation, .unsaved, .nothingToTranslate, .noTextInImage, .failed, .failedAgain:
            false
        }
    }

    /// The text in an image is recognized before it is translated, or waits its turn to be.
    var isRecognizingText: Bool {
        if case .recognizingText = self { return true }
        return false
    }

    /// The text in an image is being recognized, not waiting its turn: a line passes over the image.
    var isScanningForText: Bool {
        if case .recognizingText(_, true) = self { return true }
        return false
    }

    /// The latest translation failed, whether or not it left a translation from before: it can be tried again.
    var isFailed: Bool {
        switch self {
        case .failed, .failedAgain: true
        case .loading, .notStarted, .translating, .translation, .unsaved, .nothingToTranslate, .recognizingText,
             .noTextInImage: false
        }
    }

    /// The translation shown is part of one, stopped or cut off on its way.
    var isIncomplete: Bool {
        switch self {
        case .translation(_, _, let status), .unsaved(_, _, let status): status != .complete
        case .loading, .notStarted, .translating, .nothingToTranslate, .recognizingText, .noTextInImage, .failed,
             .failedAgain: false
        }
    }

    /// Whether Try Again, and ⌘T, make it again: it failed, or stopped part of the way.
    var offersTryAgain: Bool { isFailed || isIncomplete }

    /// The language a new try is to be in: the one that failed, or the one shown.
    var askedLanguage: String? {
        switch self {
        case .failed(_, let asked), .failedAgain(_, _, let asked): asked ?? language
        case .loading, .notStarted, .translating, .translation, .unsaved, .nothingToTranslate, .recognizingText,
             .noTextInImage: language
        }
    }
}

/// The languages translations are made in. `offered` is what Translation lists, a language in each of its regions, as
/// English is in two; empty until it is read, when any language may be offered.
enum TranslationTargets {
    /// The first language the person prefers that is offered, else English, in the region the person wants it in.
    static func first(of preferred: [String], offered: [Locale.Language] = []) -> Locale.Language {
        let first = preferred.map(Locale.Language.init(identifier:)).first { isOffered($0, offered) }
        return variant(of: first ?? Locale.Language(identifier: "en"), preferred: preferred, offered: offered)
    }

    /// The first such language other than `language`, else English; nil where that is `language` too.
    static func next(after language: Locale.Language, of preferred: [String],
                     offered: [Locale.Language] = []) -> Locale.Language? {
        let candidates = preferred.map(Locale.Language.init(identifier:)).filter { isOffered($0, offered) }
            + [Locale.Language(identifier: "en")]
        guard let next = candidates.first(where: { !$0.isSameLanguage(as: language) }) else { return nil }
        return variant(of: next, preferred: preferred, offered: offered)
    }

    /// The language translations are made in: the one fixed in Settings, else the one last chosen in the language
    /// menu, where Translation offers it; else the first the person prefers. Each in the region the person wants it in.
    static func target(fixed: String?, lastUsed: String?, preferred: [String],
                       offered: [Locale.Language]) -> Locale.Language {
        // Stored codes are not trusted: one that names no language is passed over, as quick access and Settings both
        // ask here.
        for chosen in [fixed, lastUsed].compactMap({ $0.flatMap(Self.code(of:)) }) {
            let language = Locale.Language(identifier: chosen)
            if isOffered(language, offered) { return variant(of: language, preferred: preferred, offered: offered) }
        }
        return first(of: preferred, offered: offered)
    }

    /// The languages to translate into as the language menu and Settings list them: the ones the person prefers that
    /// Translation offers, and English, then the others it offers, by name. Each is listed once, in the region the
    /// person wants it in.
    static func ordered(preferred: [String],
                        offered: [Locale.Language]) -> (preferred: [Locale.Language], others: [Locale.Language]) {
        var first: [Locale.Language] = []
        for language in preferred.map(Locale.Language.init(identifier:)) + [Locale.Language(identifier: "en")]
            where isOffered(language, offered) && !first.contains(where: { $0.isSameLanguage(as: language) }) {
            first.append(variant(of: language, preferred: preferred, offered: offered))
        }
        var others: [Locale.Language] = []
        for language in offered where !(first + others).contains(where: { $0.isSameLanguage(as: language) }) {
            others.append(variant(of: language, preferred: preferred, offered: offered))
        }
        others.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return (first, others)
    }

    /// Whether translations can be made in `language`, as far as is known.
    static func isOffered(_ language: Locale.Language, _ offered: [Locale.Language]) -> Bool {
        offered.isEmpty || offered.contains { $0.isSameLanguage(as: language) }
    }

    /// The region translations into `language` are made in: the one the person's own list names for that language,
    /// where Translation offers it or nothing is known of what it offers; else the language's usual region where
    /// Translation offers that, as US English is for English; else the first it offers. British English and US English
    /// are downloaded apart.
    static func variant(of language: Locale.Language, preferred: [String],
                        offered: [Locale.Language]) -> Locale.Language {
        // The language alone, so that its usual region is the language's own, not that of a region named with it.
        let language = Locale.Language(identifier: language.translationCode)
        let wanted = preferred.map(Locale.Language.init(identifier:)).filter { $0.isSameLanguage(as: language) }
        let regions = offered.filter { $0.isSameLanguage(as: language) }
        guard let first = regions.first else { return wanted.first ?? language }
        for want in wanted {
            if let match = regions.first(where: { $0.region == want.region }) { return match }
        }
        let usual = Locale.Language(identifier: language.maximalIdentifier).region
        return regions.first { $0.region == usual } ?? first
    }

    /// A language's code as the language menu and kept translations name it, without a region: "zh-Hans", "en". Nil
    /// for one that names no language, as "zz" or "123" don't.
    static func code(of identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines))
        guard language.languageCode?.isISOLanguage == true else { return nil }
        return language.translationCode
    }
}

/// The language menu: the languages translations can be made in, the ones the person prefers first.
struct TranslationLanguageMenu: Equatable {
    struct Item: Equatable {
        /// The language's code, as translations name it, without a region: "zh-Hans", "en".
        let code: String
        let name: String
        /// What translating the clip's text into it needs, where that is known and it needs anything.
        let note: Note?
        /// Whether it is the language the column shows, or else the one translations are made in.
        let isChosen: Bool

        /// What VoiceOver reads: the name, with what it needs after it, as in "Japanese, not downloaded".
        var spokenName: String { note.map { "\(name), \($0.spoken)" } ?? name }
    }

    /// What translating into a language needs, said after its name.
    enum Note: Equatable {
        /// Its languages are to be downloaded first.
        case notDownloaded
        /// This Mac can't translate between them.
        case notAvailable

        init?(_ status: TranslationPairStatus?) {
            switch status {
            case .needsDownload?: self = .notDownloaded
            case .unsupported?: self = .notAvailable
            case .installed?, nil: return nil
            }
        }

        var title: String {
            switch self {
            case .notDownloaded: "Not Downloaded"
            case .notAvailable: "Not Available on This Mac"
            }
        }

        var spoken: String {
            switch self {
            case .notDownloaded: "not downloaded"
            case .notAvailable: "not available on this Mac"
            }
        }
    }

    var preferred: [Item] = []
    var others: [Item] = []
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
    /// Whether text recognized from now on keeps the image's line breaks or joins lines into paragraphs: the person's
    /// choice, which the panel gives as it opens and keeps as Keep Line Breaks changes it.
    private(set) var keepsLineBreaks = true
    /// What earlier jobs kept for the listed clips, read with the cards' details: the text in images and the
    /// translations of texts, how whole each is and its language.
    private(set) var keptResults: [DerivedTextOperation: [ContentRef: DerivedTextSummary]] = [:]
    /// The clips the store has said what it keeps for, for each operation, in this showing: until it has, a failure
    /// that a result kept from before may outweigh says nothing.
    private(set) var keptAnswered: [DerivedTextOperation: Set<ContentRef>] = [:]
    /// The clips whose kept results of each operation have been read for, or are being read for, in this showing.
    @ObservationIgnored private var keptAsked: [DerivedTextOperation: Set<ContentRef>] = [:]
    /// The clip, and the column beside it, whose result was copied just now: the preview's bar says so for a moment,
    /// beside that result.
    private var copied: (ref: ContentRef, column: ResultColumn)?
    static let textCopiedNoteDuration: Duration = .seconds(1.5)
    @ObservationIgnored private var textCopiedNote: Task<Void, Never>?
    /// The texts saved as snippets in this showing: saving one again says it is there already.
    @ObservationIgnored private var savedTexts: Set<String> = []
    /// The image the saved text below was read for. Until it is the previewed image, the column is still reading.
    private var savedTextRef: ContentRef?
    /// What an earlier job saved of the previewed image's text, if anything.
    private var savedText: DerivedText?
    @ObservationIgnored private var readingSavedText: Task<Void, Never>?
    /// The clip the saved translation below was read for. Until it is the previewed clip, the column is still reading.
    private var savedTranslationRef: ContentRef?
    /// What an earlier job saved of the previewed clip's translation, if anything.
    private var savedTranslation: DerivedText?
    @ObservationIgnored private var readingSavedTranslation: Task<Void, Never>?
    /// The languages the person prefers, first first, as the system lists them.
    @ObservationIgnored private let preferredLanguages: () -> [String]
    /// The language last chosen from the language menu, by its code without a region: translations are made in it
    /// unless Settings fixes one. Nil until one is, and translations are made in the first language the person
    /// prefers.
    private var chosenTranslationTarget: String?
    /// The language Settings fixes translations in; nil for the last used one.
    private var fixedTranslationTarget: String?
    /// The languages translations can be made in, a language in each of its regions, as Translation last listed them:
    /// read again each time the panel opens. Empty until then; kept from one showing to the next.
    private(set) var knownTranslationLanguages: [Locale.Language] = []
    @ObservationIgnored private var readingKnownLanguages: Task<Void, Never>?
    /// What translating from a language into each language needs, by the code of the language translated from, as
    /// read in this showing: read again in the next, as a language may be downloaded or removed meanwhile.
    private var pairStatuses: [String: [TranslationLanguage]] = [:]
    @ObservationIgnored private var readingPairStatuses: [String: Task<Void, Never>] = [:]
    /// The language each clip's text was told to be in, in this showing, from the text quick access had of it: nil
    /// where it couldn't be told.
    private var textLanguages: [ContentRef: Locale.Language?] = [:]
    @ObservationIgnored private var tellingLanguage: (ref: ContentRef, task: Task<Void, Never>)?
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

    init(services: @escaping @MainActor () -> QuickAccessServices?,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.preferredLanguages = preferredLanguages
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

    /// What the panel offers for the selected row, or for the text beside it while the preview shows that.
    var actions: QuickAccessActions {
        resultColumnRef == nil ? actions(for: selection.selection)
            : textColumnRef != nil ? textActions : translationActions
    }

    /// What Return can do in this session, whatever clip is selected: the toolbar keeps room for the widest.
    var possibleActions: [QuickAccessActions] {
        ([nil] + [ContentKind.text, .url, .image, .file, .other]).map { kind in
            QuickAccessActions.make(target: pasteTarget, availability: directPaste, kind: kind,
                                    awaitsReopen: directPasteAwaitsReopen)
        } + [textActions, translationActions]
    }

    /// What Return does with text made of the selected clip, such as the text recognized in an image.
    private var textActions: QuickAccessActions {
        QuickAccessActions.make(target: pasteTarget, availability: directPaste, kind: .text,
                                awaitsReopen: directPasteAwaitsReopen, takesText: true)
    }

    /// What Return does with the translation of the selected clip.
    private var translationActions: QuickAccessActions {
        QuickAccessActions.make(target: pasteTarget, availability: directPaste, kind: .text,
                                awaitsReopen: directPasteAwaitsReopen, takesText: true, resultName: "Translation")
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
        savedTexts = []
        cancelLanguageReads()
        textLanguages = [:]
        pairStatuses = [:]
        readKnownTranslationLanguages()
        keptResults = [:]
        keptAnswered = [:]
        keptAsked = [:]
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
        cancelLanguageReads()
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
        // What another library kept says nothing of this one's.
        keptResults = [:]
        keptAnswered = [:]
        keptAsked = [:]
        cancelLanguageReads()
        textLanguages = [:]
        pairStatuses = [:]
        readKnownTranslationLanguages()
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
        let kinds = Dictionary(selection.rows.map { ($0.ref, $0.kind) }, uniquingKeysWith: { first, _ in first })
        readKeptResults(of: refs.filter { kinds[$0] == .image }, operation: .extractText)
        readKeptResults(of: refs.filter { kinds[$0].map(Self.isTranslatable) == true }, operation: .translate)
    }

    /// Reads, in one go, what earlier jobs of the operation kept for the framed clips not asked about yet, for their
    /// cards: the text in images, or the translations of texts.
    private func readKeptResults(of refs: [ContentRef], operation: DerivedTextOperation) {
        guard let derivedText = services()?.derivedText, let asking = session else { return }
        let asked = refs.filter { keptAsked[operation]?.contains($0) != true }
        guard !asked.isEmpty else { return }
        keptAsked[operation, default: []].formUnion(asked)
        Task { [weak self] in
            let kept = await derivedText.savedSummaries(of: asked, operation: operation)
            // Another showing, or another library, asks for itself.
            guard let self, isOpen, session === asking else { return }
            guard let kept else {
                // Unread, they are asked about again with the cards' next details.
                keptAsked[operation]?.subtract(asked)
                return
            }
            if !kept.isEmpty { keptResults[operation, default: [:]].merge(kept) { _, read in read } }
            keptAnswered[operation, default: []].formUnion(asked)
        }
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

    /// Whether the preview is split for the column chosen beside it: as wide as the band and above it, with an image's
    /// text beside the image. A clip that has no such column shows its preview alone in the same place, so the card
    /// stays where it is while the selection moves.
    var isPreviewSplit: Bool {
        resultColumn != nil && isPreviewExpanded && services()?.derivedText != nil
    }

    /// The image whose text the column shows: the selected clip, while the preview is split and the clip is an image.
    var textColumnRef: ContentRef? {
        guard isPreviewSplit, resultColumn == .text, let row = selection.selectedRow, row.kind == .image else {
            return nil
        }
        return row.ref
    }

    /// The clip whose translation the column shows: the selected clip, while the preview is split for translations
    /// and the clip is a text, or an image whose text is translated.
    var translationColumnRef: ContentRef? {
        guard isPreviewSplit, resultColumn == .translation, let row = selection.selectedRow,
              Self.isTranslatable(row.kind) else { return nil }
        return row.ref
    }

    /// What a card says of the text in its image: a recognition under way or waiting its turn, text made or kept,
    /// or why making it failed. Nothing for a clip that isn't an image, an image whose text was never made, or one
    /// with none in it.
    func textMark(for row: QuickAccessRow) -> StripTextMark? {
        textMarker()(row)
    }

    /// `textMark(for:)` for many rows at once, as the panel asks for every card, with the library's coordinator
    /// looked up once. A job is told apart as waiting or running by whether it started, which changes once, so the
    /// panel doesn't follow every snapshot it publishes.
    func textMarker() -> (QuickAccessRow) -> StripTextMark? {
        guard let derivedText = services()?.derivedText else { return { _ in nil } }
        // Text cut off at its length limit is text, as it is when made in this showing.
        let kept = Set((keptResults[.extractText] ?? [:]).keys)
        let answered = keptAnswered[.extractText] ?? []
        return { row in
            guard row.kind == .image else { return nil }
            let (job, outcome) = derivedText.cardState(for: row.ref, operation: .extractText)
            if let job { return job.hasStarted ? .recognizing : .waiting }
            switch outcome {
            case .saving?, .saved?, .notSaved?: return .hasText
            // A failure leaves the text kept from before, which the store is asked for first.
            case .failed(let error)?:
                if kept.contains(row.ref) { return .hasText }
                return answered.contains(row.ref) ? .failed(error.message) : nil
            case .noText?: return nil
            case nil: return kept.contains(row.ref) ? .hasText : nil
            }
        }
    }

    /// What a card says of the translation of its text, or of the text in its image: one under way or waiting its turn,
    /// waiting for the image's text to be recognized included, one made or kept from before, whole or stopped part way,
    /// or why making it failed. Nothing for a clip that can't be translated, one never translated, or one with nothing
    /// in it to translate.
    func translationMark(for row: QuickAccessRow) -> StripTranslationMark? {
        translationMarker()(row)
    }

    /// `translationMark(for:)` for many rows at once, as `textMarker()` is for the text in images.
    func translationMarker() -> (QuickAccessRow) -> StripTranslationMark? {
        guard let derivedText = services()?.derivedText else { return { _ in nil } }
        let kept = keptResults[.translate] ?? [:]
        let answered = keptAnswered[.translate] ?? []
        func made(_ status: DerivedTextStatus, into language: String?) -> StripTranslationMark {
            status == .complete ? .translated(into: language) : .stopped
        }
        return { row in
            guard Self.isTranslatable(row.kind) else { return nil }
            let (job, outcome) = derivedText.cardState(for: row.ref, operation: .translate)
            if let job {
                guard job.hasStarted else { return .waiting }
                let into = derivedText.runningRequest(for: row.ref, operation: .translate)?.targetLanguage
                return .translating(into: into)
            }
            // A translation of the text in an image waits for the text to be recognized.
            if derivedText.translationWaitingForText(row.ref) != nil { return .waiting }
            let before = kept[row.ref].map { made($0.status, into: $0.targetLanguage) }
            switch outcome {
            case .saving(_, let request, let status)?, .notSaved(_, let request, let status)?:
                return made(status, into: request.targetLanguage)
            case .saved(let result)?: return made(result.status, into: result.targetLanguage)
            // A failure leaves the translation kept from before, which the store is asked for first.
            case .failed(let error)?:
                guard answered.contains(row.ref) else { return nil }
                return before ?? .failed(error.message)
            case .noText?: return nil
            case nil: return before
            }
        }
    }

    /// Whether the selected clip is an image whose text the preview can show beside it.
    var offersTextInImage: Bool {
        selection.selectedRow?.kind == .image && canRecognizeText
    }

    /// Whether the text in images can be recognized and shown here: the library is open.
    var canRecognizeText: Bool { services()?.derivedText != nil }

    /// What the text column shows, while it shows: a job under way, then how the latest job ended, and otherwise what
    /// an earlier one saved.
    var textColumn: TextColumn? { textColumnContents?.column }

    /// The whole result the text column shows, as it was saved: what Return takes.
    var textColumnResult: DerivedText? {
        guard let result = textColumnContents?.result, result.status == .complete else { return nil }
        return result
    }

    /// What the text column shows, and the saved result behind it when that is what it shows. A recognition that
    /// failed leaves what was made before, in this session or an earlier one, and says so while it is the latest
    /// recognition's ending.
    private var textColumnContents: (column: TextColumn, result: DerivedText?)? {
        guard let ref = textColumnRef, let derivedText = services()?.derivedText else { return nil }
        if let job = derivedText.job(for: ref, operation: .extractText) { return (.recognizing(job.snapshot), nil) }
        let made: (column: TextColumn, result: DerivedText?)
        switch derivedText.outcome(for: ref, operation: .extractText) {
        // Recognition on this Mac ends whole or not at all, so the text being saved is whole.
        case .saving(let text, let request, _)?:
            made = (.text(text, keepsLineBreaks: request.keepsLineBreaks, status: .complete), nil)
        case .saved(let result)?: made = (Self.column(showing: result), result)
        case .noText?: made = (.noText, nil)
        case .notSaved(let text, let request, _)?:
            made = (.unsaved(text, keepsLineBreaks: request.keepsLineBreaks), nil)
        case .failed(let error)?:
            guard savedTextRef == ref else { return (.loading, nil) }
            guard let savedText else {
                // Tried again once the store has said it kept none.
                return (derivedText.isWaitingToStart(ref, operation: .extractText) ? .loading : .failed(error), nil)
            }
            let kept = Self.column(showing: savedText)
            let isLatest = derivedText.showsLatestEnding(for: ref, operation: .extractText)
            return (isLatest ? .failedAgain(kept, error) : kept, savedText)
        case nil:
            guard savedTextRef == ref else { return (.loading, nil) }
            if let savedText { return (Self.column(showing: savedText), savedText) }
            // Text the person asked for starts once the store has said it kept none.
            return (derivedText.isWaitingToStart(ref, operation: .extractText) ? .loading : .notStarted, nil)
        }
        guard let failure = derivedText.failure(for: ref, operation: .extractText) else { return made }
        return (.failedAgain(made.column, failure), made.result)
    }

    private static func column(showing result: DerivedText) -> TextColumn {
        .text(result.text, keepsLineBreaks: result.keepsLineBreaks, status: result.status)
    }

    /// Whether the column shows how the latest recognition of its image just ended: the text it made, that it found
    /// none, or why it failed, rather than text kept from before or brought back by stopping a recognition.
    var isTextColumnJustMade: Bool { textColumnEnding != nil }

    /// The latest recognition's ending that the column shows, which tells one ending from another so that each is
    /// said once; nil while the column shows something else.
    var textColumnEnding: UUID? {
        guard let ref = textColumnRef, let derivedText = services()?.derivedText else { return nil }
        return derivedText.latestEnding(for: ref, operation: .extractText)
    }

    /// Opens the preview with the text in the selected image beside it, and recognizes the text unless something was
    /// made of it already; a failure is tried again. Asked for while the column says a recognition failed, it tries
    /// again. The recognition starts whatever the selection does next. Nothing happens for a clip that isn't an image.
    func showTextInImage() {
        guard let row = selection.selectedRow, row.kind == .image, let derivedText = services()?.derivedText else {
            return
        }
        if textColumnRef == row.ref, textColumn?.isFailed == true {
            extractText()
            return
        }
        resultColumn = .text
        if !isPreviewExpanded {
            isPreviewExpanded = true
            loadPreview()
        }
        derivedText.extractTextUnlessMade(from: row.ref, keepingLineBreaks: keepsLineBreaks)
    }

    func closeResultColumn() {
        resultColumn = nil
    }

    /// Recognizes the text in the image the column shows, again if it was made before.
    func extractText() {
        guard let ref = textColumnRef else { return }
        services()?.derivedText?.extractText(from: ref, keepingLineBreaks: keepsLineBreaks)
    }

    /// Whether there is a recognition to stop in the column: one under way or waiting its turn, or one asked for that
    /// waits on what the store kept.
    var canStopTextRecognition: Bool {
        guard let ref = textColumnRef, let derivedText = services()?.derivedText else { return false }
        return textColumn?.isRecognizing == true || derivedText.isWaitingToStart(ref, operation: .extractText)
    }

    func stopTextRecognition() {
        guard let ref = textColumnRef else { return }
        services()?.derivedText?.stop(ref, operation: .extractText)
    }

    // MARK: Translation

    /// Whether the selected clip is a text, or an image, whose translation the preview can show beside it.
    var offersTranslation: Bool {
        guard let kind = selection.selectedRow?.kind else { return false }
        return Self.isTranslatable(kind) && services()?.derivedText != nil
    }

    /// Whether a clip of this kind can be translated: a text, or the text in an image.
    static func isTranslatable(_ kind: ContentKind) -> Bool { kind == .text || kind == .image }

    /// The language translations are made in: the one fixed in Settings, else the one last chosen from the language
    /// menu, while Translation offers it, or else the first the person prefers that it offers, each in the region the
    /// person wants it in.
    var translationTarget: Locale.Language {
        TranslationTargets.target(fixed: fixedTranslationTarget, lastUsed: chosenTranslationTarget,
                                  preferred: preferredLanguages(), offered: knownTranslationLanguages)
    }

    /// The language to offer where the text is in the one asked for already; nil without another.
    func translationTarget(after language: Locale.Language) -> Locale.Language? {
        TranslationTargets.next(after: language, of: preferredLanguages(), offered: knownTranslationLanguages)
    }

    /// The language menu for the selected clip.
    var translationLanguageMenu: TranslationLanguageMenu {
        translationLanguageMenu(for: selection.selectedRow?.ref)
    }

    /// The language menu for a clip: the languages the person prefers that translations can be made in, then English,
    /// then the others by name, each once whatever its regions, in the region translations into it are made in. Once
    /// the clip's text was told to be in a language in this showing, each is marked for what translating from that
    /// language into it needs. Until Translation's languages are read, the person's own and English. The language the
    /// clip's column shows, or else the one translations are made in, is chosen.
    func translationLanguageMenu(for ref: ContentRef?) -> TranslationLanguageMenu {
        let shown = ref != nil && ref == translationColumnRef ? translationColumn?.language : nil
        let chosen = shown.map(Locale.Language.init(identifier:)) ?? translationTarget
        let offered = knownTranslationLanguages
        let preferredLanguages = preferredLanguages()
        // The marks are for this clip's own language, never another clip's.
        var statuses: [TranslationLanguage] = []
        if let ref, let entry = textLanguages[ref], let told = entry {
            statuses = pairStatuses[told.translationCode] ?? []
        }
        let (preferred, others) = TranslationTargets.ordered(preferred: preferredLanguages, offered: offered)
        func item(_ language: Locale.Language) -> TranslationLanguageMenu.Item {
            let status = statuses.first {
                $0.language.isSameLanguage(as: language) && $0.language.region == language.region
            }?.status
            return TranslationLanguageMenu.Item(code: language.translationCode, name: language.displayName,
                                                note: TranslationLanguageMenu.Note(status),
                                                isChosen: language.isSameLanguage(as: chosen))
        }
        return TranslationLanguageMenu(preferred: preferred.map(item), others: others.map(item))
    }

    /// Tells the selected clip's language from the text quick access has of it, unless that was done in this showing,
    /// and reads what translating from that language needs, unless that was read: what the language menu marks.
    /// Without text at hand, as before a text's preview is read or while an image's text is unknown, it does nothing
    /// yet; the panel asks again as it updates.
    func readTranslationLanguages() {
        guard let row = selection.selectedRow, Self.isTranslatable(row.kind),
              let derivedText = services()?.derivedText else { return }
        let ref = row.ref
        if let entry = textLanguages[ref] {
            if let told = entry { readPairStatuses(from: told, derivedText) }
            return
        }
        guard tellingLanguage?.ref != ref, let text = textAtHand(for: row, derivedText) else { return }
        tellingLanguage?.task.cancel()
        tellingLanguage = (ref, Task { [weak self] in
            let language = await derivedText.language(of: text)
            guard !Task.isCancelled, let self else { return }
            tellingLanguage = nil
            textLanguages.updateValue(language, forKey: ref)
            if let language { readPairStatuses(from: language, derivedText) }
        })
    }

    /// Reads what translating from `source` into each language needs, unless that was read in this showing or is
    /// being read.
    private func readPairStatuses(from source: Locale.Language, _ derivedText: DerivedTextCoordinator) {
        let code = source.translationCode
        guard pairStatuses[code] == nil, readingPairStatuses[code] == nil else { return }
        readingPairStatuses[code] = Task { [weak self] in
            let languages = await derivedText.translationLanguages(from: source)
            guard !Task.isCancelled, let self else { return }
            readingPairStatuses[code] = nil
            pairStatuses[code] = languages
            if knownTranslationLanguages.isEmpty { knownTranslationLanguages = languages.map(\.language) }
        }
    }

    /// The text a clip's language is told from, as quick access already has it: a text's preview, or an image's text,
    /// recognized in this session or kept from before. Nil until it is at hand: a clip is never read again for it.
    private func textAtHand(for row: QuickAccessRow, _ derivedText: DerivedTextCoordinator) -> String? {
        if row.kind == .image {
            if let recognized = derivedText.recognizedText(in: row.ref) { return recognized }
            return savedTextRef == row.ref ? savedText?.text : nil
        }
        guard previewedRef == row.ref, case .text(let text, _) = TranslationOriginal(preview) else { return nil }
        return text
    }

    /// Reads the languages Translation lists, as the panel opens. Those read before stand until then, and where it
    /// lists none.
    private func readKnownTranslationLanguages() {
        readingKnownLanguages?.cancel()
        guard let derivedText = services()?.derivedText else { return }
        readingKnownLanguages = Task { [weak self] in
            let languages = await derivedText.translationLanguages(from: nil).map(\.language)
            guard !Task.isCancelled, let self, !languages.isEmpty else { return }
            knownTranslationLanguages = languages
        }
    }

    /// Stops telling languages and reading what they need: the panel closed or opened again, or its library changed.
    private func cancelLanguageReads() {
        readingKnownLanguages?.cancel()
        readingKnownLanguages = nil
        tellingLanguage?.task.cancel()
        tellingLanguage = nil
        readingPairStatuses.values.forEach { $0.cancel() }
        readingPairStatuses = [:]
    }

    /// Chooses a language from the language menu, by its code: the last used one, which translations are made in
    /// unless Settings fixes one. The selected clip's translation shows beside it, made in that language, in the
    /// region the person wants it in, unless the column shows a whole one in it or one is being made in it. Returns
    /// the code, without a region, for the panel to keep; a code that names no language chooses nothing and returns
    /// nil.
    @discardableResult
    func chooseTranslationLanguage(_ code: String) -> String? {
        guard let code = TranslationTargets.code(of: code) else { return nil }
        chosenTranslationTarget = code
        let language = TranslationTargets.variant(of: Locale.Language(identifier: code), preferred: preferredLanguages(),
                                                  offered: knownTranslationLanguages)
        guard let row = selection.selectedRow, Self.isTranslatable(row.kind),
              let derivedText = services()?.derivedText else { return code }
        resultColumn = .translation
        if !isPreviewExpanded {
            isPreviewExpanded = true
            loadPreview()
        }
        readTranslationLanguages()
        if let column = translationColumn, column.isTranslating || column.wholeText != nil,
           column.language.map(Locale.Language.init(identifier:))?.isSameLanguage(as: language) == true {
            return code
        }
        if row.kind == .image {
            derivedText.translateText(inImage: row.ref, to: language, keepingLineBreaks: keepsLineBreaks)
        } else {
            derivedText.translate(row.ref, to: language)
        }
        return code
    }

    /// The person's choice of language, as the panel opens: the one fixed in Settings, else the one last chosen in
    /// the language menu. Without either, or with codes that name no language, translations are made in the first
    /// language the person prefers. It changes nothing shown.
    func restoreTranslationTarget(_ code: String?, fixed: String?) {
        chosenTranslationTarget = code.flatMap(TranslationTargets.code(of:))
        fixedTranslationTarget = fixed.flatMap(TranslationTargets.code(of:))
    }

    /// What the translation column shows, while it shows: a job under way, then how the latest job ended, and
    /// otherwise what an earlier one saved.
    var translationColumn: TranslationColumn? { translationColumnContents?.column }

    /// The whole translation the column shows, as it was saved: what Return takes.
    var translationColumnResult: DerivedText? {
        guard let result = translationColumnContents?.result, result.status == .complete else { return nil }
        return result
    }

    /// The text the translation is of, as the preview shows it, for the column beside the translation. An image's text
    /// is translated beside the image itself, while its preview loads too.
    var translationOriginal: TranslationOriginal {
        selection.selectedRow?.kind == .image ? .image : TranslationOriginal(preview)
    }

    /// What the translation column shows, and the saved result behind it when that is what it shows. A translation
    /// that failed leaves what was made before, in this session or an earlier one, and says so while it is the latest
    /// translation's ending.
    private var translationColumnContents: (column: TranslationColumn, result: DerivedText?)? {
        guard let ref = translationColumnRef, let derivedText = services()?.derivedText else { return nil }
        if let job = derivedText.job(for: ref, operation: .translate) {
            let into = derivedText.runningRequest(for: ref, operation: .translate)?.targetLanguage
            return (.translating(job.snapshot, into: into), nil)
        }
        // The text in an image is recognized first, as soon as this Mac's lane has room.
        if let target = derivedText.translationWaitingForText(ref) {
            let hasStarted = derivedText.job(for: ref, operation: .extractText)?.hasStarted == true
            return (.recognizingText(into: target.translationCode, hasStarted: hasStarted), nil)
        }
        let made: (column: TranslationColumn, result: DerivedText?)
        switch derivedText.outcome(for: ref, operation: .translate) {
        case .saving(let text, let request, let status)?:
            made = (.translation(text, into: request.targetLanguage, status: status), nil)
        case .saved(let result)?: made = (Self.translationColumn(showing: result), result)
        case .noText?:
            let into = derivedText.shownRequest(for: ref, operation: .translate)?.targetLanguage
            let isImage = selection.selectedRow?.kind == .image
            made = (isImage ? .noTextInImage(into: into) : .nothingToTranslate(into: into), nil)
        case .notSaved(let text, let request, let status)?:
            made = (.unsaved(text, into: request.targetLanguage, status: status), nil)
        case .failed(let error)?:
            let asked = derivedText.failedRequest(for: ref, operation: .translate)?.targetLanguage
            guard savedTranslationRef == ref else { return (.loading, nil) }
            guard let savedTranslation else {
                // Tried again once the store has said it kept none.
                let isWaiting = derivedText.isWaitingToStart(ref, operation: .translate)
                return (isWaiting ? .loading : .failed(error, asked: asked), nil)
            }
            let kept = Self.translationColumn(showing: savedTranslation)
            let isLatest = derivedText.showsLatestEnding(for: ref, operation: .translate)
            return (isLatest ? .failedAgain(kept, error, asked: asked) : kept, savedTranslation)
        case nil:
            guard savedTranslationRef == ref else { return (.loading, nil) }
            if let savedTranslation { return (Self.translationColumn(showing: savedTranslation), savedTranslation) }
            // A translation the person asked for starts once the store has said it kept none.
            return (derivedText.isWaitingToStart(ref, operation: .translate) ? .loading : .notStarted, nil)
        }
        guard let failure = derivedText.failure(for: ref, operation: .translate) else { return made }
        let asked = derivedText.failedRequest(for: ref, operation: .translate)?.targetLanguage
        return (.failedAgain(made.column, failure, asked: asked), made.result)
    }

    private static func translationColumn(showing result: DerivedText) -> TranslationColumn {
        .translation(result.text, into: result.targetLanguage, status: result.status)
    }

    /// The latest translation's ending that the column shows, which tells one ending from another so that each is
    /// said once; nil while the column shows something else.
    var translationColumnEnding: UUID? {
        guard let ref = translationColumnRef, let derivedText = services()?.derivedText else { return nil }
        return derivedText.latestEnding(for: ref, operation: .translate)
    }

    /// Whether the column shows how the latest translation of its clip just ended.
    var isTranslationColumnJustMade: Bool { translationColumnEnding != nil }

    /// Opens the preview with the translation of the selected text, or of the text in the selected image, beside it,
    /// and translates unless something was made of it already, recognizing an image's text first where none is known;
    /// a failure is tried again. Asked for while the column says a translation failed, it tries again. Nothing happens
    /// for a clip that can't be translated.
    func showTranslation() {
        guard let row = selection.selectedRow, Self.isTranslatable(row.kind),
              let derivedText = services()?.derivedText else { return }
        if translationColumnRef == row.ref, translationColumn?.offersTryAgain == true {
            translate()
            return
        }
        resultColumn = .translation
        if !isPreviewExpanded {
            isPreviewExpanded = true
            loadPreview()
        }
        readTranslationLanguages()
        if row.kind == .image {
            derivedText.translateImageUnlessMade(row.ref, to: translationTarget, keepingLineBreaks: keepsLineBreaks)
        } else {
            derivedText.translateUnlessMade(row.ref, to: translationTarget)
        }
    }

    /// Translates the text the column shows again: into `language` when given; else, where the text is in the
    /// language asked for already, into the one the column offers next; else into the language that failed or the one
    /// shown, or the one translations are made in.
    func translate(into language: Locale.Language? = nil) {
        guard let ref = translationColumnRef else { return }
        let asked = translationColumn?.askedLanguage.map(Locale.Language.init(identifier:)) ?? translationTarget
        var target = language ?? asked
        if language == nil, case .failed(let error, _)? = translationColumn, error.kind == .alreadyInTargetLanguage,
           let next = translationTarget(after: asked) {
            target = next
        }
        // A language the column names is kept without its region: it is made in the region the person wants it in.
        target = TranslationTargets.variant(of: target, preferred: preferredLanguages(),
                                            offered: knownTranslationLanguages)
        // The text in an image is translated again as it was recognized, and recognized first only where it never was.
        if selection.selectedRow?.kind == .image {
            services()?.derivedText?.translateText(inImage: ref, to: target, keepingLineBreaks: keepsLineBreaks)
        } else {
            services()?.derivedText?.translate(ref, to: target)
        }
    }

    /// Whether there is a translation to stop in the column: one under way or waiting its turn, or one asked for that
    /// waits on what the store kept.
    var canStopTranslation: Bool {
        guard let ref = translationColumnRef, let derivedText = services()?.derivedText else { return false }
        return translationColumn?.isTranslating == true || derivedText.isWaitingToStart(ref, operation: .translate)
    }

    func stopTranslation() {
        guard let ref = translationColumnRef else { return }
        services()?.derivedText?.stop(ref, operation: .translate)
    }

    /// The whole text the column shows, made now or kept from before, whether or not the library could keep it: what
    /// copying all of it and Save Text as Snippet take. Part of a text, as a stopped or cut-off one is, can only be
    /// copied by selecting it.
    var textColumnText: String? { textColumn?.wholeText }

    /// Whether the text beside the image, or the translation beside the text, was copied just now.
    var isTextCopied: Bool {
        guard let copied, let column = resultColumn else { return false }
        return copied.ref == resultColumnRef && copied.column == column
    }

    /// The clip the preview shows a result beside: an image with its text, or a text with its translation.
    var resultColumnRef: ContentRef? { textColumnRef ?? translationColumnRef }

    /// The whole result the preview shows beside the clip, whether or not the library could keep it.
    var resultColumnText: String? { textColumnRef != nil ? textColumnText : translationColumnText }

    /// The whole result the preview shows beside the clip, as it was saved: what Return takes.
    var resultColumnResult: DerivedText? { textColumnRef != nil ? textColumnResult : translationColumnResult }

    /// The whole translation the column shows, made now or kept from before, whether or not the library could keep it.
    var translationColumnText: String? { translationColumn?.wholeText }

    /// Copies the text beside an image, or the translation beside a text, or `part` of it as its own Copy hands it over,
    /// as plain text that capture skips. The panel stays open, and says for a moment that it copied. Returns whether the clipboard was
    /// written.
    @discardableResult
    func copyText(_ part: String? = nil) -> Bool {
        guard let ref = resultColumnRef, let column = resultColumn, let text = part ?? resultColumnText,
              let paste = services()?.paste, paste.copyText(text) else { return false }
        copied = (ref, column)
        textCopiedNote?.cancel()
        textCopiedNote = Task { [weak self] in
            try? await Task.sleep(for: Self.textCopiedNoteDuration)
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
        return true
    }

    /// What Save Text as Snippet came to: no whole text to keep; a message the toolbar now shows; or a save that went
    /// on while the column it was asked for closed or moved on, which says nothing.
    enum TextSaveOutcome: Equatable {
        case nothingToSave, said(String), interrupted
    }

    /// ⌘S while the preview shows the text beside an image: that text becomes a snippet of its own, a new item, and
    /// the image stays as it was. Saved again in this showing, it is there already. What the save came to is said
    /// only while the same image's text shows.
    @discardableResult
    func saveTextAsSnippet() async -> TextSaveOutcome {
        guard isOpen, !saving, let ref = resultColumnRef, let text = resultColumnText, let currentSession = session,
              let library = services()?.library else { return .nothingToSave }
        let name = textColumnRef != nil ? "Text" : "Translation"
        failure = nil
        guard !savedTexts.contains(text) else { return say("Already in Snippets") }
        saving = true
        defer { saving = false }
        func stillAsked() -> Bool { isOpen && session === currentSession && resultColumnRef == ref }
        do {
            let identity = try await library.controller.identity()
            guard stillAsked() else { return .interrupted }
            _ = try await library.create(MemoDraft(body: text), expecting: identity)
            // Saved, whatever the column does meanwhile: saving it again in this showing says so.
            savedTexts.insert(text)
            guard stillAsked() else { return .interrupted }
            // Undo Save takes back a clip saved as a snippet; this is a snippet of its own.
            savedUndo = nil
            canUndoSave = false
            return say("\(name) saved to Snippets")
        } catch {
            guard stillAsked() else { return .interrupted }
            return say("The \(name.lowercased()) couldn't be saved. Try again.")
        }
    }

    private func say(_ message: String) -> TextSaveOutcome {
        saveMessage = message
        return .said(message)
    }

    /// The person's choice of layout, as the panel opens. It changes nothing shown.
    func restoreKeepsLineBreaks(_ keeps: Bool) {
        keepsLineBreaks = keeps
    }

    /// Whether Keep Line Breaks shows as on: as the text in the column is laid out, or without text there, as the
    /// person chose.
    var isKeepLineBreaksOn: Bool {
        textColumn?.keepsLineBreaks ?? keepsLineBreaks
    }

    /// Turns Keep Line Breaks over from what it shows, and recognizes the text shown, or being made, again in that
    /// layout; a recognition asked for that hasn't started yet starts in it. Returns the person's new choice, for the
    /// panel to keep.
    @discardableResult
    func toggleKeepLineBreaks() -> Bool {
        let column = textColumn
        keepsLineBreaks = !(column?.keepsLineBreaks ?? keepsLineBreaks)
        switch column {
        case .text?, .unsaved?, .recognizing?, .failedAgain(.text, _)?, .failedAgain(.unsaved, _)?:
            extractText()
        case .loading?:
            if let ref = textColumnRef, let derivedText = services()?.derivedText,
               derivedText.isWaitingToStart(ref, operation: .extractText) {
                derivedText.extractTextUnlessMade(from: ref, keepingLineBreaks: keepsLineBreaks)
            }
        case .notStarted?, .noText?, .failed?, .failedAgain?, nil:
            break
        }
        return keepsLineBreaks
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
            readTranslationLanguages()
        }
    }

    /// Reads what an earlier job saved of the previewed clip's translation, for the translation column.
    private func readSavedTranslation() {
        readingSavedTranslation?.cancel()
        readingSavedTranslation = nil
        savedTranslationRef = nil
        savedTranslation = nil
        guard isPreviewExpanded, let row = selection.selectedRow, Self.isTranslatable(row.kind),
              let derivedText = services()?.derivedText else { return }
        let ref = row.ref
        readingSavedTranslation = Task { [weak self] in
            let saved = await derivedText.savedResult(for: ref, operation: .translate)
            guard !Task.isCancelled, let self, selection.selection == ref else { return }
            savedTranslationRef = ref
            savedTranslation = saved
        }
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
        /// The saved text made of the clip that is taken in the clip's place, such as the text recognized in an image.
        var derivedText: DerivedTextPaste? = nil
    }

    /// The selected clip.
    var copyTarget: CopyTarget? {
        selection.executableSelection.map { CopyTarget(ref: $0, generation: selection.generation) }
    }

    /// What Return takes: while the preview shows a result beside the clip, the text in an image or a translation,
    /// that result once it is made whole and kept, and otherwise the selected clip. Nil when there is nothing to take,
    /// as while the result is still being made: then Return takes neither the result nor the clip.
    var actionTarget: CopyTarget? {
        guard let ref = resultColumnRef else { return copyTarget }
        guard selection.executableSelection == ref, let result = resultColumnResult else { return nil }
        return CopyTarget(ref: ref, generation: selection.generation,
                          derivedText: DerivedTextPaste(id: result.id, operation: result.operation,
                                                        textDigest: result.textDigest))
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
                                                       returnIsDown: returnIsDown, confirmation: confirmation,
                                                       derivedText: target.derivedText))
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
        readSavedTranslation()
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
            self.readTranslationLanguages()
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
