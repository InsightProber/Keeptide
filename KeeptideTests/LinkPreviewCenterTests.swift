import LinkPresentation
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

@MainActor
final class LinkPreviewCenterTests: XCTestCase {
    private var directory: URL!
    private let clock = LinkTestClock()
    private var isEnabled = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-link-center-\(UUID().uuidString)", isDirectory: true)
        isEnabled = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testALinkAskedForIsLoadedOnceAndShown() async throws {
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/a",
                            with: .success(LinkPageMetadata(title: "Page A",
                                                            image: try LinkTestImages.png(width: 600, height: 300))))
        await loader.hold()
        let center = makeCenter(loader)
        XCTAssertEqual(center.state(of: "https://example.com/a"), LinkPreviewState.notLoaded)
        center.request("https://example.com/a")
        center.request("https://example.com/a")
        // The same page, as the preview is kept: the fragment is the page's own business.
        center.request("HTTPS://EXAMPLE.com/a#part")
        await eventually { center.state(of: "https://example.com/a") == .loading }
        await loader.release("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title == "Page A" }
        guard case .loaded(let preview) = center.state(of: "https://example.com/a") else {
            return XCTFail("not loaded")
        }
        let picture = try XCTUnwrap(preview.image)
        XCTAssertEqual(max(picture.width, picture.height), 480)
        XCTAssertEqual(center.state(of: "https://example.com/a#part"), .loaded(preview))
        let requested = await loader.requested
        XCTAssertEqual(requested, ["https://example.com/a"])
    }

    func testNothingIsLoadedOrShownWhileLoadingIsOff() async throws {
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/a", with: .success(LinkPageMetadata(title: "Page A")))
        let center = makeCenter(loader)
        isEnabled = false
        center.request("https://example.com/a")
        await settle()
        var requested = await loader.requested
        XCTAssertEqual(requested, [])
        XCTAssertEqual(center.state(of: "https://example.com/a"), LinkPreviewState.notLoaded)

        isEnabled = true
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title == "Page A" }
        // Turned off, what was loaded isn't shown.
        isEnabled = false
        XCTAssertEqual(center.state(of: "https://example.com/a"), LinkPreviewState.notLoaded)
        requested = await loader.requested
        XCTAssertEqual(requested, ["https://example.com/a"])
    }

    func testALinkThatIsNotLoadedIsNeverAskedFor() async {
        let loader = FakeLinkLoader()
        let center = makeCenter(loader)
        for text in ["http://localhost:3000/", "https://example.com/?token=abc", "mailto:someone@example.com",
                     "https://user:secret@example.com/", "http://192.168.1.1/"] {
            center.request(text)
            XCTAssertEqual(center.state(of: text), LinkPreviewState.notLoaded, text)
        }
        await settle()
        let requested = await loader.requested
        XCTAssertEqual(requested, [])
    }

    func testAtMostTwoLoadsRunAtOnceAndTheLatestAskedForGoesFirst() async {
        let loader = FakeLinkLoader()
        await loader.hold()
        let center = makeCenter(loader)
        for name in ["a", "b", "c", "d"] {
            center.request("https://example.com/\(name)")
            // Each is read from the store before it is loaded; this keeps the order they are asked for.
            await eventually { center.state(of: "https://example.com/\(name)") == .loading }
        }
        await eventually { await loader.requested.count == 2 }
        await settle()
        var requested = await loader.requested
        XCTAssertEqual(Set(requested), ["https://example.com/a", "https://example.com/b"])
        await loader.release("https://example.com/a")
        await eventually { await loader.requested.count == 3 }
        requested = await loader.requested
        XCTAssertEqual(requested.last, "https://example.com/d")
        await loader.release("https://example.com/d")
        await eventually { await loader.requested.count == 4 }
        requested = await loader.requested
        XCTAssertEqual(requested.last, "https://example.com/c")
    }

    func testAPreviewKeptBeforeIsShownWithoutLoadingThePage() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Kept", image: try LinkTestImages.png(width: 300, height: 200)),
                         for: try key("https://example.com/k"), imagePixels: 480)
        let loader = FakeLinkLoader()
        let center = makeCenter(loader, store: store)
        center.request("https://example.com/k")
        await eventually { center.state(of: "https://example.com/k").title == "Kept" }
        await settle()
        let requested = await loader.requested
        XCTAssertEqual(requested, [])
    }

    func testAPreviewDueForRefreshIsShownWhileThePageIsLoadedAgain() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Old"), for: try key("https://example.com/r"), imagePixels: 480)
        // Shown in the meantime, it is still used, though it is due to be loaded again.
        clock.advance(by: 29 * 86_400)
        _ = await store.kept(for: try key("https://example.com/r"), imagePixels: 480)
        clock.advance(by: 2 * 86_400)
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/r", with: .success(LinkPageMetadata(title: "New")))
        await loader.hold()
        let center = makeCenter(loader, store: store)
        center.request("https://example.com/r")
        await eventually { await loader.requested.count == 1 }
        XCTAssertEqual(center.state(of: "https://example.com/r").title, "Old")
        // Asked for again while it is loaded, it isn't loaded twice.
        center.request("https://example.com/r")
        await settle()
        let requested = await loader.requested
        XCTAssertEqual(requested.count, 1)
        await loader.release("https://example.com/r")
        await eventually { center.state(of: "https://example.com/r").title == "New" }
    }

    func testAFailedLoadIsTriedAgainOnlyWhenItsTimeComes() async throws {
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/off", with: .failure(.unreachable))
        await loader.answer("https://example.com/gone", with: .failure(.unavailable))
        let center = makeCenter(loader)
        center.request("https://example.com/off")
        center.request("https://example.com/gone")
        await eventually {
            center.state(of: "https://example.com/off") == .failed
                && center.state(of: "https://example.com/gone") == .failed
        }
        center.request("https://example.com/off")
        center.request("https://example.com/gone")
        await settle()
        var requested = await loader.requested
        XCTAssertEqual(requested.count, 2)

        // Unreachable is tried again after 10 minutes; a page that couldn't be loaded, after a day.
        clock.advance(by: 11 * 60)
        center.request("https://example.com/off")
        center.request("https://example.com/gone")
        await eventually { await loader.requested.count == 3 }
        await settle()
        requested = await loader.requested
        XCTAssertEqual(requested.last, "https://example.com/off")
        XCTAssertEqual(requested.count, 3)
        clock.advance(by: 86_400)
        center.request("https://example.com/gone")
        await eventually { await loader.requested.count == 4 }
        requested = await loader.requested
        XCTAssertEqual(requested.last, "https://example.com/gone")
    }

    func testAPageWithNothingToShowIsTriedAgainAfterADay() async {
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/e", with: .success(LinkPageMetadata()))
        let center = makeCenter(loader)
        center.request("https://example.com/e")
        await eventually { center.state(of: "https://example.com/e") == .empty }
        clock.advance(by: 2 * 3_600)
        center.request("https://example.com/e")
        await settle()
        var requested = await loader.requested
        XCTAssertEqual(requested.count, 1)
        clock.advance(by: 86_400)
        center.request("https://example.com/e")
        await eventually { await loader.requested.count == 2 }
        requested = await loader.requested
        XCTAssertEqual(requested.count, 2)
    }

    func testClearingForgetsWhatWasLoadedAndDropsWhatIsUnderWay() async throws {
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/a", with: .success(LinkPageMetadata(title: "A")))
        await loader.answer("https://example.com/b", with: .success(LinkPageMetadata(title: "B")))
        let store = makeStore()
        let center = makeCenter(loader, store: store)
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title == "A" }
        await loader.hold()
        center.request("https://example.com/b")
        await eventually { await loader.requested.count == 2 }

        await center.clear()
        XCTAssertEqual(center.state(of: "https://example.com/a"), LinkPreviewState.notLoaded)
        await loader.release("https://example.com/b")
        await settle()
        XCTAssertEqual(center.state(of: "https://example.com/b"), LinkPreviewState.notLoaded)
        let keptA = await store.kept(for: try key("https://example.com/a"), imagePixels: 480)
        let keptB = await store.kept(for: try key("https://example.com/b"), imagePixels: 480)
        XCTAssertNil(keptA)
        XCTAssertNil(keptB)

        // Asked for again, it is loaded again.
        await loader.stopHolding()
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title == "A" }
        let requested = await loader.requested
        XCTAssertEqual(requested, ["https://example.com/a", "https://example.com/b", "https://example.com/a"])
    }

    func testLoadsWaitingWhenLoadingIsTurnedOffDontStart() async {
        let loader = FakeLinkLoader()
        await loader.hold()
        let center = makeCenter(loader)
        for name in ["a", "b", "c"] { center.request("https://example.com/\(name)") }
        await eventually { await loader.requested.count == 2 }
        await settle()
        isEnabled = false
        await loader.release("https://example.com/a")
        await loader.release("https://example.com/b")
        await settle()
        let requested = await loader.requested
        XCTAssertEqual(requested.count, 2)
    }

    func testALinkWhoseLoadWasDroppedIsLoadedWhenAskedForAgain() async {
        let loader = FakeLinkLoader()
        await loader.hold()
        let center = makeCenter(loader)
        for name in ["a", "b", "c"] {
            center.request("https://example.com/\(name)")
            await eventually { center.state(of: "https://example.com/\(name)") == .loading }
        }
        isEnabled = false
        await loader.release("https://example.com/a")
        await loader.release("https://example.com/b")
        await settle()
        isEnabled = true
        XCTAssertEqual(center.state(of: "https://example.com/c"), LinkPreviewState.notLoaded)
        await loader.stopHolding()
        center.request("https://example.com/c")
        await eventually { await loader.requested.contains("https://example.com/c") }
        await eventually { center.state(of: "https://example.com/c").title != nil }
    }

    func testALinkAskedForAgainWhileItWaitsGoesFirst() async {
        let loader = FakeLinkLoader()
        await loader.hold()
        let center = makeCenter(loader)
        for name in ["a", "b", "c", "d"] {
            center.request("https://example.com/\(name)")
            await eventually { center.state(of: "https://example.com/\(name)") == .loading }
        }
        await eventually { await loader.requested.count == 2 }
        center.request("https://example.com/c")
        await loader.release("https://example.com/a")
        await eventually { await loader.requested.count == 3 }
        let requested = await loader.requested
        XCTAssertEqual(requested.last, "https://example.com/c")
    }

    func testAPreviewShownStaysWhenLoadingItAgainFailsThoughTheStoreLostIt() async throws {
        let loader = FakeLinkLoader()
        await loader.answer("https://example.com/a", with: .success(LinkPageMetadata(
            title: "Shown", image: try LinkTestImages.png(width: 300, height: 200))))
        let store = makeStore()
        let center = makeCenter(loader, store: store)
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title == "Shown" }
        await store.removeAll()
        clock.advance(by: 31 * 86_400)
        await loader.answer("https://example.com/a", with: .failure(.unavailable))
        center.request("https://example.com/a")
        await eventually { await loader.requested.count == 2 }
        await settle()
        XCTAssertEqual(center.state(of: "https://example.com/a").title, "Shown")
    }

    func testTheStoreIsTrimmedAsAPreviewIsAskedForAtMostOnceADay() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Unused"), for: try key("https://example.com/unused"),
                         imagePixels: 480)
        clock.advance(by: 29.75 * 86_400)
        let center = makeCenter(FakeLinkLoader(), store: store)
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title != nil }
        XCTAssertTrue(try isKept("https://example.com/unused"), "Used within 30 days when it was trimmed")
        // A day hasn't passed since: the preview, unused for 30 days now, stays until one has.
        clock.advance(by: 12 * 3_600)
        center.request("https://example.com/b")
        await eventually { center.state(of: "https://example.com/b").title != nil }
        XCTAssertTrue(try isKept("https://example.com/unused"))
        clock.advance(by: 13 * 3_600)
        center.request("https://example.com/c")
        await eventually { (try? self.isKept("https://example.com/unused")) == false }
    }

    func testTheStoreIsTrimmedAfterEveryFewPagesLoaded() async throws {
        let store = makeStore()
        await store.keep(LinkPageMetadata(title: "Later"), for: try key("https://example.com/later"), imagePixels: 480)
        clock.advance(by: 29.9 * 86_400)
        let center = LinkPreviewCenter(loader: FakeLinkLoader(), store: store,
                                       isEnabled: { [unowned self] in self.isEnabled }, now: { [clock] in clock.now },
                                       trimEvery: 2)
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title != nil }
        XCTAssertTrue(try isKept("https://example.com/later"))
        // Within the day of the first trim, the second page loaded since makes two, and trims again.
        clock.advance(by: 0.2 * 86_400)
        center.request("https://example.com/b")
        await eventually { center.state(of: "https://example.com/b").title != nil }
        await eventually { (try? self.isKept("https://example.com/later")) == false }
    }

    func testAPreviewShownFromMemoryCountsAsUsed() async throws {
        let loader = FakeLinkLoader()
        let store = makeStore()
        let center = makeCenter(loader, store: store)
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title != nil }
        clock.advance(by: 20 * 86_400)
        center.request("https://example.com/a")
        await settle()
        clock.advance(by: 15 * 86_400)
        await store.trim()
        let kept = await store.kept(for: try key("https://example.com/a"), imagePixels: 480)
        XCTAssertNotNil(kept, "Shown 15 days ago, it was used within 30 days")
    }

    func testOnlyTheLatestPicturesStayInMemoryAndTheRestAreReadAgainFromTheStore() async throws {
        let loader = FakeLinkLoader()
        let picture = try LinkTestImages.png(width: 300, height: 200)
        for name in ["a", "b", "c"] {
            await loader.answer("https://example.com/\(name)",
                                with: .success(LinkPageMetadata(title: name, image: picture)))
        }
        let center = makeCenter(loader, maximumPictures: 2)
        for name in ["a", "b", "c"] {
            center.request("https://example.com/\(name)")
            await eventually { center.state(of: "https://example.com/\(name)").title == name }
        }
        XCTAssertEqual(center.state(of: "https://example.com/a"), LinkPreviewState.notLoaded)
        XCTAssertEqual(center.state(of: "https://example.com/c").title, "c")
        center.request("https://example.com/a")
        await eventually { center.state(of: "https://example.com/a").title == "a" }
        let requested = await loader.requested
        XCTAssertEqual(requested, ["https://example.com/a", "https://example.com/b", "https://example.com/c"])
    }

    // MARK: Helpers

    private func makeStore() -> LinkPreviewStore {
        LinkPreviewStore(directory: directory, now: { [clock] in clock.now })
    }

    private func makeCenter(_ loader: FakeLinkLoader, store: LinkPreviewStore? = nil,
                            maximumPictures: Int = 96) -> LinkPreviewCenter {
        LinkPreviewCenter(loader: loader, store: store ?? makeStore(), isEnabled: { [unowned self] in self.isEnabled },
                          now: { [clock] in clock.now }, maximumPictures: maximumPictures)
    }

    private func key(_ text: String) throws -> String {
        LinkAddress.key(for: try LinkAddress.loadable(text).get())
    }

    /// Whether a preview is on disk, found without reading it, which would count as using it.
    private func isKept(_ address: String) throws -> Bool {
        let name = LinkPreviewStore.fileName(for: try key(address))
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path)
    }

    /// Waits for `condition`, for up to five seconds.
    private func eventually(_ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    /// Lets work under way go as far as it goes, for a check that something didn't happen.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }
}

private extension LinkPreviewState {
    var title: String? {
        if case .loaded(let preview) = self { return preview.title }
        return nil
    }
}

/// A stand-in for the network: it answers each address as a test says, and can hold its answers until released.
actor FakeLinkLoader: LinkMetadataLoading {
    /// The addresses asked for, in order.
    private(set) var requested: [String] = []
    private var answers: [String: Result<LinkPageMetadata, LinkMetadataError>] = [:]
    private var holds = false
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<String> = []

    func answer(_ address: String, with result: Result<LinkPageMetadata, LinkMetadataError>) {
        answers[address] = result
    }

    func hold() { holds = true }

    func stopHolding() {
        holds = false
        for (_, waiting) in held { waiting.forEach { $0.resume() } }
        held = [:]
    }

    func release(_ address: String) {
        released.insert(address)
        held.removeValue(forKey: address)?.forEach { $0.resume() }
    }

    func metadata(for url: URL) async throws -> LinkPageMetadata {
        let address = url.absoluteString
        requested.append(address)
        if holds, !released.contains(address) {
            await withCheckedContinuation { held[address, default: []].append($0) }
        }
        released.remove(address)
        return try (answers[address] ?? .success(LinkPageMetadata(title: "Synthetic \(address)"))).get()
    }
}

/// Whether a failed fetch is tried again in ten minutes or in a day, as the system's loader reads the failure. No
/// loader is built: that would reach a real website.
final class SystemLinkMetadataLoaderTests: XCTestCase {
    func testNoConnectionOrNoAnswerInTimeIsTriedAgainSoon() {
        let timedOut = NSError(domain: LPErrorDomain, code: LPError.Code.metadataFetchTimedOut.rawValue)
        XCTAssertEqual(SystemLinkMetadataLoader.reason(for: timedOut), .unreachable)
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                     NSURLErrorCannotConnectToHost] {
            let failure = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(SystemLinkMetadataLoader.reason(for: failure), .unreachable, "\(code)")
            // Also when LinkPresentation wraps it.
            let wrapped = NSError(domain: LPErrorDomain, code: LPError.Code.metadataFetchFailed.rawValue,
                                  userInfo: [NSUnderlyingErrorKey: failure])
            XCTAssertEqual(SystemLinkMetadataLoader.reason(for: wrapped), .unreachable, "\(code)")
        }
    }

    func testAnyOtherFailureIsThePagesAndWaitsADay() {
        for failure in [NSError(domain: LPErrorDomain, code: LPError.Code.metadataFetchFailed.rawValue),
                        NSError(domain: LPErrorDomain, code: LPError.Code.metadataFetchCancelled.rawValue),
                        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost),
                        NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse),
                        NSError(domain: "Synthetic", code: 1)] {
            XCTAssertEqual(SystemLinkMetadataLoader.reason(for: failure), .unavailable, failure.description)
        }
        XCTAssertEqual(SystemLinkMetadataLoader.reason(for: CancellationError()), .unavailable)
    }
}

/// How a picture or an icon LinkPresentation hands over is read: in time, no larger than the most, and not past a
/// cancellation. Synthetic providers stand in for LinkPresentation's.
final class ItemProviderImageTests: XCTestCase {
    /// A provider of a PNG whose load calls `load` with what to answer, or never answers if it doesn't call it.
    private func provider(_ load: @escaping @Sendable (@escaping @Sendable (Data?, (any Error)?) -> Void) -> Void)
        -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            load(completion)
            return nil
        }
        return provider
    }

    /// What reading `provider` gives, failing if it takes longer than three seconds.
    private func read(_ provider: NSItemProvider?, largest: Int = 1_000_000, timeout: TimeInterval = 30,
                      cancelAfter: Duration? = nil) async -> Data?? {
        let finished = expectation(description: "read")
        let box = ReadResult()
        let source = SyntheticProvider(provider: provider)
        let task = Task {
            box.set(await ItemProviderImage.data(of: source.provider, largest: largest, timeout: timeout))
            finished.fulfill()
        }
        if let cancelAfter {
            try? await Task.sleep(for: cancelAfter)
            task.cancel()
        }
        await fulfillment(of: [finished], timeout: 3)
        return box.value
    }

    func testAnImageThatArrivesIsReadAsItCame() async throws {
        let png = try LinkTestImages.png(width: 10, height: 10)
        let read = await read(provider { $0(png, nil) })
        XCTAssertEqual(read, .some(png))
    }

    func testAnImageLargerThanTheMostIsLeftOut() async throws {
        let png = try LinkTestImages.png(width: 10, height: 10)
        let read = await read(provider { $0(png, nil) }, largest: png.count - 1)
        XCTAssertEqual(read, .some(nil))
    }

    func testAnImageThatNeverArrivesIsLeftOutWhenTheTimeRunsOut() async {
        let read = await read(provider { _ in }, timeout: 0.2)
        XCTAssertEqual(read, .some(nil))
    }

    func testACancelledReadStopsWaitingAtOnce() async {
        let read = await read(provider { _ in }, timeout: 30, cancelAfter: .milliseconds(100))
        XCTAssertEqual(read, .some(nil))
    }

    func testAReadCancelledBeforeItBeginsEndsAtOnce() async {
        let finished = expectation(description: "read")
        let box = ReadResult()
        let loads = LoadCount()
        let source = SyntheticProvider(provider: provider { _ in loads.add() })
        Task {
            // Cancelled before it asks, for certain.
            withUnsafeCurrentTask { $0?.cancel() }
            box.set(await ItemProviderImage.data(of: source.provider, largest: 1_000_000, timeout: 30))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(box.value, .some(nil))
        XCTAssertEqual(loads.count, 0, "Nothing is loaded")
    }

    func testTheLoadIsStoppedWhenTheTimeRunsOutAndALateAnswerChangesNothing() async throws {
        let progress = Progress(totalUnitCount: 1)
        let png = try LinkTestImages.png(width: 10, height: 10)
        let source = NSItemProvider()
        source.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { completion(png, nil) }
            return progress
        }
        let read = await read(source, timeout: 0.1)
        XCTAssertEqual(read, .some(nil))
        XCTAssertTrue(progress.isCancelled)
        // The answer that comes after is dropped.
        try await Task.sleep(for: .milliseconds(600))
    }

    func testNoImageIsNothing() async {
        let text = NSItemProvider(item: "Synthetic" as NSString, typeIdentifier: UTType.plainText.identifier)
        let readText = await read(text)
        XCTAssertEqual(readText, .some(nil))
        let readNone = await read(nil)
        XCTAssertEqual(readNone, .some(nil))
    }
}

/// How many times a synthetic provider was asked to load.
private final class LoadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0

    var count: Int { lock.withLock { loads } }

    func add() { lock.withLock { loads += 1 } }
}

/// A synthetic provider handed to the task that reads it.
private struct SyntheticProvider: @unchecked Sendable {
    let provider: NSItemProvider?
}

/// What a read gave, once it gave it.
private final class ReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Data??

    var value: Data?? { lock.withLock { result } }

    func set(_ data: Data?) { lock.withLock { result = .some(data) } }
}
