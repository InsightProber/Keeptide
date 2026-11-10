import AppKit
import SwiftUI

/// The quick access band: an opaque tray in a rounded rectangle with a hairline edge and a soft shadow, and on it a soft
/// light behind the selected card. Along its top the toolbar, below it the strip of clips, which the band's rounded edge
/// cuts off where it goes on beyond either end, with the strip's section icons below the cards. A browsing preview
/// floats over the band; a command review stands above it. The panel owns the AppKit views placed in it, keeps them up
/// to date and lays the band out; the band reads the rest from the state.
struct QuickAccessBandView: View {
    /// What the band is laid out by. The panel sets it together with its own frame, so the two always agree.
    struct Layout: Equatable {
        var metrics: StripMetrics
        /// The card's size while the preview or a command review is open.
        var previewSize: CGSize?
        /// From the band's top edge up to the card's bottom edge: less than nothing where the card lies over the band.
        var previewGap = StripLayout.previewGap
        /// How far the band's bottom edge is above the panel's: the room its shadow has there.
        var roomBelow: CGFloat
    }

    struct Actions {
        /// Keys pressed in the preview's text, or the review's.
        let previewCommand: (QuickAccessCommand) -> Void
        /// The review card's buttons.
        let confirmCommand: () -> Void
        let cancelCommandReview: () -> Void
        /// Copies text the preview shows, such as part of the text recognized in an image, as the panel copies it.
        let copyText: (String) -> Void
    }

    let layout: Layout
    let state: QuickAccessState
    let toolbar: QuickAccessToolbar
    let strip: QuickAccessStripView
    /// The light behind the selected card, which the panel keeps where the card rests.
    let glow: QuickAccessGlowView
    let applicationNames: ApplicationNames
    let actions: Actions

    @Environment(\.colorSchemeContrast) private var contrast

    private var metrics: StripMetrics { layout.metrics }
    /// The strip reaches this far above and below the cards: as far as the enlarged selected card reaches past them,
    /// and 8 pt more for the ring drawn outside it.
    private var ringRoom: CGFloat { metrics.selectionGrowth + 8 }
    private var hasFrames: Bool { !state.selection.rows.isEmpty }
    private var selectedRow: QuickAccessRow? { state.selection.selectedRow }

    var body: some View {
        ZStack(alignment: .bottom) {
            band.padding(.bottom, layout.roomBelow)
            if let size = layout.previewSize {
                card.frame(width: size.width, height: size.height)
                    .offset(y: -(layout.roomBelow + StripLayout.bandHeight(metrics) + layout.previewGap))
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: Band

    private var band: some View {
        VStack(spacing: 0) {
            HostedView(view: toolbar)
                .frame(width: metrics.bandWidth, height: QuickAccessToolbar.height)
                .padding(.top, StripLayout.toolbarTop - QuickAccessToolbar.focusRoom)
            stripRow
                .padding(.top, metrics.toolbarGap - QuickAccessToolbar.focusRoom - ringRoom)
            Spacer(minLength: 0)
        }
        .frame(width: metrics.bandWidth, height: StripLayout.bandHeight(metrics), alignment: .top)
        // The strip places its section icons in the room below the cards. Their view takes no clicks, so the strip and
        // the band beneath keep the pointer there, and VoiceOver does not read them; each icon's help tag still shows.
        .overlay(alignment: .bottom) {
            HostedView(view: strip.sectionLabels)
                .frame(width: metrics.bandWidth, height: metrics.bottomPadding)
                .accessibilityHidden(true)
        }
        // The light lies on the tray, under the toolbar and the cards, and the band's edge cuts it off as it does them.
        .background {
            HostedView(view: glow)
                .frame(width: metrics.bandWidth, height: StripLayout.bandHeight(metrics))
                .accessibilityHidden(true)
        }
        // The band's edge is clear: cards that go on beyond it are cut off there.
        .clipShape(RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous))
        .background {
            BandBackdrop(layout: layout, increasesContrast: contrast == .increased)
                .padding(EdgeInsets(top: -StripLayout.shadowRoom.above, leading: -StripLayout.sideMargin,
                                    bottom: -StripLayout.shadowRoom.below, trailing: -StripLayout.sideMargin))
        }
    }

    private var stripRow: some View {
        ZStack {
            HostedView(view: strip)
                .frame(width: metrics.bandWidth, height: metrics.frameSize.height + 2 * ringRoom)
            if !hasFrames { emptyState }
        }
    }

    /// In place of the clips when there are none: the library is empty or closed, or a search found nothing yet.
    @ViewBuilder
    private var emptyState: some View {
        let message = QuickAccessStatus.empty(phase: state.phase, notice: state.indexNotice, list: state.list,
                                              favoritesOnly: state.favoritesOnly, collectionName: state.collectionName)
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
                // The toolbar's status is QuickAccessStatus; this is the card area's own.
                Text(message.text).font(.system(size: 15)).accessibilityIdentifier("QuickAccessEmptyState")
                if let detail = message.detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
        }
    }

    // MARK: Card

    /// An opaque card over the band: a command's review while one waits, otherwise the selected clip in full. The
    /// preview is one card, plain or split, whose bar and content change inside it as the column opens and closes and
    /// the selection moves, so it never appears again and its controls keep VoiceOver's focus.
    private var card: some View {
        Group {
            if let review = state.commandReview {
                CommandReviewView(review: review, confirmTitle: QuickAccessActions.confirmTitle(for: review),
                                  onConfirm: actions.confirmCommand, onCancel: actions.cancelCommandReview,
                                  onCommand: actions.previewCommand)
                    .clipShape(RoundedRectangle(cornerRadius: CommandReviewView.cornerRadius, style: .continuous))
            } else {
                // Escape closes the split preview's column before the preview.
                QuickAccessPreviewCard(closeHelp: state.isPreviewSplit ? "Close Preview" : "Close Preview (Esc)",
                                       onClose: { actions.previewCommand(.togglePreview) }) {
                    previewBar
                } content: {
                    previewContent
                }
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    /// What the preview's bar holds after the close button: Preview | Text for an image, and while its text shows,
    /// Stop or Keep Line Breaks at the end. While the preview is split, the segments stay for a clip without text in
    /// an image too, with Text chosen and dimmed, and Preview leaves the split.
    @ViewBuilder
    private var previewBar: some View {
        if state.offersTextInImage || state.isPreviewSplit {
            previewSegments(textChosen: state.isPreviewSplit, textEnabled: state.offersTextInImage)
        } else {
            Text("Preview")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: ToolbarPalette.secondary))
        }
        Spacer()
        if let column = state.textColumn {
            if column.isRecognizing {
                Button { actions.previewCommand(.stopTextRecognition) } label: {
                    HStack(spacing: 6) {
                        Text("Stop")
                        ReviewKeycap(symbol: "⌘.")
                    }
                }
                .buttonStyle(TrayCapsuleButtonStyle())
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("QuickAccessStopTextRecognition")
                .help("Stop Recognizing (⌘.)")
            } else {
                keepLineBreaks
            }
            textButtons(enabled: state.textColumnText != nil)
        }
    }

    /// Copy and Save as Snippet for the text beside an image, dimmed until there is text. After a copy, "Copied" shows
    /// beside Copy for a moment.
    private func textButtons(enabled: Bool) -> some View {
        HStack(spacing: 8) {
            if state.isTextCopied {
                Text("Copied")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: ToolbarPalette.secondary))
                    .accessibilityIdentifier("QuickAccessTextCopied")
            }
            TrayRoundButton(symbol: "doc.on.doc", label: "Copy Text", help: "Copy Text (⌘C)",
                            identifier: "QuickAccessCopyText") { actions.previewCommand(.copyText) }
            TrayRoundButton(symbol: "bookmark", label: "Save Text as Snippet", help: "Save Text as Snippet (⌘S)",
                            identifier: "QuickAccessSaveText") { actions.previewCommand(.saveTextAsSnippet) }
        }
        .disabled(!enabled)
    }

    /// On, with a check mark, while the text shown keeps the image's line breaks; without text, as the person chose.
    private var keepLineBreaks: some View {
        let isOn = state.isKeepLineBreaksOn
        return Button { actions.previewCommand(.toggleKeepLineBreaks) } label: {
            HStack(spacing: 5) {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text("Keep Line Breaks")
            }
        }
        .buttonStyle(TrayCapsuleButtonStyle(isOn: isOn))
        .accessibilityLabel("Keep Line Breaks")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("QuickAccessKeepLineBreaks")
        .help(isOn ? "Join the Lines into Paragraphs" : "Keep the Image's Line Breaks")
    }

    /// The selected clip in full, with the text in an image beside it while the preview is split.
    @ViewBuilder
    private var previewContent: some View {
        let applicationName = selectedRow?.sourceApp.flatMap(applicationNames.name(for:))
        if let ref = state.textColumnRef, let column = state.textColumn {
            QuickAccessSplitPreview(preview: state.preview, applicationName: applicationName, column: column, ref: ref,
                                    isJustMade: state.isTextColumnJustMade, onCommand: actions.previewCommand,
                                    onCopy: actions.copyText)
        } else {
            QuickAccessPreviewView(preview: state.preview,
                                   applicationName: applicationName,
                                   onCommand: actions.previewCommand,
                                   fileAccessStore: state.fileAccessStore,
                                   fileAccessIdentity: state.fileAccessIdentity,
                                   isLoadingOriginal: state.isLoadingOriginalPreview,
                                   previewMessage: state.previewMessage,
                                   onRequestOriginal: state.loadOriginalPreview,
                                   isOnTray: true)
                // In the split card, no wider than the plain preview, so text keeps lines it can be read in.
                .frame(maxWidth: state.isPreviewSplit ? StripLayout.previewMaximum.width : .infinity)
        }
    }

    /// Preview | Text: Text shows the text in an image beside it, and Preview leaves the split.
    private func previewSegments(textChosen: Bool, textEnabled: Bool) -> some View {
        TraySegments(segments: [
            .init(id: "Preview", title: "Preview", isChosen: !textChosen,
                  help: textChosen ? "Preview Alone (Esc)" : nil) {
                if textChosen { actions.previewCommand(.closeResultColumn) }
            },
            .init(id: "Text", title: "Text", isChosen: textChosen, isEnabled: textEnabled,
                  help: textEnabled ? "\(TextColumnWords.title) (⇧⌘T)" : "\(TextColumnWords.title), for an image") {
                if !textChosen { actions.previewCommand(.showTextInImage) }
            },
        ])
    }
}

/// A window-like surface inside the same nonactivating panel, so previewing never changes the paste target. It stands
/// on a tray like the band's, in one piece with no surface of its own for the content, under a bar laid out like the
/// band's toolbar.
private struct QuickAccessPreviewCard<Bar: View, Content: View>: View {
    /// The close button's help tag.
    let closeHelp: String
    let onClose: () -> Void
    /// What the bar holds after the close button.
    @ViewBuilder let bar: () -> Bar
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: ToolbarPalette.glyph))
                        .frame(width: QuickAccessSearchControl.foldedWidth, height: QuickAccessSearchControl.foldedWidth)
                        .background(Color(nsColor: ToolbarPalette.foldedSearchFill), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Preview")
                .accessibilityIdentifier("CloseQuickAccessPreview")
                .help(closeHelp)
                bar()
            }
            .frame(height: StripLayout.toolbarHeight)
            .padding(.top, StripLayout.toolbarTop)
            .padding(.horizontal, QuickAccessToolbar.leadingInset)
            content()
        }
        .background {
            ZStack {
                // The tray's colour as a shape of its own, under the tray's drawing: it takes the pointer on the
                // card's empty parts, so that a click there never reaches the band beneath the card, and the card's
                // shadow falls from it.
                RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: QuickAccessBandSurface.trayColor))
                PreviewTray(increasesContrast: contrast == .increased)
            }
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { appeared = true }
        }
    }
}

/// The band's tray, with its edge and highlight, behind the preview card.
private struct PreviewTray: NSViewRepresentable {
    let increasesContrast: Bool

    func makeNSView(context: Context) -> QuickAccessBandSurface { QuickAccessBandSurface() }

    func updateNSView(_ surface: QuickAccessBandSurface, context: Context) {
        surface.increasesContrast = increasesContrast
    }
}

/// Places one of the panel's AppKit views in the band. The panel keeps the view up to date itself.
private struct HostedView<Content: NSView>: NSViewRepresentable {
    let view: Content
    func makeNSView(context: Context) -> Content { view }
    func updateNSView(_ nsView: Content, context: Context) {}
}

/// Places the band's backdrop behind it, reaching into the room the panel leaves around the band for the shadow.
private struct BandBackdrop: NSViewRepresentable {
    let layout: QuickAccessBandView.Layout
    let increasesContrast: Bool

    func makeNSView(context: Context) -> QuickAccessBandBackdrop { QuickAccessBandBackdrop() }

    func updateNSView(_ backdrop: QuickAccessBandBackdrop, context: Context) {
        backdrop.panelLayout = layout
        backdrop.increasesContrast = increasesContrast
    }
}

/// What the band stands on: an opaque tray in a rounded rectangle, with a hairline edge and a highlight along its top,
/// and a soft shadow around it, never under it. Nothing behind the window shows through it, so Reduce Transparency
/// changes nothing; with Increase Contrast the edge is stronger. The view reaches beyond the band by the room the panel
/// leaves around it, where the shadow falls; it takes no clicks.
@MainActor
final class QuickAccessBandBackdrop: NSView {
    /// How far the view reaches beyond the band on each side.
    static let reach = NSEdgeInsets(top: StripLayout.shadowRoom.above, left: StripLayout.sideMargin,
                                    bottom: StripLayout.shadowRoom.below, right: StripLayout.sideMargin)

    /// The tray, its edge and its highlight.
    let surface = QuickAccessBandSurface()
    var increasesContrast = false {
        didSet { if increasesContrast != oldValue { restyle() } }
    }
    private var drawnSize = NSSize.zero
    /// The shadow fades out over this much inside the window's edges. Its soft edge reaches farther than the room the
    /// panel leaves it, 40 points above the band, 100 below and 32 beside it, and less on a low screen; cut short where
    /// the window ends, it would show as a faint band with a hard edge.
    static let shadowFade: CGFloat = 24
    /// The part of the view the window shows, where the shadow is drawn to, as it was last drawn.
    private(set) var drawnShadowArea = NSRect.zero
    /// How the panel lays the band out. As the preview or a command's review opens and closes, the band moves in the
    /// window and the window grows or shrinks around it, while the view keeps its size, so AppKit does not lay it out
    /// again; the shadow is drawn again to end where the window now does.
    var panelLayout: QuickAccessBandView.Layout? {
        didSet { if panelLayout != oldValue { needsDisplay = true } }
    }

    /// The part of the view the window shows: all of it where the panel leaves the shadow its whole room, and less
    /// where the edge of a low screen leaves the window short of it.
    var shadowArea: NSRect {
        guard let content = window?.contentView else { return bounds }
        let shown = bounds.intersection(convert(content.bounds, from: content))
        return shown.isEmpty ? bounds : shown
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(surface)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The band within the view.
    var bandRect: NSRect {
        let reach = Self.reach
        return NSRect(x: reach.left, y: reach.bottom, width: max(0, bounds.width - reach.left - reach.right),
                      height: max(0, bounds.height - reach.top - reach.bottom))
    }

    /// The band's outline in `rect`, with continuous corners as the content's clip has them. It only builds a path,
    /// so it may be called from any thread.
    nonisolated static func outline(in rect: NSRect) -> CGPath {
        RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous).path(in: rect).cgPath
    }

    override func layout() {
        super.layout()
        let band = bandRect
        surface.frame = band
        if band.size != drawnSize {
            drawnSize = band.size
            needsDisplay = true
        }
        // The window's edges may lie elsewhere in the view at its new size, and the shadow ends with them.
        if shadowArea != drawnShadowArea { needsDisplay = true }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize),
                                               name: NSWindow.didResizeNotification, object: window)
    }

    /// The window grows and shrinks around the band, which need not lay the view out again, and the shadow ends with
    /// the window.
    @objc private func windowDidResize(_ notification: Notification) {
        if shadowArea != drawnShadowArea { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func restyle() {
        surface.increasesContrast = increasesContrast
        surface.needsDisplay = true
        needsDisplay = true
    }

    /// The shadow: 30 pt down and 90 pt soft, black at 55 percent in dark mode; 80 pt soft and a faint blue-grey at 22
    /// percent in light mode. It is drawn only outside the band, where the tray does not cover it, and it fades out over
    /// `shadowFade` inside the window's edges, so it never ends in a hard edge where the window does.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let band = Self.outline(in: bandRect)
        let area = shadowArea
        drawnShadowArea = area
        context.saveGState()
        defer { context.restoreGState() }
        context.beginTransparencyLayer(in: area, auxiliaryInfo: nil)
        context.saveGState()
        context.addRect(bounds)
        context.addPath(band)
        context.clip(using: .evenOdd)
        // A shadow's offset and blur are taken in the context's device units, which no transform reaches: on a Retina
        // screen a point is two of them, and drawing into a picture may turn them upside down. So the design's 30
        // points down this view's own way, and its blur, are carried into those units by hand.
        let offset = context.convertToDeviceSpace(CGSize(width: 0, height: isFlipped ? 30 : -30))
        let blur = abs(context.convertToDeviceSpace(CGSize(width: isDark ? 90 : 80, height: 0)).width)
        context.setShadow(offset: offset, blur: blur,
                          color: isDark ? CGColor(gray: 0, alpha: 0.55)
                              : CGColor(srgbRed: 30 / 255, green: 30 / 255, blue: 40 / 255, alpha: 0.22))
        context.addPath(band)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
        Self.fadeEdges(of: area, in: context)
        context.endTransparencyLayer()
    }

    /// Keeps what is drawn in `area` at full strength `shadowFade` in from its edges, and fades it to nothing at them:
    /// one ramp across, one down, each keeping only as much of what lies under it as its own opacity.
    private static func fadeEdges(of area: NSRect, in context: CGContext) {
        guard area.width > 0, area.height > 0 else { return }
        let gray = CGColorSpaceCreateDeviceGray()
        func ramp(_ length: CGFloat) -> CGGradient? {
            let inset = min(shadowFade, length / 2) / length
            // Gray and opacity: none at the edges, all of it `inset` in from them.
            return CGGradient(colorSpace: gray, colorComponents: [0, 0, 0, 1, 0, 1, 0, 0],
                              locations: [0, inset, 1 - inset, 1], count: 4)
        }
        guard let across = ramp(area.width), let down = ramp(area.height) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.destinationIn)
        let beyond: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        context.drawLinearGradient(across, start: CGPoint(x: area.minX, y: area.midY),
                                   end: CGPoint(x: area.maxX, y: area.midY), options: beyond)
        context.drawLinearGradient(down, start: CGPoint(x: area.midX, y: area.minY),
                                   end: CGPoint(x: area.midX, y: area.maxY), options: beyond)
    }
}

/// The tray: #121316 in dark mode, #F3F3F1 in light mode. Along its top, inside it, a 1 pt highlight, white at 9
/// percent in dark mode and white in light mode; and around it, inside its edge, a 1 pt hairline, white at 7 percent in
/// dark mode and black at 6 percent in light mode, or with Increase Contrast white at 20 and black at 18.
@MainActor
final class QuickAccessBandSurface: NSView {
    var increasesContrast = false {
        didSet { if increasesContrast != oldValue { needsDisplay = true } }
    }

    /// The edge's width.
    static let edgeWidth: CGFloat = 1

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The tray's colour in the appearance it is drawn in, for a view that is not drawn here. AppKit may ask for it
    /// on any thread.
    nonisolated static let trayColor = NSColor(name: nil) { appearance in
        fill(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// The tray's colour.
    nonisolated static func fill(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x16 / 255, alpha: 1)
            : NSColor(srgbRed: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF1 / 255, alpha: 1)
    }

    /// The hairline's colour.
    static func edge(dark: Bool, increasedContrast: Bool) -> NSColor {
        dark ? NSColor(white: 1, alpha: increasedContrast ? 0.2 : 0.07)
            : NSColor(white: 0, alpha: increasedContrast ? 0.18 : 0.06)
    }

    /// The highlight's colour.
    static func highlight(dark: Bool) -> NSColor {
        NSColor(white: 1, alpha: dark ? 0.09 : 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A band with no room has no outline to draw: an empty one has no point to start from.
        guard bounds.width > 0, bounds.height > 0 else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tray = NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: bounds))
        Self.fill(dark: isDark).setFill()
        tray.fill()
        // The highlight is the part of the tray that the tray moved 1 pt down does not cover: a line along the top
        // that thins out around the corners.
        NSGraphicsContext.saveGraphicsState()
        tray.addClip()
        let highlight = NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: bounds))
        let lowered = bounds.offsetBy(dx: 0, dy: isFlipped ? 1 : -1)
        highlight.append(NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: lowered)))
        highlight.windingRule = .evenOdd
        Self.highlight(dark: isDark).setFill()
        highlight.fill()
        NSGraphicsContext.restoreGraphicsState()
        let width = Self.edgeWidth
        let edge = NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: bounds.insetBy(dx: width / 2, dy: width / 2)))
        edge.lineWidth = width
        Self.edge(dark: isDark, increasedContrast: increasesContrast).setStroke()
        edge.stroke()
    }
}

/// The soft light behind the selected card, in the card's accent, the colour that washes in from its top: where it
/// lies and how large it is.
struct QuickAccessGlow: Equatable {
    /// The row whose card the light is behind.
    let row: QuickAccessRow.ID
    let accent: CardAccent
    /// The light's middle, from the band's top left corner: the middle of the card where it rests.
    let center: CGPoint
    let size: CGSize

    /// The light behind a medium card. Behind a smaller or a larger card it is as much smaller or larger as the card.
    static let mediumSize = CGSize(width: 460, height: 500)

    /// The light behind `row`'s card, whose middle rests `cardMidX` from the band's left end, in its `accent`; nil for
    /// a card without one.
    static func make(row: QuickAccessRow, accent: CardAccent?, cardMidX: CGFloat,
                     metrics: StripMetrics) -> QuickAccessGlow? {
        guard let accent else { return nil }
        let scale = metrics.frameSize.width / StripLayout.cardDimensions(for: .medium).frame.width
        return QuickAccessGlow(
            row: row.id, accent: accent,
            center: CGPoint(x: cardMidX, y: StripLayout.cardTop(metrics) + metrics.frameSize.height / 2),
            size: CGSize(width: (mediumSize.width * scale).rounded(), height: (mediumSize.height * scale).rounded())
        )
    }

    /// How strong the light is at its middle: in dark mode 0.46 for a deep colour such as blue, down to 0.40 for one as
    /// light as yellow; in light mode 0.24, up to 0.34 for a light colour, which would hardly show on the light tray
    /// otherwise. Increase Contrast halves it.
    static func peakOpacity(of color: HeaderTint.RGB, dark: Bool, increasedContrast: Bool) -> CGFloat {
        let lightness = min(1, max(0, (HeaderTint.luminance(color) - 0.2) / 0.4))
        let peak = dark ? 0.46 - 0.06 * lightness : 0.24 + 0.10 * lightness
        return CGFloat(increasedContrast ? peak / 2 : peak)
    }

    /// The light's strength `t` of the way from its middle, 0, to its edge, 1, as a share of its peak: level at the
    /// middle and fading to nothing at the edge, as a blurred radial gradient does.
    static func falloff(_ t: CGFloat) -> CGFloat {
        (1 + cos(.pi * min(1, max(0, t)))) / 2
    }
}

/// Draws the soft light behind the selected card on the band, under the toolbar and the cards, cut off by the band's
/// edge. When the selection moves to another card the light there fades in as the last one fades out, over a fifth of
/// a second, or at once with Reduce Motion; when the card it is behind only moves, it moves with it. It takes no
/// clicks, and VoiceOver does not read it.
@MainActor
final class QuickAccessGlowView: NSView {
    static let fadeDuration: CFTimeInterval = 0.2

    /// The light shown, or nil while there is none.
    private(set) var glow: QuickAccessGlow?
    /// With Reduce Motion one light gives way to the next at once. Asked each time, since the setting can change while
    /// the app runs.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// With Increase Contrast the light is half as strong. Asked each time it is coloured, and again when the system's
    /// display options change.
    var increasesContrast: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// The two lights a crossfade passes between: the one shown, and the one going. One that has gone is hidden.
    private let lights = [QuickAccessGlowLight(), QuickAccessGlowLight()]
    private var shown = 0
    private let outline = CAShapeLayer()

    /// The light shown; nil while there is none.
    var shownLight: QuickAccessGlowLight? { glow == nil ? nil : lights[shown] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layer?.mask = outline
        for light in lights {
            light.isHidden = true
            addSubview(light)
        }
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { [] }

    /// Shows `glow`, or no light for nil. The light behind another row, or in another colour, takes over from the last
    /// one by a crossfade; the same light only moves.
    func show(_ glow: QuickAccessGlow?) {
        guard glow != self.glow else { return }
        let previous = self.glow
        self.glow = glow
        if let glow, let previous, glow.row == previous.row, glow.accent == previous.accent {
            place(lights[shown])
            return
        }
        let fades = window?.isVisible == true && !reducesMotion()
        fade(lights[shown], in: false, animated: fades)
        guard glow != nil else { return }
        shown = 1 - shown
        place(lights[shown])
        paint(lights[shown])
        fade(lights[shown], in: true, animated: fades)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = QuickAccessBandBackdrop.outline(in: bounds)
        CATransaction.commit()
        place(lights[shown])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(lights[shown])
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        paint(lights[shown])
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Puts `light` around the glow's middle, which is measured from the band's top.
    private func place(_ light: QuickAccessGlowLight) {
        guard let glow else { return }
        light.frame = NSRect(x: glow.center.x - glow.size.width / 2,
                             y: bounds.height - glow.center.y - glow.size.height / 2,
                             width: glow.size.width, height: glow.size.height)
    }

    /// Colours `light` in the card's accent as this appearance shows it, at its peak in the middle.
    private func paint(_ light: QuickAccessGlowLight) {
        guard let glow else { return }
        let color = glow.accent.rgb(in: effectiveAppearance)
        light.paint(color, peak: QuickAccessGlow.peakOpacity(of: color, dark: isDark,
                                                              increasedContrast: increasesContrast()))
    }

    /// Fades `light` in or out from wherever it is drawn now, or puts it there at once. One that has faded out is
    /// hidden.
    private func fade(_ light: QuickAccessGlowLight, in fadesIn: Bool, animated: Bool) {
        guard let layer = light.layer else { return }
        light.fades += 1
        let fade = light.fades
        let from = light.isHidden ? 0 : layer.presentation()?.opacity ?? layer.opacity
        let to: Float = fadesIn ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.removeAnimation(forKey: "glow.fade")
        layer.opacity = to
        light.isHidden = false
        guard animated, from != to else {
            light.isHidden = !fadesIn
            return
        }
        CATransaction.setCompletionBlock { [weak light] in
            MainActor.assumeIsolated {
                guard let light, light.fades == fade, !fadesIn else { return }
                light.isHidden = true
            }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "glow.fade")
    }
}

/// One light: an ellipse as large as the view, in one colour, strongest in the middle and fading to nothing at its edge.
@MainActor
final class QuickAccessGlowLight: NSView {
    /// How many steps the light's colours take from its middle to its edge.
    private static let steps = 12

    /// The colours from the middle out to the edge.
    private(set) var colors: [CGColor] = []
    /// Counts the fades, so that one which has been overtaken does not hide the light when it ends.
    fileprivate var fades = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    func paint(_ color: HeaderTint.RGB, peak: CGFloat) {
        let colors = (0...Self.steps).map { step in
            CGColor(srgbRed: color.red, green: color.green, blue: color.blue,
                    alpha: peak * QuickAccessGlow.falloff(CGFloat(step) / CGFloat(Self.steps)))
        }
        guard colors != self.colors else { return }
        self.colors = colors
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, colors.count > 1,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                        locations: (0...Self.steps).map { CGFloat($0) / CGFloat(Self.steps) })
        else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // A circle of radius 1 stretched to fill the view.
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: bounds.width / 2, y: bounds.height / 2)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                                   options: [])
    }
}

extension PasteRefusal {
    var message: String {
        switch self {
        case .stale: "The results changed. Select the item again."
        case .contentUnavailable: "This item changed or is no longer available."
        case .noPlainText: "This item has no plain text."
        case .writeFailed: "Couldn't write to the clipboard."
        case .commandTooLong: "Too long to review — use Copy As-Is in the ⌘K menu"
        case .terminalCannotTake: "A terminal can't take this item. Use Copy As-Is in the ⌘K menu."
        }
    }
}
