import AppKit
import Carbon.HIToolbox
import Observation

/// What was made of the item the Library's detail shows, beside it: the text recognized in an image, or a translation
/// of a text or of the text in an image, one at a time. Opened by Item › Extract Text and Translate and the row's
/// menu, and closed with its close button, with Escape, or as the detail moves to another item. What it shows is
/// worked out as quick access works it out (`ResultColumnContents`).
@MainActor @Observable
final class LibraryResultColumn {
    /// What the column reads and acts through.
    struct Services {
        let derivedText: DerivedTextCoordinator
        /// Writes text to the clipboard as Keeptide's own copy, which capture skips; false where it couldn't.
        let copyText: @MainActor (String) -> Bool
        /// Saves text as a snippet of its own.
        let saveSnippet: @MainActor (String) async throws -> Void
        /// Whether recognized text keeps the image's line breaks, as Settings says.
        let keepsLineBreaks: @MainActor () -> Bool
        /// Says something to VoiceOver from the Library's window.
        let announce: @MainActor (String) -> Void
        /// The language Settings fixes translations in, if any, and the one last chosen from a language menu, by
        /// their codes, as quick access keeps them.
        let translationTargets: @MainActor () -> (fixed: String?, lastUsed: String?)
        /// Keeps a language chosen from a language menu as the last used one, for quick access too.
        let keepLastUsed: @MainActor (String) -> Void
    }

    static let copiedNoteDuration: Duration = .seconds(1.5)

    /// The item whose result the column shows; nil while it is closed.
    private(set) var ref: ContentRef?
    /// Which column shows: the text in an image, or a translation.
    private(set) var showing: ResultColumn?
    /// Whether the item is an image: its text is recognized before it is translated.
    private(set) var isImage = false
    /// The item's own text, for telling its language, where the detail has it.
    @ObservationIgnored private var itemText: String?
    /// What the store kept of the result shown, once it has said. Until it is what it said of `ref`, the column is still
    /// reading.
    private var kept: KeptResult?
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Tells one opening of the column from the next, so that a read or a save that ends after the column closed leaves
    /// the next opening alone.
    @ObservationIgnored private var opening = UUID()
    /// The opening whose save is under way, if any: it saves once at a time.
    @ObservationIgnored private var savingOpening: UUID?
    /// Whether the column's result was copied just now: the column says so for a moment.
    private(set) var isCopied = false
    @ObservationIgnored private var copiedNote: Task<Void, Never>?
    /// What saving the column's result as a snippet came to, said beside its buttons until the column closes.
    private(set) var saveMessage: String?
    /// The results saved as snippets while the column was open: saving one again says it is there already.
    @ObservationIgnored private var savedTexts: Set<String> = []
    @ObservationIgnored private var endings = ResultColumnEndings()
    /// What the Library knows of the languages translations can be made in.
    let languages: TranslationLanguageState
    @ObservationIgnored private let services: @MainActor () -> Services?

    /// `preferredLanguages` are the languages the person prefers, first first, as the system lists them.
    init(services: @escaping @MainActor () -> Services?,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.services = services
        languages = TranslationLanguageState(preferred: preferredLanguages)
    }

    /// What the text column shows; nil while another column, or none, shows, or without the library.
    var textColumn: TextColumn? {
        guard showing == .text, let ref, let derivedText = services()?.derivedText else { return nil }
        return ResultColumnContents.text(for: ref, in: derivedText, kept: kept).column
    }

    /// What the translation column shows; nil while another column, or none, shows, or without the library.
    var translationColumn: TranslationColumn? {
        guard showing == .translation, let ref, let derivedText = services()?.derivedText else { return nil }
        return ResultColumnContents.translation(for: ref, isImage: isImage, in: derivedText, kept: kept).column
    }

    /// The whole result the column shows, made now or kept from before: what Copy and Save as Snippet take.
    var text: String? { textColumn?.wholeText ?? translationColumn?.wholeText }

    /// The operation the column shows the result of.
    private var operation: DerivedTextOperation? {
        showing.map { $0 == .text ? .extractText : .translate }
    }

    /// The latest job's ending that the column shows, which tells one ending from another; nil while it shows
    /// something else.
    var ending: UUID? {
        guard let ref, let operation, let derivedText = services()?.derivedText else { return nil }
        return derivedText.latestEnding(for: ref, operation: operation)
    }

    /// Whether the column shows how the latest job just ended, rather than a result kept from before.
    var isJustMade: Bool { ending != nil }

    /// Whether a recognition or a translation is under way or waiting its turn: the column offers to stop it.
    var isRunning: Bool { textColumn?.isRecognizing == true || translationColumn?.isTranslating == true }

    /// Whether there is a job to stop: one under way or waiting its turn, or one asked for that waits on what the
    /// store kept.
    var canStop: Bool {
        guard let ref, let operation, let derivedText = services()?.derivedText else { return false }
        return isRunning || derivedText.isWaitingToStart(ref, operation: operation)
    }

    /// The language translations are made in: the one fixed in Settings, else the last used one, else the first the
    /// person prefers.
    var translationTarget: Locale.Language {
        let targets: (fixed: String?, lastUsed: String?) = services()?.translationTargets() ?? (nil, nil)
        return languages.target(fixed: targets.fixed, lastUsed: targets.lastUsed)
    }

    /// The language menu for the item shown: the language its translation is in, or else the one translations are
    /// made in, chosen.
    var languageMenu: TranslationLanguageMenu {
        let shown = translationColumn?.language.map(Locale.Language.init(identifier:))
        return languages.menu(for: ref, chosen: shown ?? translationTarget)
    }

    // MARK: The text in an image

    /// Opens the text column for the image `ref` and recognizes its text unless something was made of it already, as
    /// quick access does. Asked for while the column says a recognition failed, it tries again.
    func showText(_ ref: ContentRef) {
        guard let services = services() else { return }
        if self.ref == ref, showing == .text, textColumn?.isFailed == true {
            extractText()
            return
        }
        if self.ref != ref || showing != .text {
            open(ref, .text, isImage: true, itemText: nil, services)
        }
        services.derivedText.extractTextUnlessMade(from: ref, keepingLineBreaks: services.keepsLineBreaks())
    }

    /// Recognizes the column's image again, as Try Again does.
    func extractText() {
        guard showing == .text, let ref, let services = services() else { return }
        services.derivedText.extractText(from: ref, keepingLineBreaks: services.keepsLineBreaks())
    }

    // MARK: Translation

    /// Opens the translation column for `ref` and translates it into the language translations are made in, unless
    /// something was made of it already; an image's text is recognized first where none is known. Asked for while the
    /// column says a translation failed, it tries again. `itemText` is the item's own text, where the detail has it,
    /// for telling its language.
    func showTranslation(_ ref: ContentRef, isImage: Bool, itemText: String?) {
        guard let services = services() else { return }
        if self.ref == ref, showing == .translation, translationColumn?.offersTryAgain == true {
            translate()
            return
        }
        if self.ref != ref || showing != .translation {
            open(ref, .translation, isImage: isImage, itemText: itemText, services)
        }
        readLanguageMarks()
        let target = translationTarget
        if isImage {
            services.derivedText.translateImageUnlessMade(ref, to: target,
                                                          keepingLineBreaks: services.keepsLineBreaks())
        } else {
            services.derivedText.translateUnlessMade(ref, to: target)
        }
    }

    /// Translates the item shown again: into `language` when given; else, where its text is in the language asked
    /// for already, into the one the column offers next; else into the language that failed or the one shown, or the
    /// one translations are made in.
    func translate(into language: Locale.Language? = nil) {
        guard showing == .translation, let ref, let services = services() else { return }
        // What saving the translation before came to isn't this one's.
        saveMessage = nil
        let asked = translationColumn?.askedLanguage.map(Locale.Language.init(identifier:)) ?? translationTarget
        var target = language ?? asked
        if language == nil, case .failed(let error, _)? = translationColumn, error.kind == .alreadyInTargetLanguage,
           let next = languages.target(after: asked) {
            target = next
        }
        // A language the column names is kept without its region: it is made in the region the person wants it in.
        target = languages.variant(of: target)
        // The text in an image is translated again as it was recognized, and recognized first only where it never was.
        if isImage {
            services.derivedText.translateText(inImage: ref, to: target, keepingLineBreaks: services.keepsLineBreaks())
        } else {
            services.derivedText.translate(ref, to: target)
        }
    }

    /// Chooses a language from a language menu, by its code, for `ref`: kept as the last used one, for quick access
    /// too, and the item's translation shows in it, made in it unless the column shows a whole one in it or one is
    /// being made in it. A code that names no language chooses nothing.
    func chooseLanguage(_ code: String, for ref: ContentRef, isImage: Bool, itemText: String?) {
        guard let code = TranslationTargets.code(of: code), let services = services() else { return }
        services.keepLastUsed(code)
        let language = languages.variant(of: Locale.Language(identifier: code))
        if self.ref != ref || showing != .translation {
            open(ref, .translation, isImage: isImage, itemText: itemText, services)
        }
        readLanguageMarks()
        // A whole translation kept in that language shows as it is: until the store has said, it waits for it.
        let opening = opening
        let reading = reading
        Task { [weak self] in
            await reading?.value
            guard let self, self.opening == opening else { return }
            translateUnlessShown(in: language)
        }
    }

    /// Translates the item shown into `language`, unless the column shows a whole translation in it or one is being
    /// made in it. One made in the background in that language becomes the person's, made again as theirs.
    private func translateUnlessShown(in language: Locale.Language) {
        guard let ref, let derivedText = services()?.derivedText else { return }
        let isBackground = derivedText.job(for: ref, operation: .translate)?.priority == .automatic
        if !isBackground, let column = translationColumn, column.isTranslating || column.wholeText != nil,
           column.language.map(Locale.Language.init(identifier:))?.isSameLanguage(as: language) == true {
            return
        }
        translate(into: language)
    }

    /// Chooses a language from the column's own language menu, for the item it shows.
    func chooseLanguage(_ code: String) {
        guard let ref else { return }
        chooseLanguage(code, for: ref, isImage: isImage, itemText: itemText)
    }

    /// Tells the language of the item shown, from its own text or, for an image, from the text recognized in it in
    /// this session, and reads what translating it into each language needs, for the language menu.
    func readLanguageMarks() {
        guard showing == .translation, let ref, let derivedText = services()?.derivedText else { return }
        let itemText = itemText
        let isImage = isImage
        languages.readMarks(for: ref, text: { isImage ? derivedText.recognizedText(in: ref) : itemText },
                            in: derivedText)
    }

    // MARK: Either column

    /// Opens the column for `ref`, reading what was kept of the result it shows, and says so unless `announces` is
    /// false.
    private func open(_ ref: ContentRef, _ column: ResultColumn, isImage: Bool, itemText: String?,
                      _ services: Services, announces: Bool = true) {
        close()
        self.ref = ref
        showing = column
        self.isImage = isImage
        self.itemText = itemText
        let opening = opening
        let operation: DerivedTextOperation = column == .text ? .extractText : .translate
        let derivedText = services.derivedText
        reading = Task { [weak self] in
            let saved = await derivedText.savedResult(for: ref, operation: operation)
            guard !Task.isCancelled, let self, self.opening == opening else { return }
            kept = KeptResult(source: ref, result: saved)
        }
        guard announces else { return }
        let title = column == .text ? TextColumnWords.title : TranslationColumnWords.title
        services.announce("\(title), on this Mac")
    }

    func stop() {
        guard let ref, let operation else { return }
        services()?.derivedText.stop(ref, operation: operation)
    }

    /// Closes the column. A job under way goes on, and a save under way ends saying nothing.
    func close() {
        reading?.cancel()
        reading = nil
        opening = UUID()
        ref = nil
        showing = nil
        isImage = false
        itemText = nil
        kept = nil
        copiedNote?.cancel()
        copiedNote = nil
        isCopied = false
        saveMessage = nil
        savedTexts = []
        endings.reset()
    }

    /// The detail now shows `ref`, or nothing: the column closes unless it is that item's. The same item saved again,
    /// as after an edit, is another version: the column stays and shows what was made of that version, offering to
    /// make it where nothing was. `itemText` is the item's own text, where the detail has it.
    func follow(_ ref: ContentRef?, itemText: String? = nil) {
        guard let current = self.ref, current != ref else { return }
        guard let ref, ref.itemID == current.itemID, let column = showing, let services = services() else {
            close()
            return
        }
        open(ref, column, isImage: isImage, itemText: itemText ?? self.itemText, services, announces: false)
    }

    /// Copies the column's whole result, or `part` of it as its own Copy hands it over, and says so. Returns whether
    /// the clipboard was written.
    @discardableResult
    func copy(_ part: String? = nil) -> Bool {
        guard ref != nil, let text = part ?? text, let services = services(), services.copyText(text) else {
            return false
        }
        isCopied = true
        services.announce("Copied")
        copiedNote?.cancel()
        copiedNote = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedNoteDuration)
            guard !Task.isCancelled else { return }
            self?.isCopied = false
        }
        return true
    }

    /// What the column calls its result: "Text" or "Translation".
    var resultName: String { showing == .translation ? "Translation" : "Text" }

    /// Saves the column's whole result as a snippet of its own, and returns what that came to, as the column says it;
    /// nil where there was no whole result to save, a save was under way already, or the column closed meanwhile.
    @discardableResult
    func saveAsSnippet() async -> String? {
        let opening = opening
        let name = resultName
        guard ref != nil, savingOpening != opening, let text, let services = services() else { return nil }
        guard !savedTexts.contains(text) else { return say("Already in Snippets", services) }
        savingOpening = opening
        defer { if savingOpening == opening { savingOpening = nil } }
        do {
            try await services.saveSnippet(text)
            guard self.opening == opening else { return nil }
            savedTexts.insert(text)
            return say("\(name) saved to Snippets", services)
        } catch {
            guard self.opening == opening else { return nil }
            return say("The \(name.lowercased()) couldn't be saved. Try again.", services)
        }
    }

    private func say(_ message: String, _ services: Services) -> String {
        saveMessage = message
        services.announce(message)
        return message
    }

    /// What VoiceOver hears as a job ends here without a new result, once per ending; nil otherwise. What the column
    /// shows as it opens is only shown.
    func endingToAnnounce() -> String? {
        let words: String?
        let isRead: Bool
        if let column = textColumn {
            (words, isRead) = (column.endingWords, column.isRead)
        } else if let column = translationColumn {
            (words, isRead) = (column.endingWords, column.isRead)
        } else {
            return endings.words(for: nil, isOpen: true)
        }
        guard let ref else { return nil }
        return endings.words(for: (ref: ref, ending: ending, words: words, isRead: isRead), isOpen: true)
    }

    /// Says how a job just ended without a new result, where it did.
    func announceEnding() {
        guard let words = endingToAnnounce() else { return }
        services()?.announce(words)
    }
}

/// Where the Library's result column goes beside the item.
enum LibraryResultLayout {
    /// Narrower than this, the detail shows the column under the item.
    static let sideBySideWidth: CGFloat = 640

    static func isSideBySide(width: CGFloat) -> Bool { width >= sideBySideWidth }
}

/// What keys pressed in the Library's result text do before the text takes them: Escape closes the column, and ⌘.
/// stops a recognition or a translation, and never closes the column, so that one pressed just as the job ends isn't
/// taken as Escape. Held down, either has acted already.
@MainActor
enum LibraryResultKeys {
    /// True when the column took the key.
    static func handle(_ event: NSEvent, _ column: LibraryResultColumn) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isEscape = Int(event.keyCode) == kVK_Escape && modifiers.subtracting(.shift).isEmpty
        // ⇧⌘. too, where the keyboard needs Shift for the full stop.
        let isCommandPeriod = event.charactersIgnoringModifiers == "." && modifiers.subtracting(.shift) == .command
        guard isEscape || isCommandPeriod else { return false }
        guard !event.isARepeat else { return true }
        if isEscape { column.close() } else { column.stop() }
        return true
    }
}
