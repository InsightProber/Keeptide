import Foundation
import Observation

/// What a surface knows of the languages translations can be made in, as quick access reads it and another surface can:
/// the languages Translation offers, kept until they are read again, and, for what the surface shows, the language each
/// item's text was told to be in and what translating from a language into each needs. A surface forgets those as it
/// shows again (`showAgain`), as a language may be downloaded or removed meanwhile.
@MainActor @Observable
final class TranslationLanguageState {
    /// The languages translations can be made in, a language in each of its regions, as Translation last listed them:
    /// empty until then.
    private(set) var known: [Locale.Language] = []
    @ObservationIgnored private var readingKnown: Task<Void, Never>?
    /// What translating from a language into each language needs, by the code of the language translated from, as
    /// read while the surface shows.
    private var pairStatuses: [String: [TranslationLanguage]] = [:]
    @ObservationIgnored private var readingPairStatuses: [String: Task<Void, Never>] = [:]
    /// The language each item's text was told to be in while the surface shows: nil where it couldn't be told.
    private var textLanguages: [ContentRef: Locale.Language?] = [:]
    @ObservationIgnored private var telling: (ref: ContentRef, task: Task<Void, Never>)?
    /// The languages the person prefers, first first, as the system lists them.
    private let preferred: () -> [String]

    init(preferred: @escaping () -> [String]) {
        self.preferred = preferred
    }

    /// The language translations are made in: the one fixed in Settings, else the one last chosen from the language
    /// menu, while Translation offers it, or else the first the person prefers that it offers, each in the region the
    /// person wants it in.
    func target(fixed: String?, lastUsed: String?) -> Locale.Language {
        TranslationTargets.target(fixed: fixed, lastUsed: lastUsed, preferred: preferred(), offered: known)
    }

    /// The language to offer where the text is in the one asked for already; nil without another.
    func target(after language: Locale.Language) -> Locale.Language? {
        TranslationTargets.next(after: language, of: preferred(), offered: known)
    }

    /// `language` in the region translations into it are made in.
    func variant(of language: Locale.Language) -> Locale.Language {
        TranslationTargets.variant(of: language, preferred: preferred(), offered: known)
    }

    /// The language menu for an item: the languages the person prefers that translations can be made in, then English,
    /// then the others by name, each once whatever its regions, in the region translations into it are made in. Once
    /// the item's text was told to be in a language while the surface shows, each is marked for what translating from
    /// that language into it needs. Until Translation's languages are read, the person's own and English. The language
    /// that is the same as `chosen`, whatever its region, is marked chosen.
    func menu(for ref: ContentRef?, chosen: Locale.Language) -> TranslationLanguageMenu {
        // The marks are for this item's own language, never another item's.
        var statuses: [TranslationLanguage] = []
        if let ref, let entry = textLanguages[ref], let told = entry {
            statuses = pairStatuses[told.translationCode] ?? []
        }
        let ordered = TranslationTargets.ordered(preferred: preferred(), offered: known)
        func item(_ language: Locale.Language) -> TranslationLanguageMenu.Item {
            let status = statuses.first {
                $0.language.isSameLanguage(as: language) && $0.language.region == language.region
            }?.status
            return TranslationLanguageMenu.Item(code: language.translationCode, name: language.displayName,
                                                note: TranslationLanguageMenu.Note(status),
                                                isChosen: language.isSameLanguage(as: chosen))
        }
        return TranslationLanguageMenu(preferred: ordered.preferred.map(item), others: ordered.others.map(item))
    }

    /// Tells an item's language from its text, unless that was done while the surface shows, and reads what
    /// translating from that language needs, unless that was read: what the language menu marks. Without text at hand
    /// (`text` gives nil), it does nothing yet; the surface asks again as it has more.
    func readMarks(for ref: ContentRef, text: () -> String?, in derivedText: DerivedTextCoordinator) {
        if let entry = textLanguages[ref] {
            if let told = entry { readPairStatuses(from: told, derivedText) }
            return
        }
        guard telling?.ref != ref, let body = text() else { return }
        telling?.task.cancel()
        telling = (ref, Task { [weak self] in
            let language = await derivedText.language(of: body)
            guard !Task.isCancelled, let self else { return }
            telling = nil
            textLanguages.updateValue(language, forKey: ref)
            if let language { readPairStatuses(from: language, derivedText) }
        })
    }

    /// Reads what translating from `source` into each language needs, unless that was read while the surface shows or
    /// is being read.
    private func readPairStatuses(from source: Locale.Language, _ derivedText: DerivedTextCoordinator) {
        let code = source.translationCode
        guard pairStatuses[code] == nil, readingPairStatuses[code] == nil else { return }
        readingPairStatuses[code] = Task { [weak self] in
            let languages = await derivedText.translationLanguages(from: source)
            guard !Task.isCancelled, let self else { return }
            readingPairStatuses[code] = nil
            pairStatuses[code] = languages
            if known.isEmpty { known = languages.map(\.language) }
        }
    }

    /// The surface shows again, or its library changed: it stops the reads under way, forgets the languages told and
    /// what translating from them needs, and reads the languages Translation lists. Those read before stand until then,
    /// and where it lists none. Without a coordinator, as while the library is closed, nothing is read.
    func showAgain(in derivedText: DerivedTextCoordinator?) {
        cancelReads()
        textLanguages = [:]
        pairStatuses = [:]
        readKnown(in: derivedText)
    }

    private func readKnown(in derivedText: DerivedTextCoordinator?) {
        readingKnown?.cancel()
        guard let derivedText else { return }
        readingKnown = Task { [weak self] in
            let languages = await derivedText.translationLanguages(from: nil).map(\.language)
            guard !Task.isCancelled, let self, !languages.isEmpty else { return }
            known = languages
        }
    }

    /// Stops telling languages and reading what they need, as the surface closes.
    func cancelReads() {
        readingKnown?.cancel()
        readingKnown = nil
        telling?.task.cancel()
        telling = nil
        readingPairStatuses.values.forEach { $0.cancel() }
        readingPairStatuses = [:]
    }
}
