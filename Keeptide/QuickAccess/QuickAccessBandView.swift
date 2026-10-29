import AppKit
import SwiftUI

/// The quick access band, backed as the app switcher is: the system's material in a rounded rectangle with a hairline
/// edge and a soft shadow. Along its top the toolbar, below it the strip of clips, which the band's rounded edge cuts
/// off where it goes on beyond either end; and the preview card above it while the preview is open. The panel owns
/// the AppKit views placed in it, keeps them up to date and lays the band out; the band reads the rest from the state.
struct QuickAccessBandView: View {
    /// What the band is laid out by. The panel sets it together with its own frame, so the two always agree.
    struct Layout: Equatable {
        var metrics: StripMetrics
        /// The preview card's size while the preview is open.
        var previewSize: CGSize?
        /// From the band's top edge up to the card's bottom edge: less than nothing where the card lies over the band.
        var previewGap = StripLayout.previewGap
        /// How far the band's bottom edge is above the panel's: the room its shadow has there.
        var roomBelow: CGFloat
    }

    struct Actions {
        /// Keys pressed in the preview's text.
        let previewCommand: (QuickAccessCommand) -> Void
    }

    let layout: Layout
    let state: QuickAccessState
    let toolbar: QuickAccessToolbar
    let strip: QuickAccessStripView
    let applicationNames: ApplicationNames
    let actions: Actions

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// The selected clip's ring is drawn outside its frame, so the strip reaches this far above and below the cards.
    private static let ringRoom: CGFloat = 8

    private var metrics: StripMetrics { layout.metrics }
    private var hasFrames: Bool { !state.selection.rows.isEmpty }
    private var selectedRow: QuickAccessRow? {
        state.selection.selection.flatMap { selected in state.selection.rows.first { $0.ref == selected } }
    }

    var body: some View {
        VStack(spacing: layout.previewGap) {
            if let size = layout.previewSize {
                // Over the band's shadow, which reaches up toward the card, and over the band itself on a low screen.
                previewCard.frame(width: size.width, height: size.height).zIndex(1)
            }
            band
        }
        .padding(.bottom, layout.roomBelow)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: Band

    private var band: some View {
        VStack(spacing: 0) {
            HostedView(view: toolbar)
                .frame(width: metrics.bandWidth, height: QuickAccessToolbar.height)
                .padding(.top, StripLayout.toolbarTop - QuickAccessToolbar.focusRoom)
            stripRow
                .padding(.top, StripLayout.toolbarGap - QuickAccessToolbar.focusRoom - Self.ringRoom)
            Spacer(minLength: 0)
        }
        .frame(width: metrics.bandWidth, height: StripLayout.bandHeight(metrics), alignment: .top)
        .overlay(alignment: .bottom) { rebuildNotice }
        // The band's edge is clear: cards that go on beyond it are cut off there.
        .clipShape(RoundedRectangle(cornerRadius: StripLayout.cornerRadius, style: .continuous))
        .background {
            BandBackdrop(reducesTransparency: reduceTransparency, increasesContrast: contrast == .increased)
                .padding(EdgeInsets(top: -StripLayout.shadowRoom.above, leading: -StripLayout.sideMargin,
                                    bottom: -StripLayout.shadowRoom.below, trailing: -StripLayout.sideMargin))
        }
    }

    private var stripRow: some View {
        ZStack {
            HostedView(view: strip)
                .frame(width: metrics.bandWidth, height: metrics.frameSize.height + 2 * Self.ringRoom)
            if !hasFrames { emptyState }
        }
    }

    /// Under the clips while the index rebuilds, so that the toolbar keeps Return's hint; with no clips the empty state
    /// says it instead. Its line stands 1.5 pt above the band's edge, which sets its letters midway between that edge
    /// and the ring of a selected card above them, about 2 pt from each.
    @ViewBuilder
    private var rebuildNotice: some View {
        if hasFrames, state.indexNotice == .rebuilding {
            Text(QuickAccessStatus.rebuilding)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 1.5)
                .allowsHitTesting(false)
                .accessibilityIdentifier("QuickAccessIndexNotice")
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
                // The toolbar's status is QuickAccessStatus; this is the card area's own.
                Text(message.text).font(.system(size: 15)).accessibilityIdentifier("QuickAccessEmptyState")
                if let detail = message.detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
        }
    }

    // MARK: Preview

    /// An opaque card over the band, with the selected clip in full.
    private var previewCard: some View {
        QuickAccessPreviewView(preview: state.preview,
                               applicationName: selectedRow?.sourceApp.flatMap(applicationNames.name(for:)),
                               onCommand: actions.previewCommand)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
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
    let reducesTransparency: Bool
    let increasesContrast: Bool

    func makeNSView(context: Context) -> QuickAccessBandBackdrop { QuickAccessBandBackdrop() }

    func updateNSView(_ backdrop: QuickAccessBandBackdrop, context: Context) {
        backdrop.reducesTransparency = reducesTransparency
        backdrop.increasesContrast = increasesContrast
    }
}

/// What the band stands on, as the app switcher does: the system's material, blurring what lies behind the window, in
/// a rounded rectangle with a hairline edge, and a soft shadow around it, never under it. With Reduce Transparency the
/// band is solid, and with Increase Contrast its edge is 1 pt and stronger. The view reaches beyond the band by the
/// room the panel leaves around it, where the shadow falls; it takes no clicks.
@MainActor
final class QuickAccessBandBackdrop: NSView {
    /// How far the view reaches beyond the band on each side.
    static let reach = NSEdgeInsets(top: StripLayout.shadowRoom.above, left: StripLayout.sideMargin,
                                    bottom: StripLayout.shadowRoom.below, right: StripLayout.sideMargin)

    let material = NSVisualEffectView()
    /// The solid fill under Reduce Transparency, and the edge.
    let surface = QuickAccessBandSurface()
    var reducesTransparency = false {
        didSet { if reducesTransparency != oldValue { restyle() } }
    }
    var increasesContrast = false {
        didSet { if increasesContrast != oldValue { restyle() } }
    }
    private var maskedSize = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)
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
        material.frame = band
        surface.frame = band
        if band.size != maskedSize {
            maskedSize = band.size
            // AppKit may draw the mask away from the main thread, so its handler touches nothing of the view's.
            material.maskImage = NSImage(size: band.size, flipped: false) { @Sendable rect in
                NSColor.black.setFill()
                NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: rect)).fill()
                return true
            }
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func restyle() {
        // A dark HUD's material in dark mode, a popover's light one in light mode.
        material.material = isDark ? .hudWindow : .popover
        material.isHidden = reducesTransparency
        surface.isSolid = reducesTransparency
        surface.increasesContrast = increasesContrast
        surface.needsDisplay = true
        needsDisplay = true
    }

    /// The shadow: 30 pt down and 90 pt soft, black at 55 percent in dark mode; 80 pt soft and a faint blue-grey at 22
    /// percent in light mode. It is drawn only outside the band, so none of it shows through the material.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let band = Self.outline(in: bandRect)
        context.saveGState()
        defer { context.restoreGState() }
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
    }
}

/// The band's edge, a hairline inside it in white at 16 percent in dark mode and black at 10 percent in light mode, 1 pt
/// and stronger with Increase Contrast; and, when the band is solid, its fill: #1E1E20 in dark mode, #F6F6F8 in light.
@MainActor
final class QuickAccessBandSurface: NSView {
    var isSolid = false {
        didSet { if isSolid != oldValue { needsDisplay = true } }
    }
    var increasesContrast = false {
        didSet { if increasesContrast != oldValue { needsDisplay = true } }
    }

    /// The edge's width.
    var edgeWidth: CGFloat { increasesContrast ? 1 : 0.5 }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isSolid {
            (isDark ? NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255, alpha: 1)
                : NSColor(srgbRed: 0xF6 / 255, green: 0xF6 / 255, blue: 0xF8 / 255, alpha: 1)).setFill()
            NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: bounds)).fill()
        }
        let width = edgeWidth
        let edge = NSBezierPath(cgPath: QuickAccessBandBackdrop.outline(in: bounds.insetBy(dx: width / 2, dy: width / 2)))
        edge.lineWidth = width
        (isDark ? NSColor(white: 1, alpha: increasesContrast ? 0.4 : 0.16)
            : NSColor(white: 0, alpha: increasesContrast ? 0.3 : 0.1)).setStroke()
        edge.stroke()
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
