import AppKit
import SwiftUI

/// Shows text that a generation is writing, like a typewriter. It is an `NSTextView` that only ever appends: what is
/// shown can be selected and copied while more arrives, and appending never moves the selection. Text that is there
/// when the display first shows it, text that changes other than by growing, and all of it once a generation stops
/// appear at once; only text arriving while the display is on screen is typed out. A frame costs as much as the text
/// it adds, however long the text is. Copying goes to `onCopy`, never straight to the pasteboard.
@MainActor
final class StreamingTextDisplay: NSView {
    /// How the text is being produced.
    enum Mode: Equatable {
        /// A generation is writing it: new text is typed out, a caret marks the end, and the view follows the end.
        case writing
        /// The generation has finished: what is still waiting is typed out, then the caret goes.
        case finishing
        /// Nothing is being written, as for a saved result, a stopped generation or one still queued: everything
        /// shows at once.
        case still

        init(_ phase: GenerationSnapshot.Phase) {
            switch phase {
            case .waiting, .streaming: self = .writing
            case .finished: self = .finishing
            case .queued, .stopped, .failed: self = .still
            }
        }
    }

    struct Style: Equatable {
        var font: NSFont = .systemFont(ofSize: 16)
        var textColor: NSColor = .labelColor
        /// Line height as a multiple of the font's.
        var lineHeightMultiple: CGFloat = 1.6
    }

    /// What VoiceOver hears when writing starts and when it ends. It never hears the text letter by letter.
    struct Announcements: Equatable {
        var start: String?
        var finish: String?
    }

    var style = Style() {
        didSet { if style != oldValue { restyle() } }
    }

    var announcements = Announcements()

    /// Receives the text to copy, so the app's pasteboard writer can mark it as Keeptide's own. Without it, Copy is
    /// unavailable.
    var onCopy: (@MainActor (String) -> Void)? {
        get { textView.copyHandler }
        set { textView.copyHandler = newValue }
    }

    /// Whether Copy with nothing selected takes the whole text. Surfaces turn it on only for a whole result.
    var allowsCopyingAll: Bool {
        get { textView.copiesWholeText }
        set { textView.copiesWholeText = newValue }
    }

    /// Keys the surface takes before the text does, such as a panel's own: true when it took the key.
    var onKeyDown: (@MainActor (NSEvent) -> Bool)? {
        get { textView.keyHandler }
        set { textView.keyHandler = newValue }
    }

    var pacerTuning: TypewriterPacer.Tuning {
        get { pacer.tuning }
        set { pacer.tuning = newValue }
    }

    var now: () -> TimeInterval = { CACurrentMediaTime() }
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var isOnScreen: @MainActor (NSView) -> Bool = { view in
        guard let window = view.window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }
    var postAnnouncement: @MainActor (NSView, String) -> Void = { view, message in
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    let textView = GeneratedTextView(usingTextLayoutManager: true)
    private let scrollView = NSScrollView()
    private let caret = NSView()

    private(set) var mode = Mode.still
    /// The whole text so far. The text view always holds a prefix of it.
    private var target = ""
    private var targetCount = 0
    /// Where the last character of `target` starts, as a UTF-8 offset. Only that character can change as text grows.
    private var lastCharacterStart = 0
    /// A character boundary at or before the end of the shown text: the characters before it and its UTF-8 offset.
    /// Revealing moves on from here, so a frame doesn't walk the whole text.
    private var mark = (count: 0, offset: 0)
    /// The end of the shown text, as a UTF-8 offset into `target`.
    private var shownOffset = 0
    private var pacer = TypewriterPacer()
    private var hasUpdated = false
    private var frameLink: CADisplayLink?
    private var followsEnd = true
    private var isScrollingProgrammatically = false
    private var lastScrollY: CGFloat = 0
    private weak var observedWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The text on screen.
    var shownText: String { textView.string }

    var isCaretVisible: Bool { !caret.isHidden }

    /// Shows `text`. While `mode` is writing or finishing, text that only grew is typed out; anything else appears at
    /// once. A display first shown on a finished or saved text opens at its start; while writing, it follows the end.
    func update(text: String, mode newMode: Mode) {
        let oldMode = mode
        mode = newMode
        if newMode == .writing, oldMode != .writing { followsEnd = true }
        if !hasUpdated {
            hasUpdated = true
            showAtOnce(text)
            if newMode == .writing { scrollToEndIfFollowing() } else { scrollToStart() }
        } else if text.utf8.count > target.utf8.count, text.utf8.starts(with: target.utf8) {
            grow(to: text)
        } else if text != target {
            showAtOnce(text)
            if newMode == .writing { scrollToEndIfFollowing() }
        }
        if newMode == .still || reducesMotion() || !isOnScreen(self) {
            pacer.revealAll()
        }
        render()
        announce(from: oldMode, to: newMode)
        refresh()
    }

    /// Moves the typewriter to `time`. The display link calls this once a frame.
    func tick(at time: TimeInterval) {
        if isOnScreen(self), !reducesMotion() {
            pacer.advance(to: time)
        } else {
            pacer.revealAll()
        }
        render()
        refresh()
    }

    override func layout() {
        super.layout()
        if mode == .writing { scrollToEndIfFollowing() }
        placeCaret()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
        }
        observedWindow = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            observedWindow = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionDidChange(_:)), name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
        } else {
            pacer.revealAll()
            render()
        }
        refresh()
    }

    // MARK: Text

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeightMultiple
        return [.font: style.font, .foregroundColor: style.textColor, .paragraphStyle: paragraph]
    }

    private func setUp() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = attributes

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        addSubview(scrollView)

        caret.wantsLayer = true
        caret.isHidden = true
        textView.addSubview(caret)

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(
            self, selector: #selector(contentDidScroll(_:)), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(liveScrollDidStart(_:)), name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView)
        center.addObserver(
            self, selector: #selector(liveScrollDidEnd(_:)), name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView)
    }

    private func showAtOnce(_ text: String) {
        target = text
        targetCount = text.count
        lastCharacterStart = Self.lastCharacterStart(of: text)
        mark = (count: targetCount, offset: text.utf8.count)
        shownOffset = text.utf8.count
        pacer.reset(showing: targetCount)
        let selection = textView.selectedRanges.map(\.rangeValue)
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        let length = (text as NSString).length
        textView.selectedRanges = selection.map { range in
            let start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: min(NSMaxRange(range), length) - start))
        }
    }

    /// Takes the target's new end. Appending can only change the old last character, so only it is counted again.
    private func grow(to text: String) {
        let oldCount = targetCount
        let oldLastStart = lastCharacterStart
        let utf8 = text.utf8
        targetCount = max(0, oldCount - 1) + text[utf8.index(utf8.startIndex, offsetBy: oldLastStart)...].count
        lastCharacterStart = Self.lastCharacterStart(of: text)
        // A mark at the old end may now sit inside that character, so it moves back to where the character starts.
        if mark.offset > oldLastStart { mark = (count: max(0, oldCount - 1), offset: oldLastStart) }
        target = text
        pacer.receive(total: targetCount, at: now())
    }

    /// Appends the part of the target the pacer has newly revealed.
    private func render() {
        guard let storage = textView.textStorage else { return }
        let utf8 = target.utf8
        let revealed = min(pacer.revealed, targetCount)
        if revealed >= targetCount {
            mark = (count: targetCount, offset: utf8.count)
        } else if revealed > mark.count {
            let end = target.index(utf8.index(utf8.startIndex, offsetBy: mark.offset), offsetBy: revealed - mark.count)
            mark = (count: revealed, offset: utf8.distance(from: utf8.startIndex, to: end))
        }
        // The shown end is a scalar boundary of the target. A character can grow past it, as when an emoji's joiner
        // arrives in the next delta; the slice then starts inside that character, which is what is missing.
        guard mark.offset > shownOffset else { return }
        let start = utf8.index(utf8.startIndex, offsetBy: shownOffset)
        let end = utf8.index(utf8.startIndex, offsetBy: mark.offset)
        shownOffset = mark.offset
        let selection = textView.selectedRanges
        storage.append(NSAttributedString(string: String(target.unicodeScalars[start..<end]), attributes: attributes))
        if textView.selectedRanges != selection { textView.selectedRanges = selection }
        scrollToEndIfFollowing()
    }

    private static func lastCharacterStart(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.utf8.distance(from: text.utf8.startIndex, to: text.index(before: text.endIndex))
    }

    private func restyle() {
        textView.typingAttributes = attributes
        if let storage = textView.textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        placeCaret()
    }

    private func announce(from oldMode: Mode, to newMode: Mode) {
        let message: String? = switch (oldMode, newMode) {
        case (.writing, .writing): nil
        case (_, .writing): announcements.start
        case (.writing, .finishing): announcements.finish
        default: nil
        }
        if let message, !message.isEmpty { postAnnouncement(self, message) }
    }

    // MARK: Frames, caret and scrolling

    private var isWriting: Bool {
        mode == .writing || (mode == .finishing && !pacer.isCaughtUp)
    }

    private func refresh() {
        if !pacer.isCaughtUp, window != nil {
            if frameLink == nil {
                let link = displayLink(target: self, selector: #selector(step(_:)))
                link.add(to: .main, forMode: .common)
                frameLink = link
            }
        } else {
            frameLink?.invalidate()
            frameLink = nil
        }
        placeCaret()
    }

    @objc private func step(_ link: CADisplayLink) {
        tick(at: link.targetTimestamp)
    }

    /// A display that is covered or hidden shows what has arrived and stops typing until more arrives.
    @objc private func occlusionDidChange(_ notification: Notification) {
        guard !isOnScreen(self) else { return }
        pacer.revealAll()
        render()
        refresh()
    }

    private func placeCaret() {
        caret.isHidden = !isWriting
        guard isWriting, let window = textView.window else { return }
        let end = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
        let onScreen = textView.firstRect(forCharacterRange: end, actualRange: nil)
        guard onScreen.height > 0 else { return }
        let line = textView.convert(window.convertFromScreen(onScreen), from: nil)
        // The line is taller than the font when the line height is a multiple; the caret keeps to the glyphs, at the
        // bottom of the line in the flipped text view.
        let height = min(line.height, (style.font.ascender - style.font.descender).rounded(.up))
        caret.frame = NSRect(x: line.minX, y: line.maxY - height, width: 2, height: height)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            caret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    /// Scrolling up stops following the end; scrolling back to the end follows it again.
    @objc private func contentDidScroll(_ notification: Notification) {
        let y = scrollView.contentView.bounds.minY
        defer { lastScrollY = y }
        guard !isScrollingProgrammatically else { return }
        if y < lastScrollY - 0.5 {
            followsEnd = false
        } else if isScrolledToEnd {
            followsEnd = true
        }
    }

    @objc private func liveScrollDidStart(_ notification: Notification) {
        followsEnd = false
    }

    @objc private func liveScrollDidEnd(_ notification: Notification) {
        followsEnd = isScrolledToEnd
    }

    private var isScrolledToEnd: Bool {
        guard let document = scrollView.documentView else { return true }
        return scrollView.contentView.bounds.maxY >= document.frame.maxY - 2
    }

    /// Keeps the end in view while text arrives, unless the person has scrolled away from it to read.
    private func scrollToEndIfFollowing() {
        guard followsEnd, let length = textView.textStorage?.length else { return }
        isScrollingProgrammatically = true
        textView.scrollRangeToVisible(NSRange(location: length, length: 0))
        isScrollingProgrammatically = false
    }

    private func scrollToStart() {
        isScrollingProgrammatically = true
        textView.scroll(.zero)
        isScrollingProgrammatically = false
    }
}

/// The text view inside `StreamingTextDisplay`. Copying goes to `copyHandler`; without one there is no Copy. Keys go to
/// `keyHandler` first.
final class GeneratedTextView: NSTextView {
    var copyHandler: (@MainActor (String) -> Void)?
    /// Whether Copy with nothing selected takes the whole text.
    var copiesWholeText = false
    /// Takes a key before the text does: true when it took it.
    var keyHandler: (@MainActor (NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// What Copy takes: every selected range, or with nothing selected, the whole text when that is allowed.
    var textToCopy: String? {
        let text = string as NSString
        let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { text.substring(with: $0) }
        if !selected.isEmpty { return selected.joined(separator: "\n") }
        return copiesWholeText && text.length > 0 ? string : nil
    }

    override func copy(_ sender: Any?) {
        guard let copyHandler, let text = textToCopy else { return NSSound.beep() }
        copyHandler(text)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return canCopy }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return canCopy }
        return super.validateUserInterfaceItem(item)
    }

    private var canCopy: Bool { copyHandler != nil && textToCopy != nil }
}

/// `StreamingTextDisplay` for SwiftUI surfaces: the quick access result column, the Library's, and later AI features.
struct StreamingTextView: NSViewRepresentable {
    var text: String
    var mode: StreamingTextDisplay.Mode
    var style: StreamingTextDisplay.Style
    var announcements: StreamingTextDisplay.Announcements
    var allowsCopyingAll: Bool
    var onCopy: (@MainActor (String) -> Void)?
    var onKeyDown: (@MainActor (NSEvent) -> Bool)?

    /// Shows `text`. Pass `allowsCopyingAll` only for a whole result, such as one saved earlier. `onKeyDown` takes keys
    /// before the text does.
    init(
        text: String, mode: StreamingTextDisplay.Mode, style: StreamingTextDisplay.Style = .init(),
        announcements: StreamingTextDisplay.Announcements = .init(), allowsCopyingAll: Bool = false,
        onCopy: (@MainActor (String) -> Void)? = nil, onKeyDown: (@MainActor (NSEvent) -> Bool)? = nil
    ) {
        self.text = text
        self.mode = mode
        self.style = style
        self.announcements = announcements
        self.allowsCopyingAll = allowsCopyingAll
        self.onCopy = onCopy
        self.onKeyDown = onKeyDown
    }

    /// Shows one channel of a job's snapshot. Copying all of it, and the finish announcement, need a whole result.
    init(
        snapshot: GenerationSnapshot, channel: OutputChannel = .main, style: StreamingTextDisplay.Style = .init(),
        announcements: StreamingTextDisplay.Announcements = .init(), onCopy: (@MainActor (String) -> Void)? = nil
    ) {
        let isWhole = snapshot.phase == .finished(.completed)
        var announcements = announcements
        if !isWhole { announcements.finish = nil }
        self.init(
            text: snapshot.text(channel), mode: StreamingTextDisplay.Mode(snapshot.phase), style: style,
            announcements: announcements, allowsCopyingAll: isWhole, onCopy: onCopy)
    }

    func makeNSView(context: Context) -> StreamingTextDisplay {
        StreamingTextDisplay(frame: .zero)
    }

    func updateNSView(_ display: StreamingTextDisplay, context: Context) {
        display.style = style
        display.announcements = announcements
        display.allowsCopyingAll = allowsCopyingAll
        display.onCopy = onCopy
        display.onKeyDown = onKeyDown
        display.update(text: text, mode: mode)
    }
}
