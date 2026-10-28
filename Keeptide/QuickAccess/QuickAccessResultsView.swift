import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Hosts the panel's result table. AppKit owns focus, selection, scrolling and keys;
/// SwiftUI draws each row's content.
struct QuickAccessResultsView: NSViewRepresentable {
    let table: QuickAccessResultsTableView
    let rows: [QuickAccessRow]
    let selection: ContentRef?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        table.show(rows, selection: selection)
    }
}

/// The result list. Hover never selects; double-click is not an action; keys go
/// through `QuickAccessKeyRouter`.
final class QuickAccessResultsTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((ContentRef) -> Void)?
    var onCommand: ((QuickAccessCommand) -> Void)?
    var onRowVisible: ((Int) -> Void)?
    /// The selection the panel state actually holds.
    var selectionProvider: (() -> ContentRef?)?
    private(set) var rows: [QuickAccessRow] = []
    private var isApplyingSelection = false
    private var appliedSelection: ContentRef?
    private let applicationNames = ApplicationNames()

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QuickAccessResult"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        style = .inset
        rowHeight = 60
        intercellSpacing = NSSize(width: 0, height: 2)
        backgroundColor = .clear
        allowsEmptySelection = true
        allowsMultipleSelection = false
        allowsTypeSelect = false
        columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        dataSource = self
        delegate = self
        setAccessibilityIdentifier("QuickAccessResults")
        setAccessibilityLabel("Results")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ rows: [QuickAccessRow], selection: ContentRef?) {
        if rows != self.rows {
            self.rows = rows
            reloadData()
        }
        // Scroll only when the selection itself changes, so loading more rows or a
        // refresh never pulls the list away from where the pointer scrolled it.
        apply(selection, scroll: selection != appliedSelection)
    }

    private func apply(_ selection: ContentRef?, scroll: Bool) {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        appliedSelection = selection
        if let selection, let index = rows.firstIndex(where: { $0.ref == selection }) {
            if selectedRow != index { selectRowIndexes([index], byExtendingSelection: false) }
            if scroll { scrollRowToVisible(index) }
        } else if selectedRow != -1 {
            deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = makeView(withIdentifier: QuickAccessRowCell.reuseIdentifier, owner: self) as? QuickAccessRowCell
            ?? QuickAccessRowCell()
        let item = rows[row]
        cell.show(item, applicationName: item.sourceApp.flatMap(applicationNames.name(for:)))
        onRowVisible?(row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        if rows.indices.contains(selectedRow) {
            onSelect?(rows[selectedRow].ref)
            window?.makeFirstResponder(self)
        }
        // The highlight always shows what an action would use: a click the state
        // rejected, or a click that cleared the table, shows the state's row again.
        apply(selectionProvider.map { $0() } ?? appliedSelection, scroll: false)
    }

    override func keyDown(with event: NSEvent) {
        let key: QuickAccessKey? = switch Int(event.keyCode) {
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_Return, kVK_ANSI_KeypadEnter: .returnKey
        case kVK_Space: .space
        case kVK_Escape: .escape
        default: nil
        }
        guard let key else { return super.keyDown(with: event) }
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .results
        ))
        guard command != .passThrough else { return super.keyDown(with: event) }
        onCommand?(command)
    }
}

private final class QuickAccessRowCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("QuickAccessRowCell")
    private let host = NSHostingView(rootView: QuickAccessRowContent(row: nil, applicationName: nil))

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ row: QuickAccessRow, applicationName: String?) {
        host.rootView = QuickAccessRowContent(row: row, applicationName: applicationName)
        setAccessibilityLabel(row.displayTitle)
        setAccessibilityValue(QuickAccessRowContent.detail(for: row, applicationName: applicationName))
    }
}

struct QuickAccessRowContent: View {
    let row: QuickAccessRow?
    let applicationName: String?

    private static let relativeDates: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func detail(for row: QuickAccessRow, applicationName: String?) -> String {
        [applicationName, relativeDates.localizedString(for: row.date, relativeTo: Date())]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        if let row {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: row.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayTitle).lineLimit(1)
                    if let snippet = row.snippet {
                        Text(Self.highlighted(snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(Self.detail(for: row, applicationName: applicationName))
                        if row.savedAsMemo { Badge("Saved as Memo") }
                        if row.isPartiallyIndexed { Badge("Partially indexed") }
                        if row.isTextUnavailable { Badge("Text unavailable") }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
    }

    private static func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.text)
        let length = snippet.text.utf16.count
        for range in snippet.highlights where range.lowerBound >= 0 && range.upperBound <= length {
            let lower = String.Index(utf16Offset: range.lowerBound, in: snippet.text)
            let upper = String.Index(utf16Offset: range.upperBound, in: snippet.text)
            guard let start = AttributedString.Index(lower, within: attributed),
                  let end = AttributedString.Index(upper, within: attributed), start < end else { continue }
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}

private struct Badge: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .padding(.horizontal, 5)
            .background(Capsule().fill(.quaternary))
    }
}

extension QuickAccessRow {
    var displayTitle: String { title.isEmpty ? "Clipboard Item" : title }
}

extension ContentKind {
    var symbolName: String {
        switch self {
        case .text: "doc.text"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .other: "square.dashed"
        }
    }
}

/// Display names for source apps, looked up once per bundle identifier.
@MainActor
final class ApplicationNames {
    private var names: [String: String?] = [:]

    func name(for bundleIdentifier: String) -> String? {
        if let cached = names[bundleIdentifier] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { url in
            let display = FileManager.default.displayName(atPath: url.path)
            return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        names[bundleIdentifier] = name
        return name
    }
}
