import AppKit
import SwiftUI
import WebKit

/// What a page shown in the preview may do.
///
/// The link loads, and so do redirects and the page's own moves while they stay addresses Keeptide would load itself. A
/// link within the page, one that changes only the fragment, moves the page. Another link the person clicks, or a form
/// they send, goes to the default browser, also when it asks for a new window; a form that would send what was typed
/// other than in its address isn't sent, since the browser is given an address alone. A window the page's script asks
/// for opens nowhere. Frames inside the page load over the web alone. Nothing is downloaded.
enum LinkPolicy {
    enum Decision: Equatable {
        case allow
        /// Not shown here: the address goes to the default browser.
        case openInBrowser(URL)
        case cancel
    }

    /// What WebKit says of a navigation, and what the preview knows of it.
    struct Navigation: Equatable {
        var url: URL?
        /// The address of the page that shows, nil until one does.
        var currentURL: URL?
        /// In the page itself rather than a frame within it.
        var isMainFrame = true
        /// It asks for a new window.
        var opensWindow = false
        var type: WKNavigationType = .other
        var downloads = false
        /// The request's HTTP method: a form sent with any other than GET carries what was typed in its body.
        var method = "GET"
        /// The person clicked or pressed a key in the page just before, and no navigation claimed it yet.
        var followsInput = false
        /// The page is a UI test's synthetic one, which starts empty.
        var isSynthetic = false
    }

    static func decision(for navigation: Navigation) -> Decision {
        guard let url = navigation.url, !navigation.downloads else { return .cancel }
        let scheme = url.scheme?.lowercased()
        let isWeb = scheme == "http" || scheme == "https"
        let isPersons = navigation.followsInput && mayBePersons(navigation.type)
        let toBrowser: Decision = isWeb && navigation.method.uppercased() == "GET" ? .openInBrowser(url) : .cancel
        if navigation.opensWindow { return isPersons ? toBrowser : .cancel }
        // A frame within the page: what the page shows of others, over the web alone. "about:" is an empty frame.
        guard navigation.isMainFrame else { return isWeb || scheme == "about" ? .allow : .cancel }
        if navigation.isSynthetic, navigation.currentURL == nil, url.absoluteString == "about:blank" { return .allow }
        // A link within the page. A form sent to the page itself is still sent: it goes to the browser.
        let isForm = navigation.type == .formSubmitted || navigation.type == .formResubmitted
        if !isForm, let current = navigation.currentURL, differsInFragmentAlone(url, from: current) { return .allow }
        if isPersons { return toBrowser }
        guard case .success = LinkAddress.loadable(url.absoluteString) else { return .cancel }
        return .allow
    }

    /// Whether a navigation of `type` may be the person's own: a link they activate or a form they send. Only such a
    /// navigation claims their click or key press.
    static func mayBePersons(_ type: WKNavigationType) -> Bool {
        type == .linkActivated || type == .formSubmitted || type == .formResubmitted
    }

    /// Whether `url` is the page `current` but for its fragment: a link within the page.
    static func differsInFragmentAlone(_ url: URL, from current: URL) -> Bool {
        guard var moved = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var shown = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return false }
        moved.fragment = nil
        shown.fragment = nil
        return moved.url == shown.url
    }

    /// Whether the address shown may move from `shown` to `url` before a new page shows: within the origin of the page
    /// that shows, as a link within the page or the page's own history does. An address elsewhere is shown once its
    /// page is, so that no address stands over another site's page.
    static func movesWithinOrigin(from shown: URL, to url: URL) -> Bool {
        func origin(_ url: URL) -> (scheme: String?, host: String?, port: Int?) {
            let scheme = url.scheme?.lowercased()
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
            return (scheme, url.host()?.lowercased(), port)
        }
        return origin(shown) == origin(url)
    }

    /// The address shown once WebKit's moves to `url`: `url` while no navigation is on its way and it stays within the
    /// origin of the page `shown`, as a link within the page or the page's own history moves it; `shown` otherwise, so
    /// that a navigation that may never arrive, and its redirects, show no address. Nil while no page shows.
    static func address(shown: URL?, after url: URL?, isProvisional: Bool) -> URL? {
        guard !isProvisional, let shown, let url, movesWithinOrigin(from: shown, to: url) else { return shown }
        return url
    }

    /// Whether a failure ends the preview's page: not once a page shows, which stays, nor when a newer navigation took
    /// the place of the one that failed, as a page that moves on before it finishes does.
    static func endsPage(_ error: any Error, pageShows: Bool) -> Bool {
        guard !pageShows else { return false }
        let error = error as NSError
        return !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
    }
}

/// The person's clicks and key presses in a page, each of which one navigation may claim within a second. Times are
/// seconds of the system's uptime, which no change of the clock moves.
struct PersonsInput {
    private var last: TimeInterval?

    /// Notes an input at `time`.
    mutating func note(at time: TimeInterval) { last = time }

    /// Moves an input that is still unclaimed on to `time`: a click, whose link is followed as the button comes up.
    mutating func extend(to time: TimeInterval) {
        if last != nil { last = time }
    }

    /// Whether an input came within a second before `time` and is still unclaimed; claiming it, if so.
    mutating func claim(at time: TimeInterval) -> Bool {
        guard let last, time >= last, time - last < 1 else { return false }
        self.last = nil
        return true
    }
}

/// The page a link leads to, in a web view that keeps nothing: each preview has a store of its own that lasts as long
/// as it does, with no cookies, cache or history kept from one to another.
struct LinkWebView: NSViewRepresentable {
    enum Phase: Equatable {
        case loading
        /// The page shows.
        case loaded
        case failed
    }

    /// The page: a link's address, or for a UI test, text to show in its place, which loads nothing.
    enum Page: Equatable {
        case address(URL)
        case synthetic(html: String)
    }

    let page: Page
    var onPhase: (Phase) -> Void = { _ in }
    /// Told the address of the page that shows, as it moves; nil when it is no web address, and the link's stands for
    /// it.
    var onAddress: (URL?) -> Void = { _ in }
    var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// A configuration that keeps no data and opens no window or plays nothing on its own.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LinkPageWebView {
        let webView = LinkPageWebView(frame: .zero, configuration: Self.configuration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.watch(webView)
        load(page, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: LinkPageWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.page != page else { return }
        load(page, in: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: LinkPageWebView, coordinator: Coordinator) {
        // Stopping changes the address; nothing hears of it any more.
        coordinator.stopWatching()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// Loads `page`. The phase isn't told here, during an update: a new page is a new view, which starts loading.
    private func load(_ page: Page, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.page = page
        switch page {
        case .address(let url): webView.load(URLRequest(url: url))
        case .synthetic(let html): webView.loadHTMLString(html, baseURL: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LinkWebView
        var page: LinkWebView.Page?
        /// Whether a page shows: one committed.
        private var pageShows = false
        /// The address of the page that shows: the one last committed, or one it moved to within its origin since.
        private var shownURL: URL?
        /// Whether a navigation of the page itself is on its way, not shown yet. A navigation decided meanwhile, its
        /// redirects among them, never claims the person's input.
        private var isProvisional = false
        private var provisional: WKNavigation?
        /// The address last sent to the browser, and when: the same one again within a second, as a double click or a
        /// held key asks for, isn't sent twice.
        private var lastOpened: (url: URL, time: TimeInterval)?
        private weak var webView: LinkPageWebView?
        private var addressWatch: NSKeyValueObservation?

        init(_ parent: LinkWebView) {
            self.parent = parent
        }

        func watch(_ webView: LinkPageWebView) {
            self.webView = webView
            // WebKit's address moves as soon as a navigation starts, and back when it fails.
            addressWatch = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.addressMayHaveMoved() }
            }
        }

        /// WebKit moves its address before it tells the delegate of the navigation that moved it: where the address is
        /// is read once the delegate has heard.
        private func addressMayHaveMoved() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.addressChanged() }
            }
        }

        func stopWatching() {
            addressWatch?.invalidate()
            addressWatch = nil
        }

        private func addressChanged() {
            let moved = LinkPolicy.address(shown: shownURL, after: webView?.url, isProvisional: isProvisional)
            guard moved != shownURL else { return }
            shownURL = moved
            tellAddress()
        }

        /// Tells the address of the page that shows, once one does: before, the address is the link's.
        private func tellAddress() {
            guard let url = shownURL else { return }
            parent.onAddress(["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil)
        }

        private func endProvisional(_ navigation: WKNavigation?) {
            guard navigation == nil || provisional == nil || navigation === provisional else { return }
            isProvisional = false
            provisional = nil
        }

        /// What WebKit may do with a navigation to `url`, in the page itself or a frame within it (`inMainFrame`), or
        /// asking for a new window (nil): one of the person's goes to the browser. Only a link or form of the page
        /// itself, or one for a window, and none decided while a navigation is on its way, claims the person's input.
        func policy(to url: URL?, inMainFrame: Bool?, type: WKNavigationType, downloads: Bool = false,
                    method: String? = "GET") -> WKNavigationActionPolicy {
            var isSynthetic = false
            if case .synthetic = page { isSynthetic = true }
            let isMainFrame = inMainFrame ?? true
            let opensWindow = inMainFrame == nil
            let mayClaim = LinkPolicy.mayBePersons(type) && (isMainFrame || opensWindow)
                && !isProvisional
            let navigation = LinkPolicy.Navigation(
                url: url, currentURL: shownURL, isMainFrame: isMainFrame, opensWindow: opensWindow, type: type,
                downloads: downloads, method: method ?? "GET",
                followsInput: mayClaim && webView?.claimInput() == true, isSynthetic: isSynthetic)
            switch LinkPolicy.decision(for: navigation) {
            case .allow: return .allow
            case .openInBrowser(let url):
                let now = ProcessInfo.processInfo.systemUptime
                if lastOpened.map({ $0.url != url || now - $0.time >= 1 }) ?? true { parent.openInBrowser(url) }
                lastOpened = (url, now)
                return .cancel
            case .cancel: return .cancel
            }
        }

        /// What `action` is: one with no frame to load in asks for a new window.
        private func policy(for action: WKNavigationAction, opensWindow: Bool) -> WKNavigationActionPolicy {
            policy(to: action.request.url, inMainFrame: opensWindow ? nil : action.targetFrame.map { $0.isMainFrame },
                   type: action.navigationType, downloads: action.shouldPerformDownload,
                   method: action.request.httpMethod)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            (policy(for: navigationAction, opensWindow: false), preferences)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            navigationResponse.canShowMIMEType ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isProvisional = true
            provisional = navigation
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            endProvisional(navigation)
            shownURL = webView.url
            if !pageShows {
                pageShows = true
                self.webView?.showsPage = true
                parent.onPhase(.loaded)
            }
            tellAddress()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if LinkPolicy.endsPage(error, pageShows: pageShows) { parent.onPhase(.failed) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) {
            endProvisional(navigation)
            if LinkPolicy.endsPage(error, pageShows: pageShows) { parent.onPhase(.failed) }
        }

        /// The page's process ended, as when it crashed: nothing shows any more.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            pageShows = false
            shownURL = nil
            endProvisional(nil)
            self.webView?.showsPage = false
            parent.onPhase(.failed)
        }

        /// A page asking for a window of its own: on the person's click, its address goes to the default browser.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            _ = policy(for: navigationAction, opensWindow: true)
            return nil
        }

        /// A page asking for the camera or the microphone gets neither.
        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                     initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            .deny
        }
    }
}

/// The web view of a link's page. It notes the person's clicks and key presses, so that only a navigation one of them
/// made goes to the default browser, and takes no click until a page shows: until then it lies clear under what is
/// known of the page. A force click doesn't load the link outside the delegate, and nothing dropped on the page reaches
/// its script. Escape never reaches the page: the panel takes it first and closes the preview.
final class LinkPageWebView: WKWebView {
    /// Whether a page shows.
    var showsPage = false
    private var input = PersonsInput()

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsLinkPreview = false
        unregisterDraggedTypes()
        setAccessibilityLabel("Web page")
    }

    /// Never made from an archive, which would bring a configuration of its own.
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        showsPage ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        noteInput()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        input.extend(to: ProcessInfo.processInfo.systemUptime)
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // A held key is one press.
        if !event.isARepeat { noteInput() }
        super.keyDown(with: event)
    }

    /// Notes a click or key press of the person's in the page.
    func noteInput() { input.note(at: ProcessInfo.processInfo.systemUptime) }

    /// Whether the person clicked or pressed a key within the last second, claiming it for one navigation.
    func claimInput() -> Bool { input.claim(at: ProcessInfo.processInfo.systemUptime) }
}
