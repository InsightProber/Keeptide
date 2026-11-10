import AppKit
import SwiftUI

/// The open item beside what was made of it: side by side where the detail is at least 640 points wide, the result
/// under the item where it is narrower, with a thin line between them as in quick access.
struct LibraryResultSplit<Content: View, Column: View>: View {
    let showsColumn: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let column: () -> Column
    /// Whether the detail is wide enough for the column beside the item, as it was last laid out: only its changes
    /// lay the item out again, not every change of size.
    @State private var sideBySide = true

    var body: some View {
        let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsColumn {
                ColumnDivider(vertical: sideBySide)
                column().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: Bool.self) { LibraryResultLayout.isSideBySide(width: $0.size.width) } action: {
            sideBySide = $0
        }
    }
}

/// The Library's result column: quick access's text or translation column, with the Library's own buttons at the
/// end of its title. Escape in its text closes it and gives the keyboard back to the list. Each item has a column of
/// its own: the result and its selection never carry over.
struct LibraryResultColumnView: View {
    let resultColumn: LibraryResultColumn
    let returnFocusToList: () -> Void
    /// Opens the menu of languages to translate into at a point in a view.
    let openLanguageMenu: (NSView, NSPoint) -> Void
    /// Where the translation's title is, as SwiftUI last laid it out.
    @State private var languageTitleFrame: CGRect = .zero
    /// The AppKit view behind the column, and where it is in the same space as the title: the menu opens from it.
    @State private var anchor = LibraryMenuAnchor()
    @State private var anchorFrame: CGRect = .zero

    var body: some View {
        Group {
            if let column = resultColumn.textColumn {
                TextInImageColumn(column: column, pixelSize: nil, isJustMade: resultColumn.isJustMade,
                                  identifiers: .init(column: "LibraryTextInImage", extract: "LibraryExtractText"),
                                  onCommand: perform, onCopy: { resultColumn.copy($0) }, onKeyDown: keyDown) {
                    LibraryResultColumnButtons(resultColumn: resultColumn)
                }
            } else if let column = resultColumn.translationColumn {
                let target = resultColumn.translationTarget
                let asked = column.askedLanguage.map(Locale.Language.init(identifier:)) ?? target
                TranslationColumnView(column: column, target: target,
                                      nextTarget: resultColumn.languages.target(after: asked),
                                      isJustMade: resultColumn.isJustMade,
                                      identifiers: .init(column: "LibraryTranslation", translate: "LibraryTranslate",
                                                         language: "LibraryTranslationLanguage"),
                                      onCommand: perform, onCopy: { resultColumn.copy($0) },
                                      onLanguageTitleMoved: { languageTitleFrame = $0 },
                                      languageMenuHelp: "Translate into Another Language",
                                      onKeyDown: keyDown) {
                    LibraryResultColumnButtons(resultColumn: resultColumn)
                }
            }
        }
        .id(resultColumn.ref)
        .background {
            LibraryMenuAnchorView(anchor: anchor)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchorFrame = $0 }
        }
    }

    /// What the column's own buttons ask for: extracting the text again, translating, trying again, or the language
    /// menu.
    private func perform(_ command: QuickAccessCommand) {
        switch command {
        case .extractText: resultColumn.extractText()
        case .translate(let code): resultColumn.translate(into: code.map(Locale.Language.init(identifier:)))
        case .chooseTranslationLanguage:
            resultColumn.readLanguageMarks()
            guard let view = anchor.view else { return }
            // Below the title, wherever the column is in the window: both frames are in the same space.
            openLanguageMenu(view, NSPoint(x: languageTitleFrame.minX - anchorFrame.minX,
                                           y: languageTitleFrame.maxY - anchorFrame.minY + 4))
        default: break
        }
    }

    private func keyDown(_ event: NSEvent) -> Bool {
        guard LibraryResultKeys.handle(event, resultColumn) else { return false }
        if resultColumn.ref == nil { returnFocusToList() }
        return true
    }
}

/// The Library's buttons for the result beside an item, at the end of the column's title: Stop while it is made; for
/// the text in an image, Translate; then Copy and Save as Snippet, dimmed until the result is whole, and Close. Under
/// them, a note of a copy or a save. The Item menu does the same from the keyboard.
struct LibraryResultColumnButtons: View {
    let resultColumn: LibraryResultColumn

    var body: some View {
        let name = resultColumn.resultName
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if resultColumn.isRunning {
                    Button { resultColumn.stop() } label: {
                        HStack(spacing: 6) {
                            Text("Stop")
                            ReviewKeycap(symbol: "⌘.")
                        }
                    }
                    .buttonStyle(TrayCapsuleButtonStyle())
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("LibraryStopResult")
                    .help(resultColumn.showing == .translation ? "Stop Translating (⌘.)" : "Stop Recognizing (⌘.)")
                }
                if resultColumn.showing == .text, let ref = resultColumn.ref {
                    TrayRoundButton(symbol: "translate", label: "Translate Text", help: "Translate the Text (⌘T)",
                                    identifier: "LibraryTranslateText") {
                        resultColumn.showTranslation(ref, isImage: true, itemText: nil)
                    }
                    .disabled(resultColumn.text == nil)
                }
                Group {
                    TrayRoundButton(symbol: "doc.on.doc", label: "Copy \(name)", help: "Copy \(name)",
                                    identifier: "LibraryCopy\(name)") { resultColumn.copy() }
                    TrayRoundButton(symbol: "bookmark", label: "Save \(name) as Snippet",
                                    help: "Save \(name) as Snippet", identifier: "LibrarySave\(name)") {
                        Task { await resultColumn.saveAsSnippet() }
                    }
                }
                .disabled(resultColumn.text == nil)
                TrayRoundButton(symbol: "xmark", label: "Close", help: "Close (Esc)",
                                identifier: "LibraryCloseResultColumn") { resultColumn.close() }
            }
            if let note = resultColumn.isCopied ? "Copied" : resultColumn.saveMessage {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("LibraryResultColumnNote")
            }
        }
    }
}

/// Says to VoiceOver how a recognition or a translation in the result column ended without a new result. It follows
/// the column itself, so that only it, and not the whole Library, follows each step of a job; it asks on every change
/// of what the column shows or of the ending it shows.
struct LibraryResultColumnAnnouncer: View {
    let resultColumn: LibraryResultColumn

    private struct Shown: Equatable {
        let text: TextColumn?
        let translation: TranslationColumn?
        let ending: UUID?
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: Shown(text: resultColumn.textColumn, translation: resultColumn.translationColumn,
                                ending: resultColumn.ending)) { _, _ in
                resultColumn.announceEnding()
            }
    }
}

extension TranslationLanguageMenu.Item {
    /// The language's name in a SwiftUI menu, which shows no badges: with what translating into it needs after it.
    var menuTitle: String { note.map { "\(name) — \($0.title)" } ?? name }
}

/// The AppKit view behind the result column that its language menu opens from.
@MainActor
final class LibraryMenuAnchor {
    weak var view: NSView?
}

/// A flipped AppKit view behind the result column, so that the menu's point is measured from its top, as SwiftUI's are.
private struct LibraryMenuAnchorView: NSViewRepresentable {
    let anchor: LibraryMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
