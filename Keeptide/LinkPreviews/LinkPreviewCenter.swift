import CoreGraphics
import Foundation
import Observation

/// A link's preview as a card or a row shows it: the page's title and picture, and the site's icon.
struct LinkPreview: Equatable, Sendable {
    let title: String?
    let image: CGImage?
    let icon: CGImage?
}

/// What is known of a link's preview.
enum LinkPreviewState: Equatable {
    /// Nothing to show: loading previews is off, the link isn't one to load, it wasn't asked for, or what was kept of
    /// it is being read.
    case notLoaded
    /// The page is being loaded, with nothing kept to show meanwhile.
    case loading
    /// The page's title, picture or both, kept or just loaded. It stays while the page is loaded again, and when
    /// loading it again fails.
    case loaded(LinkPreview)
    /// The page gave nothing to show.
    case empty
    /// Loading the page failed, and nothing was loaded before.
    case failed

    var hasPicture: Bool {
        if case .loaded(let preview) = self { return preview.image != nil }
        return false
    }
}

/// Loads what a page gives to show its link by.
protocol LinkMetadataLoading: Sendable {
    /// The title, picture and icon of the page `url` leads to. Throws `LinkMetadataError`.
    func metadata(for url: URL) async throws -> LinkPageMetadata
}

/// Why a page's title and picture couldn't be loaded.
enum LinkMetadataError: Error, Equatable, Sendable {
    /// The page couldn't be reached for now: there is no connection, or it didn't answer in time.
    case unreachable
    /// The page couldn't be loaded, or loading it was stopped.
    case unavailable
}

/// Loads and keeps the previews of copied links while loading them is on, for the cards and rows that show them.
///
/// A link is loaded only when asked for, as a new copy or as a card or row shows it, and only once until its preview is
/// due again: a month after it was loaded, a day after its page gave nothing or loading it failed, ten minutes after it
/// couldn't be reached. A preview kept from before is shown at once, also while it is loaded again. At most two pages
/// load at once, the one asked for last first. The pictures of the latest previews asked for stay in memory; the rest
/// are read from the store again when asked for. The store is trimmed as a preview is asked for when it wasn't in the
/// last day, and after every 50 pages loaded; a preview shown from memory counts as used there, once a day.
@MainActor
@Observable
final class LinkPreviewCenter {
    /// A link to load: its address and what its preview is kept under.
    private struct Link: Sendable {
        let url: URL
        let key: String
    }

    /// What is known of each link asked for, by key.
    private var states: [String: LinkPreviewState] = [:]

    @ObservationIgnored private let loader: any LinkMetadataLoading
    @ObservationIgnored private let store: LinkPreviewStore
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let maximumLoads: Int
    @ObservationIgnored private let imagePixels: Int
    @ObservationIgnored private let maximumPictures: Int
    @ObservationIgnored private let trimEvery: Int
    /// When each preview known is due to be loaded again.
    @ObservationIgnored private var due: [String: Date] = [:]
    /// Pages waiting to be loaded. The last one goes first.
    @ObservationIgnored private var waiting: [Link] = []
    /// Pages being loaded, and previews being read from the store, by key, each with the token of its task.
    @ObservationIgnored private var loading: [String: UUID] = [:]
    @ObservationIgnored private var reading: [String: UUID] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The keys known, the one asked for last at the end.
    @ObservationIgnored private var recent: [String] = []
    /// The links addresses lead to, or nil for one that isn't loaded.
    @ObservationIgnored private var links: [String: Link?] = [:]
    /// Raised by `clear()`: what a task begun before it brings is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keptSinceTrim = 0
    /// When the store was last trimmed.
    @ObservationIgnored private var lastTrim: Date?
    /// When each preview known was last counted as used in the store.
    @ObservationIgnored private var touched: [String: Date] = [:]

    /// `isEnabled` says whether loading previews is on; `imagePixels` is the longer side of the pictures shown, and
    /// `maximumPictures` how many of them stay in memory. `trimEvery` is how many pages are loaded between trims.
    init(loader: any LinkMetadataLoading, store: LinkPreviewStore, isEnabled: @escaping @MainActor () -> Bool,
         now: @escaping @Sendable () -> Date = { Date() }, maximumLoads: Int = 2, imagePixels: Int = 480,
         maximumPictures: Int = 96, trimEvery: Int = 50) {
        self.loader = loader
        self.store = store
        self.isEnabled = isEnabled
        self.now = now
        self.maximumLoads = maximumLoads
        self.imagePixels = imagePixels
        self.maximumPictures = maximumPictures
        self.trimEvery = trimEvery
    }

    /// What is known of the preview of the link `address`. Nothing while loading previews is off.
    func state(of address: String) -> LinkPreviewState {
        guard isEnabled(), let link = link(for: address) else { return .notLoaded }
        return states[link.key] ?? .notLoaded
    }

    /// Asks for the preview of the link `address`: what was kept of it is read, and its page is loaded when nothing was
    /// kept or the preview is due again. Nothing happens while loading previews is off, or for a link that isn't
    /// loaded.
    func request(_ address: String) {
        guard isEnabled(), let link = link(for: address) else { return }
        if lastTrim.map({ now().timeIntervalSince($0) > 86_400 }) ?? true { trimStore() }
        use(link.key)
        // Asked for again while it waits, it goes first.
        if waiting.contains(where: { $0.key == link.key }) { return enqueue(link) }
        guard loading[link.key] == nil, reading[link.key] == nil else { return }
        guard states[link.key] != nil else { return read(link) }
        if let due = due[link.key], now() >= due { return enqueue(link) }
        if now().timeIntervalSince(touched[link.key] ?? .distantPast) > 86_400 {
            touched[link.key] = now()
            Task { [store, key = link.key] in await store.touch(key) }
        }
    }

    /// Forgets every preview, here and in the store, and drops the loads under way and waiting, as when loading
    /// previews is turned off.
    func clear() async {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks = [:]
        waiting = []
        loading = [:]
        reading = [:]
        states = [:]
        due = [:]
        recent = []
        touched = [:]
        await store.removeAll(before: generation)
    }

    // MARK: Reading and loading

    private func read(_ link: Link) {
        let token = UUID()
        reading[link.key] = token
        let generation = generation
        tasks[token] = Task { [weak self, store, imagePixels] in
            let kept = await store.kept(for: link.key, imagePixels: imagePixels)
            self?.didRead(kept, link: link, token: token, generation: generation)
        }
    }

    private func didRead(_ kept: KeptLinkPreview?, link: Link, token: UUID, generation: Int) {
        tasks[token] = nil
        guard reading[link.key] == token, generation == self.generation else { return }
        reading[link.key] = nil
        if let kept {
            show(kept, for: link.key)
            if now() >= kept.retryAfter { enqueue(link) }
        } else {
            states[link.key] = .loading
            enqueue(link)
        }
    }

    private func enqueue(_ link: Link) {
        waiting.removeAll { $0.key == link.key }
        waiting.append(link)
        startLoads()
    }

    /// Starts the waiting loads, the latest first, while fewer than the most are under way. Turned off, the waiting
    /// loads are dropped, and so is what is known of the links that had nothing to show, so that they are read again
    /// when asked for.
    private func startLoads() {
        guard isEnabled() else {
            for link in waiting where states[link.key] == .loading { states[link.key] = nil }
            waiting = []
            return
        }
        while loading.count < maximumLoads, let link = waiting.popLast() {
            let token = UUID()
            loading[link.key] = token
            let generation = generation
            tasks[token] = Task { [weak self, loader, store, imagePixels, now] in
                let kept: KeptLinkPreview
                do {
                    let metadata = try await loader.metadata(for: link.url)
                    kept = await store.keep(metadata, for: link.key, imagePixels: imagePixels, generation: generation)
                } catch {
                    let wait: TimeInterval = (error as? LinkMetadataError) == .unreachable ? 600 : 86_400
                    kept = await store.keepFailure(for: link.key, retryAfter: now().addingTimeInterval(wait),
                                                   imagePixels: imagePixels, generation: generation)
                }
                self?.didLoad(kept, key: link.key, token: token, generation: generation)
            }
        }
    }

    private func didLoad(_ kept: KeptLinkPreview, key: String, token: UUID, generation: Int) {
        tasks[token] = nil
        if loading[key] == token, generation == self.generation {
            loading[key] = nil
            show(kept, for: key)
            keptSinceTrim += 1
            if keptSinceTrim >= trimEvery { trimStore() }
        }
        startLoads()
    }

    private func trimStore() {
        lastTrim = now()
        keptSinceTrim = 0
        Task { [store] in await store.trim() }
    }

    private func show(_ kept: KeptLinkPreview, for key: String) {
        due[key] = kept.retryAfter
        touched[key] = now()
        // A preview shown stays when loading its page again fails, though the store no longer had it.
        if kept.outcome == .failed, let shown = states[key], Self.isLoaded(shown) { return }
        switch kept.outcome {
        case .loaded: states[key] = .loaded(LinkPreview(title: kept.title, image: kept.image, icon: kept.icon))
        case .empty: states[key] = .empty
        case .failed: states[key] = .failed
        }
        dropOldPictures()
    }

    private static func isLoaded(_ state: LinkPreviewState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    // MARK: Memory

    /// Makes `key` the one asked for last.
    private func use(_ key: String) {
        if let index = recent.lastIndex(of: key) { recent.remove(at: index) }
        recent.append(key)
        dropOldPictures()
    }

    /// Forgets the previews asked for longest ago while more pictures than the most are kept, and while very many
    /// previews are, other than those being read or loaded.
    private func dropOldPictures() {
        var pictures = recent.count(where: { states[$0]?.hasPicture == true })
        var index = 0
        while (pictures > maximumPictures || recent.count > 2_000), index < recent.count {
            let key = recent[index]
            let isBusy = loading[key] != nil || reading[key] != nil || waiting.contains(where: { $0.key == key })
            let hasPicture = states[key]?.hasPicture == true
            guard !isBusy, hasPicture || recent.count > 2_000 else {
                index += 1
                continue
            }
            states[key] = nil
            due[key] = nil
            touched[key] = nil
            recent.remove(at: index)
            if hasPicture { pictures -= 1 }
        }
    }

    /// The link `address` leads to, or nil for one that isn't loaded. Each address is worked out once.
    private func link(for address: String) -> Link? {
        if let known = links[address] { return known }
        let link: Link? = switch LinkAddress.loadable(address) {
        case .success(let url): Link(url: url, key: LinkAddress.key(for: url))
        case .failure: nil
        }
        if links.count >= 4_000 { links = [:] }
        links[address] = link
        return link
    }
}
