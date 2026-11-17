import WebKit
import XCTest
@testable import Keeptide

/// What a page in the preview may do, and that its web view keeps nothing. No page is loaded.
@MainActor
final class LinkWebViewTests: XCTestCase {
    private let article = "https://example.com/article"

    private func decision(_ address: String?, on current: String? = nil, mainFrame: Bool = true,
                          window: Bool = false, type: WKNavigationType = .other, downloads: Bool = false,
                          method: String = "GET", input: Bool = false,
                          synthetic: Bool = false) -> LinkPolicy.Decision {
        LinkPolicy.decision(for: LinkPolicy.Navigation(
            url: address.flatMap(URL.init(string:)), currentURL: current.flatMap(URL.init(string:)),
            isMainFrame: mainFrame, opensWindow: window, type: type, downloads: downloads, method: method,
            followsInput: input, isSynthetic: synthetic))
    }

    private func url(_ address: String) throws -> URL { try XCTUnwrap(URL(string: address)) }

    func testTheLinkAndThePagesOwnMovesLoadWhileTheyAreLinksKeeptideMayLoad() {
        XCTAssertEqual(decision(article), .allow)
        XCTAssertEqual(decision("https://www.example.com/article?page=2", on: article), .allow)
        // A redirect or a move to this Mac, the local network, a sign-in that carries a token, or anything but the web
        // stops, before a page shows and after.
        for address in ["http://localhost:8080/", "http://192.168.1.1/admin", "https://example.com/cb?code=abc",
                        "file:///etc/hosts", "ftp://example.com/", "javascript:alert(1)"] {
            XCTAssertEqual(decision(address), .cancel, address)
            XCTAssertEqual(decision(address, on: article), .cancel, address)
        }
        XCTAssertEqual(decision(nil), .cancel)
    }

    func testALinkThePersonClicksOrAFormTheySendOpensInTheirBrowser() throws {
        let next = try url("https://example.org/next")
        XCTAssertEqual(decision("https://example.org/next", on: article, type: .linkActivated, input: true),
                       .openInBrowser(next))
        XCTAssertEqual(decision("https://example.org/next", on: article, type: .formSubmitted, input: true),
                       .openInBrowser(next))
        // Also a link to somewhere Keeptide wouldn't load itself: the browser is where the person goes anyway.
        XCTAssertEqual(decision("http://localhost:3000/", on: article, type: .linkActivated, input: true),
                       .openInBrowser(try url("http://localhost:3000/")))
        // But only to a web address.
        XCTAssertEqual(decision("mailto:someone@example.com", on: article, type: .linkActivated, input: true), .cancel)
        XCTAssertEqual(decision("file:///etc/hosts", on: article, type: .linkActivated, input: true), .cancel)
    }

    func testAFormThatWouldSendWhatWasTypedOutsideItsAddressIsntSent() throws {
        XCTAssertEqual(decision("https://example.org/search?q=tide", on: article, type: .formSubmitted, input: true),
                       .openInBrowser(try url("https://example.org/search?q=tide")))
        // The browser is given an address alone: what such a form carries would be lost on the way.
        XCTAssertEqual(decision("https://example.org/sign-in", on: article, type: .formSubmitted, method: "POST",
                                input: true), .cancel)
        XCTAssertEqual(decision("https://example.org/sign-in", on: article, window: true, type: .formSubmitted,
                                method: "post", input: true), .cancel)
        // The page's own form is a move of the page's, held to the address rules.
        XCTAssertEqual(decision("https://example.org/sign-in", on: article, type: .formSubmitted, method: "POST"),
                       .allow)
    }

    func testAPageCantPassOffItsOwnClickAsThePersons() {
        // A click a script makes, with no click or key press of the person's, is the page moving: it stays here, held
        // to the same rules, and never reaches the browser.
        XCTAssertEqual(decision("https://example.org/next", on: article, type: .linkActivated), .allow)
        XCTAssertEqual(decision("http://localhost:3000/", on: article, type: .linkActivated), .cancel)
        XCTAssertEqual(decision("https://example.org/?token=abc", on: article, type: .formSubmitted), .cancel)
        // Nor does a move the person's input didn't make: the page changing its address after a click.
        XCTAssertEqual(decision("http://localhost:3000/", on: article, type: .other, input: true), .cancel)
        XCTAssertEqual(decision("https://example.org/next", on: article, type: .reload, input: true), .allow)
        for type: WKNavigationType in [.linkActivated, .formSubmitted, .formResubmitted] {
            XCTAssertTrue(LinkPolicy.mayBePersons(type), "\(type.rawValue)")
        }
        for type: WKNavigationType in [.other, .reload, .backForward] {
            XCTAssertFalse(LinkPolicy.mayBePersons(type), "\(type.rawValue)")
        }
    }

    func testALinkWithinThePageMovesThePage() throws {
        XCTAssertEqual(decision("https://example.com/article#part-2", on: article, type: .linkActivated, input: true),
                       .allow)
        XCTAssertEqual(decision(article, on: "https://example.com/article#part-2", type: .linkActivated, input: true),
                       .allow)
        // A form sent to the page itself is still sent: it goes to the browser.
        XCTAssertEqual(decision(article, on: article, type: .formSubmitted, input: true),
                       .openInBrowser(try url(article)))
        XCTAssertTrue(LinkPolicy.differsInFragmentAlone(try url("https://example.com/a#x"),
                                                        from: try url("https://example.com/a")))
        for other in ["https://example.com/b#x", "https://example.com/a?x=1#x", "https://example.org/a#x",
                      "http://example.com/a#x"] {
            XCTAssertFalse(LinkPolicy.differsInFragmentAlone(try url(other), from: try url("https://example.com/a")),
                           other)
        }
    }

    func testFramesInThePageLoadOverTheWebAlone() {
        XCTAssertEqual(decision("https://video.example.net/embed/1", on: article, mainFrame: false), .allow)
        XCTAssertEqual(decision("about:blank", on: article, mainFrame: false), .allow)
        for address in ["file:///etc/hosts", "data:text/html,hello", "javascript:alert(1)"] {
            XCTAssertEqual(decision(address, on: article, mainFrame: false), .cancel, address)
        }
        // A link the person clicks in a frame moves the frame.
        XCTAssertEqual(decision("https://video.example.net/embed/2", on: article, mainFrame: false,
                                type: .linkActivated, input: true), .allow)
    }

    func testAWindowOpensInTheBrowserOnlyForALinkThePersonClicks() throws {
        XCTAssertEqual(decision("https://example.org/next", on: article, window: true, type: .linkActivated,
                                input: true), .openInBrowser(try url("https://example.org/next")))
        // The page's script asking for one, on its own or after the person's click, opens nothing.
        XCTAssertEqual(decision("https://example.org/next", on: article, window: true, type: .linkActivated), .cancel)
        XCTAssertEqual(decision("https://example.org/next", on: article, window: true, input: true), .cancel)
        XCTAssertEqual(decision("file:///etc/hosts", on: article, window: true, type: .linkActivated, input: true),
                       .cancel)
    }

    func testOnlyASyntheticPageStartsEmpty() {
        XCTAssertEqual(decision("about:blank", synthetic: true), .allow)
        XCTAssertEqual(decision("about:blank"), .cancel)
    }

    func testNothingIsDownloaded() {
        let file = "https://example.com/file.zip"
        XCTAssertEqual(decision(file, downloads: true), .cancel)
        XCTAssertEqual(decision(file, on: article, type: .linkActivated, downloads: true, input: true), .cancel)
        XCTAssertEqual(decision(file, on: article, mainFrame: false, downloads: true), .cancel)
        XCTAssertEqual(decision(file, on: article, window: true, type: .linkActivated, downloads: true, input: true),
                       .cancel)
    }

    func testTheAddressShownMovesToAnotherSiteOnlyOnceItsPageShows() throws {
        let shown = try url(article)
        for moved in ["https://example.com/article#part-2", "https://example.com/other?page=2",
                      "https://EXAMPLE.com:443/other"] {
            XCTAssertTrue(LinkPolicy.movesWithinOrigin(from: shown, to: try url(moved)), moved)
        }
        // A navigation the page starts, still on its way, may never arrive: its address waits for its page.
        for elsewhere in ["https://accounts.example.com/", "http://example.com/article", "https://example.com:8443/",
                          "https://example.org/article"] {
            XCTAssertFalse(LinkPolicy.movesWithinOrigin(from: shown, to: try url(elsewhere)), elsewhere)
        }
    }

    func testTheAddressShownWaitsForANavigationOnItsWay() throws {
        let shown = try url(article)
        let moved = try url("https://example.com/other")
        XCTAssertEqual(LinkPolicy.address(shown: shown, after: moved, isProvisional: false), moved,
                       "A link within the page, or the page's own history")
        XCTAssertEqual(LinkPolicy.address(shown: shown, after: moved, isProvisional: true), shown,
                       "A navigation on its way, or its redirect, may never arrive")
        XCTAssertEqual(LinkPolicy.address(shown: shown, after: try url("https://example.org/"), isProvisional: false),
                       shown)
        XCTAssertEqual(LinkPolicy.address(shown: shown, after: nil, isProvisional: false), shown)
        XCTAssertNil(LinkPolicy.address(shown: nil, after: moved, isProvisional: false), "No page shows yet")
    }

    func testAFailureEndsThePageOnlyBeforeItShowsAndNotWhenANewerLoadTookItsPlace() {
        let unreachable = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        // How WebKit tells a navigation the policy stopped: a refused redirect, or a link that went to the browser.
        let stopped = NSError(domain: "WebKitErrorDomain", code: 102)
        let replaced = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(LinkPolicy.endsPage(unreachable, pageShows: false))
        XCTAssertTrue(LinkPolicy.endsPage(stopped, pageShows: false))
        XCTAssertFalse(LinkPolicy.endsPage(replaced, pageShows: false))
        for error in [unreachable, stopped, replaced] {
            XCTAssertFalse(LinkPolicy.endsPage(error, pageShows: true), error.description)
        }
    }

    func testAClickOrKeyPressIsClaimedOnceWithinASecondOfItOrOfItsButtonComingUp() {
        var input = PersonsInput()
        XCTAssertFalse(input.claim(at: 100), "Nothing noted")
        input.note(at: 100)
        XCTAssertTrue(input.claim(at: 100.5))
        XCTAssertFalse(input.claim(at: 100.6), "Claimed already")
        input.note(at: 100)
        XCTAssertFalse(input.claim(at: 101.5), "Too late")
        input.note(at: 100)
        XCTAssertFalse(input.claim(at: 99.9), "Before it")
        XCTAssertTrue(input.claim(at: 100.2))
        // A button held down a while: its link is followed as it comes up.
        input.note(at: 200)
        input.extend(to: 201.5)
        XCTAssertTrue(input.claim(at: 201.6))
        // A button coming up after its click was claimed is no new input.
        input.note(at: 300)
        XCTAssertTrue(input.claim(at: 300.1))
        input.extend(to: 300.2)
        XCTAssertFalse(input.claim(at: 300.3))
    }

    func testOnlyALinkOfThePageItselfClaimsThePersonsInputAndNoneWhileANavigationIsOnItsWay() throws {
        let opened = OpenedLinks()
        let coordinator = LinkWebView.Coordinator(LinkWebView(page: .synthetic(html: ""),
                                                              openInBrowser: { opened.urls.append($0) }))
        // Built as the preview builds it; nothing is loaded.
        let webView = LinkPageWebView(frame: .zero, configuration: LinkWebView.configuration())
        coordinator.watch(webView)
        defer { coordinator.stopWatching() }
        /// What the delegate decides for a navigation to `page` of example.org, in the page itself, a frame, or a
        /// window (nil).
        func decide(_ page: Int, _ type: WKNavigationType = .linkActivated,
                    inMainFrame: Bool? = true) throws -> WKNavigationActionPolicy {
            coordinator.policy(to: try url("https://example.org/\(page)"), inMainFrame: inMainFrame, type: type)
        }

        XCTAssertEqual(try decide(1), .allow, "The page's own click is a move of the page's")
        webView.noteInput()
        XCTAssertEqual(try decide(2), .cancel)
        XCTAssertEqual(opened.pages, [2], "The person's click goes to the browser")
        XCTAssertEqual(try decide(3), .allow, "Their click is claimed once")

        // A frame's navigation, or one that is no link or form, leaves the input to the person's link.
        webView.noteInput()
        XCTAssertEqual(try decide(4, inMainFrame: false), .allow)
        XCTAssertEqual(try decide(5, .other), .allow)
        XCTAssertEqual(try decide(6), .cancel)
        // The same address again within a second, as a double click asks for, goes to the browser once.
        webView.noteInput()
        XCTAssertEqual(try decide(6), .cancel)
        XCTAssertEqual(opened.pages, [2, 6])

        // A window opens in the browser for the person's link alone.
        XCTAssertEqual(try decide(7, inMainFrame: nil), .cancel)
        webView.noteInput()
        XCTAssertEqual(try decide(8, inMainFrame: nil), .cancel)
        XCTAssertEqual(opened.pages, [2, 6, 8])

        // What is decided while a navigation is on its way, its redirects among them, claims nothing.
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        webView.noteInput()
        XCTAssertEqual(try decide(9), .allow)
        coordinator.webView(webView, didFailProvisionalNavigation: nil,
                            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(try decide(10), .cancel)
        XCTAssertEqual(opened.pages, [2, 6, 8, 10])
    }

    func testTheWebViewsDelegateAnswersEachQuestionWebKitAsks() {
        // A method with a name WebKit doesn't call would leave its question to WebKit's default: a camera allowed after
        // asking, a window opened, a download made, a page that never shows or a dead one kept.
        let coordinator = LinkWebView.Coordinator(LinkWebView(page: .synthetic(html: "")))
        for selector in [
            "webView:decidePolicyForNavigationAction:preferences:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:didStartProvisionalNavigation:",
            "webView:didCommitNavigation:",
            "webView:didFailNavigation:withError:",
            "webView:didFailProvisionalNavigation:withError:",
            "webViewWebContentProcessDidTerminate:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        ] {
            XCTAssertTrue(coordinator.responds(to: NSSelectorFromString(selector)), selector)
        }
    }

    func testTheWebViewKeepsNothingAndOpensNoWindowOrPlaysNothingOnItsOwn() {
        let configuration = LinkWebView.configuration()
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
        // Each preview has a store of its own.
        XCTAssertFalse(configuration.websiteDataStore === LinkWebView.configuration().websiteDataStore)
    }

    func testThePagesViewTakesNoClickUntilAPageShowsAndNoForceClickOrDrop() {
        // Built as the preview builds it; nothing is loaded.
        let webView = LinkPageWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                                      configuration: LinkWebView.configuration())
        let middle = NSPoint(x: 100, y: 100)
        XCTAssertNil(webView.hitTest(middle))
        webView.showsPage = true
        XCTAssertNotNil(webView.hitTest(middle))
        XCTAssertFalse(webView.allowsLinkPreview)
        XCTAssertTrue(webView.registeredDraggedTypes.isEmpty)
    }
}

/// Where the delegate sent the person.
private final class OpenedLinks {
    var urls: [URL] = []
    /// The page numbers of the example.org addresses sent.
    var pages: [Int] { urls.compactMap { Int($0.lastPathComponent) } }
}
