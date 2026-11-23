import Foundation
import Observation
import SwiftUI

/// What the Library's rows say of what was made of their items, the text in an image and a translation, as quick
/// access's cards say it (`ResultMarks`): from the jobs and endings the coordinator knows of, and from what the store
/// kept of the items listed, read for them in one go.
@MainActor @Observable
final class LibraryResultMarks {
    /// What the store kept of the items it was asked about, by operation.
    private var kept: [DerivedTextOperation: [ContentRef: DerivedTextSummary]] = [:]
    /// The items the store answered for, by operation: a failure is shown once it has said it kept nothing.
    private var answered: [DerivedTextOperation: Set<ContentRef>] = [:]
    /// The items asked about, or being asked about, by operation.
    @ObservationIgnored private var asked: [DerivedTextOperation: Set<ContentRef>] = [:]
    /// Tells a read from before `forget` from one after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let derivedText: @MainActor () -> DerivedTextCoordinator?

    init(derivedText: @escaping @MainActor () -> DerivedTextCoordinator?) {
        self.derivedText = derivedText
    }

    /// Reads what the store kept of the items listed that it wasn't asked about yet: the text in images, and the
    /// translations of texts and images.
    func read(for entries: [LibraryEntry]) {
        read(entries.filter { $0.kind == .image }.map(\.ref), .extractText)
        read(entries.filter { QuickAccessState.isTranslatable($0.kind) }.map(\.ref), .translate)
    }

    /// How many items one read asks about: a long list is read a part at a time, so that the store's other work gets in
    /// between.
    static let readSize = 100

    private func read(_ refs: [ContentRef], _ operation: DerivedTextOperation) {
        let asking = refs.filter { asked[operation]?.contains($0) != true }
        stride(from: 0, to: asking.count, by: Self.readSize).forEach { start in
            ask(Array(asking[start..<min(start + Self.readSize, asking.count)]), operation)
        }
    }

    private func ask(_ asking: [ContentRef], _ operation: DerivedTextOperation) {
        guard let derivedText = derivedText(), !asking.isEmpty else { return }
        asked[operation, default: []].formUnion(asking)
        let generation = generation
        Task { [weak self] in
            let summaries = await derivedText.savedSummaries(of: asking, operation: operation)
            guard let self, self.generation == generation else { return }
            guard let summaries else {
                // Unread, they are asked about again with the next read.
                asked[operation]?.subtract(asking)
                return
            }
            if !summaries.isEmpty { kept[operation, default: [:]].merge(summaries) { _, read in read } }
            answered[operation, default: []].formUnion(asking)
        }
    }

    /// Forgets what the store said, as the library changes; it is read again. While the library stays the same, what
    /// its jobs make and end shows from the coordinator, so the store isn't asked again.
    func forget() {
        generation &+= 1
        kept = [:]
        answered = [:]
        asked = [:]
    }

    func textMark(for entry: LibraryEntry) -> StripTextMark? {
        guard let derivedText = derivedText() else { return nil }
        return ResultMarks.text(for: entry.ref, kind: entry.kind, in: derivedText, kept: kept[.extractText] ?? [:],
                                answered: answered[.extractText] ?? [])
    }

    func translationMark(for entry: LibraryEntry) -> StripTranslationMark? {
        guard let derivedText = derivedText() else { return nil }
        return ResultMarks.translation(for: entry.ref, kind: entry.kind, in: derivedText,
                                       kept: kept[.translate] ?? [:], answered: answered[.translate] ?? [])
    }
}

/// The marks at the end of a Library row for what was made of its item: the text in an image, and a "文A" for a
/// translation, worked out here so that only the marks, not the whole list, follow the jobs. They are drawn in the
/// row's own colours, which a selected row turns light, so that they show on it too; a failure has its own glyph, orange
/// but light on a selected row. Their help tags say what each means, and VoiceOver reads them after the row.
struct LibraryRowMarks: View {
    let entry: LibraryEntry
    let marks: LibraryResultMarks
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let text = marks.textMark(for: entry)
        let translation = marks.translationMark(for: entry)
        if text != nil || translation != nil {
            HStack(spacing: 5) {
                if let text { textMark(text) }
                if let translation { translationMark(translation) }
            }
        }
    }

    @ViewBuilder
    private func textMark(_ mark: StripTextMark) -> some View {
        Image(systemName: mark.isFailure ? "exclamationmark.triangle" : "text.viewfinder")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(style(isFailed: mark.isFailure))
            .opacity(pendingOpacity(mark == .recognizing || mark == .waiting))
            .help(mark.help)
            .accessibilityLabel(mark.rowSpoken)
            .accessibilityIdentifier("LibraryRowTextMark")
    }

    @ViewBuilder
    private func translationMark(_ mark: StripTranslationMark) -> some View {
        if mark.isFailure {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(style(isFailed: true))
                .help(mark.help)
                .accessibilityLabel(mark.rowSpoken)
                .accessibilityIdentifier("LibraryRowTranslationMark")
        } else {
            Text(verbatim: "文A")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style(isFailed: false))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(style(isFailed: false),
                                      style: StrokeStyle(lineWidth: 1, dash: mark == .stopped ? [2, 1.5] : []))
                }
                .opacity(pendingOpacity(mark.isTranslating || mark == .waiting))
                .help(mark.help)
                .accessibilityLabel(mark.rowSpoken)
                .accessibilityIdentifier("LibraryRowTranslationMark")
        }
    }

    private func style(isFailed: Bool) -> AnyShapeStyle {
        guard isFailed, prominence != .increased else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.orange)
    }

    /// A job under way or waiting is dimmed, but not with Increase Contrast.
    private func pendingOpacity(_ isPending: Bool) -> Double {
        isPending && contrast != .increased ? 0.55 : 1
    }
}

extension StripTextMark {
    /// Making it failed.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// What VoiceOver hears of the mark on its own, after a Library row.
    var rowSpoken: String {
        switch self {
        case .recognizing: "Recognizing text in image"
        case .waiting: "Waiting to recognize text in image"
        case .hasText: "Text found in image"
        case .failed(let reason): "Text recognition failed: \(reason)"
        }
    }
}

extension StripTranslationMark {
    /// Making it failed.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// What VoiceOver hears of the mark on its own, after a Library row.
    var rowSpoken: String {
        switch self {
        case .translating(let language?): "Translating to \(Locale.Language(identifier: language).displayName)"
        case .translating(nil): "Translating"
        case .waiting: "Waiting to translate"
        case .translated(let language?): "Translated to \(Locale.Language(identifier: language).displayName)"
        case .translated(nil): "Translated"
        case .stopped: "Translation stopped"
        case .failed(let reason): "Translation failed: \(reason)"
        }
    }
}
