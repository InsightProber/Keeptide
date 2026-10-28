import AppKit
import SwiftUI

/// The quick access band: a glass bar whose ends fade away, holding from the top the search row, the filter
/// row while it shows, the strip of clips and the caption for the clip in the middle. Faint ← and → hints sit
/// beside it, and the preview card above it while the preview is open. The panel owns the AppKit views placed
/// in it, keeps them up to date and lays the band out; the band reads the rest from the state.
struct QuickAccessBandView: View {
    /// What the band is laid out by. The panel sets it together with its own frame, so the two always agree.
    struct Layout: Equatable {
        var metrics: StripMetrics
        var filtersVisible: Bool
        /// The preview card's size while the preview is open.
        var previewSize: CGSize?
    }

    struct Actions {
        let copy: () -> Void
        let toggleFilters: () -> Void
        /// Keys pressed in the preview's text.
        let previewCommand: (QuickAccessCommand) -> Void
    }

    let layout: Layout
    let state: QuickAccessState
    let searchField: QuickAccessSearchField
    let filterRow: QuickAccessFilterRow
    let strip: QuickAccessStripView
    let applicationNames: ApplicationNames
    let actions: Actions

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The selected clip's ring is drawn outside its frame, so the strip reaches this far into the rows above
    /// and below it.
    private static let ringRoom: CGFloat = 8

    private var metrics: StripMetrics { layout.metrics }
    private var bandHeight: CGFloat { StripLayout.bandHeight(metrics, filtersVisible: layout.filtersVisible) }
    /// Text and controls keep clear of the faded ends.
    private var fadeInset: CGFloat { metrics.bandWidth * StripLayout.fade }
    private var hasFrames: Bool { !state.selection.rows.isEmpty }
    private var centredRow: QuickAccessRow? {
        state.selection.selection.flatMap { selected in state.selection.rows.first { $0.ref == selected } }
    }

    var body: some View {
        VStack(spacing: StripLayout.previewGap) {
            if let size = layout.previewSize {
                previewCard.frame(width: size.width, height: size.height)
            }
            HStack(spacing: 0) {
                keyHint("←")
                band
                keyHint("→")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Band

    private var band: some View {
        let shape = RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            searchRow.frame(height: StripLayout.searchHeight)
            // The row stays in place while hidden, so it can take the keys the moment it shows.
            HostedView(view: filterRow).frame(height: layout.filtersVisible ? StripLayout.filterHeight : 0)
            stripRow.frame(height: metrics.frameSize.height)
            captionRow.frame(height: StripLayout.captionHeight)
        }
        .frame(width: metrics.bandWidth, height: bandHeight)
        .background {
            // With Reduce Transparency the bar is solid.
            if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) }
        }
        .glassEffect(reduceTransparency ? .identity : .regular, in: shape)
        // Both ends fade out, the bar and everything on it alike, so the clips beyond them leave no edge.
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: StripLayout.fade),
                .init(color: .black, location: 1 - StripLayout.fade), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }

    private var searchRow: some View {
        ZStack {
            SearchField(field: searchField).frame(maxWidth: 560)
            HStack {
                Spacer(minLength: 0)
                filterButton
            }
        }
        .padding(.horizontal, fadeInset)
    }

    /// Shows or hides the filter row. While a query or a filter holds the row up it cannot hide it; it keeps
    /// its shown look then.
    private var filterButton: some View {
        let title = state.filtersVisible ? "Hide filters" : "Show filters"
        return Button(action: actions.toggleFilters) {
            Image(systemName: state.kinds.isEmpty ? "line.3.horizontal.decrease.circle"
                                                  : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 18))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(state.filtersVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("QuickAccessFilterButton")
    }

    private var stripRow: some View {
        ZStack {
            HostedView(view: strip)
                .frame(width: metrics.bandWidth, height: metrics.frameSize.height + 2 * Self.ringRoom)
            if !hasFrames { emptyState }
        }
    }

    /// In place of the clips when there are none: the library is empty or closed, or a search found nothing yet.
    @ViewBuilder
    private var emptyState: some View {
        let message = QuickAccessStatus.empty(phase: state.phase, notice: state.indexNotice)
        if state.phase == .noContent || state.phase == .libraryUnavailable {
            VStack(spacing: 6) {
                Text(message.text).font(.system(size: 15))
                if let detail = message.detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("QuickAccessEmptyState")
        } else {
            VStack(spacing: 6) {
                Text(message.text).font(.system(size: 15)).accessibilityIdentifier("QuickAccessStatus")
                if let detail = message.detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
        }
    }

    // MARK: Caption

    /// What the centred clip is and a way to copy it with the pointer. A refused copy's reason, or else a
    /// status, takes the place of the clip's source; the reason answers what was just done, so it comes first.
    private var captionRow: some View {
        HStack(spacing: 14) {
            captionText
            if state.selection.selection != nil { copyButton }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, fadeInset)
    }

    @ViewBuilder
    private var captionText: some View {
        if let failure = state.failure {
            Text(failure.message).foregroundStyle(Color(nsColor: .systemRed)).accessibilityIdentifier("QuickAccessFailure")
        } else if let status = statusLine {
            Text(status).foregroundStyle(.secondary).accessibilityIdentifier("QuickAccessStatus")
        } else if let row = centredRow {
            HStack(spacing: 6) {
                Image(nsImage: applicationNames.icon(for: row.sourceApp))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(QuickAccessRowContent.detail(for: row, applicationName: row.sourceApp.flatMap(applicationNames.name(for:))))
            }
        }
    }

    /// The line over clips that are on screen; with none, the empty state says it.
    private var statusLine: String? {
        guard hasFrames else { return nil }
        return QuickAccessStatus.line(selectionLost: state.selection.selectionLost, phase: state.phase,
                                      isComplete: state.selection.isComplete, notice: state.indexNotice)
    }

    private var copyButton: some View {
        Button(action: actions.copy) {
            HStack(spacing: 6) {
                Keycap(symbol: "⏎")
                Text("Copy")
            }
        }
        .buttonStyle(.borderless)
        .disabled(state.selection.executableSelection == nil)
        .accessibilityLabel("Copy")
        .accessibilityIdentifier("QuickAccessCopyButton")
    }

    /// A faint ← or → beside the band, level with the clips. Only a hint: it takes no clicks, is not read, and
    /// goes when there are no clips.
    private func keyHint(_ symbol: String) -> some View {
        let middle = StripLayout.searchHeight + (layout.filtersVisible ? StripLayout.filterHeight : 0)
            + metrics.frameSize.height / 2
        return Color.clear
            .frame(width: StripLayout.sideMargin, height: bandHeight)
            .overlay(alignment: .top) {
                if hasFrames {
                    Keycap(symbol: symbol)
                        .foregroundStyle(.tertiary)
                        .offset(y: middle - Keycap.side / 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Preview

    /// An opaque card over the band, with the selected clip in full.
    private var previewCard: some View {
        QuickAccessPreviewView(preview: state.preview,
                               applicationName: centredRow?.sourceApp.flatMap(applicationNames.name(for:)),
                               onCommand: actions.previewCommand)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }
}

/// A key drawn as a small cap: Return before Copy, and the arrow hints beside the band.
private struct Keycap: View {
    static let side: CGFloat = 20
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: Self.side, minHeight: Self.side)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.foreground.opacity(0.5), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// Places one of the panel's AppKit views in the band. The panel keeps the view up to date itself.
private struct HostedView<Content: NSView>: NSViewRepresentable {
    let view: Content
    func makeNSView(context: Context) -> Content { view }
    func updateNSView(_ nsView: Content, context: Context) {}
}

/// The filter row: All, Text, Links, Images and Files, where All clears the filters. A click chooses directly.
/// With the keys the row itself takes focus: ← and → move a cursor along the choices, ringed as focus, and
/// Space chooses the one under it.
@MainActor
final class QuickAccessFilterRow: NSView {
    /// The choices in order; nil is All.
    static let choices: [ContentKind?] = [nil] + ContentKind.filters

    var onCommand: ((QuickAccessCommand) -> Void)?
    /// A choice was clicked; its index in `choices`.
    var onChoose: ((Int) -> Void)?
    /// What a key means here depends on the rest of the panel, which keeps this current.
    var queryIsEmpty = true
    /// The choice ← and → move and Space chooses.
    var cursor = 0 {
        didSet { noteFocusRingMaskChanged() }
    }
    private let buttons: [NSButton]

    override init(frame frameRect: NSRect) {
        buttons = Self.choices.map { NSButton(title: $0?.filterTitle ?? "All", target: nil, action: nil) }
        super.init(frame: frameRect)
        for (index, button) in buttons.enumerated() {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .accessoryBar
            // Clicking a choice leaves the keys where they are.
            button.refusesFirstResponder = true
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Filter by type")
        setAccessibilityIdentifier("QuickAccessFilters")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Marks the filters that are on, or All when none is.
    func show(kinds: Set<ContentKind>) {
        for (button, kind) in zip(buttons, Self.choices) {
            button.state = (kind.map(kinds.contains) ?? kinds.isEmpty) ? .on : .off
        }
    }

    /// The cursor stops at either end.
    func moveCursor(by offset: Int) {
        cursor = min(max(cursor + offset, 0), buttons.count - 1)
    }

    @objc private func choose(_ sender: NSButton) {
        cursor = sender.tag
        onChoose?(sender.tag)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: QuickAccessStripView.key(for: event), shift: event.modifierFlags.contains(.shift), focus: .filters,
            queryIsEmpty: queryIsEmpty, filtersVisible: true
        ))
        // A key with no meaning here is dropped, not passed on to end in the alert sound.
        guard command != .passThrough else { return }
        onCommand?(command)
    }

    // The focus ring goes around the choice under the cursor, not around the whole row.

    override var focusRingMaskBounds: NSRect { cursorFrame }

    override func drawFocusRingMask() {
        let frame = cursorFrame
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
    }

    private var cursorFrame: NSRect {
        convert(buttons[cursor].bounds, from: buttons[cursor])
    }
}

extension PasteRefusal {
    var message: String {
        switch self {
        case .stale: "The results changed. Select the item again."
        case .contentUnavailable: "This item changed or is no longer available."
        case .noPlainText: "This item has no plain text."
        case .writeFailed: "Couldn't write to the clipboard."
        }
    }
}
