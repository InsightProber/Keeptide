import Foundation
import LinkPresentation
import UniformTypeIdentifiers

/// Loads a page's title, picture and icon with the system's LinkPresentation, which fetches the page and what it names
/// for its picture and icon. Only the app builds one: a test that did would reach a real website.
struct SystemLinkMetadataLoader: LinkMetadataLoading {
    /// How long a page has to answer, in seconds.
    var timeout: TimeInterval = 15
    /// The largest picture, and the largest icon, read, in bytes. A larger one is left out.
    var largestPicture = 8 * 1024 * 1024
    var largestIcon = 1024 * 1024
    /// How long a picture or an icon the page named has to arrive, in seconds; one that doesn't is left out.
    var pictureTimeout: TimeInterval = 10

    func metadata(for url: URL) async throws -> LinkPageMetadata {
        // Stopped before it starts, nothing is fetched: a cancellation that came first has nothing to cancel.
        guard !Task.isCancelled else { throw LinkMetadataError.unavailable }
        let fetch = Fetch(timeout: timeout)
        let metadata: LPLinkMetadata
        do {
            metadata = try await withTaskCancellationHandler {
                try await fetch.provider.startFetchingMetadata(for: url)
            } onCancel: {
                fetch.provider.cancel()
            }
        } catch {
            throw Self.reason(for: error)
        }
        // The picture and the icon arrive together.
        let picture = Provided(provider: metadata.imageProvider), icon = Provided(provider: metadata.iconProvider)
        async let pictureData = ItemProviderImage.data(of: picture.provider, largest: largestPicture,
                                                       timeout: pictureTimeout)
        async let iconData = ItemProviderImage.data(of: icon.provider, largest: largestIcon, timeout: pictureTimeout)
        let page = LinkPageMetadata(title: metadata.title, image: await pictureData, icon: await iconData)
        // Stopped while the picture was read, it is stopped: a page without the picture it has isn't kept.
        guard !Task.isCancelled else { throw LinkMetadataError.unavailable }
        return page
    }

    /// What LinkPresentation handed over for a picture or an icon, which may be read from any thread.
    private struct Provided: @unchecked Sendable {
        let provider: NSItemProvider?
    }

    /// The provider of one fetch, which may be cancelled from any thread.
    private final class Fetch: @unchecked Sendable {
        let provider = LPMetadataProvider()

        init(timeout: TimeInterval) {
            provider.timeout = timeout
        }
    }

    /// Whether a failed fetch may work again soon: no connection, a lost one, or no answer in time, which the
    /// failure itself or one it wraps says. Anything else is the page's.
    static func reason(for error: any Error) -> LinkMetadataError {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == LPErrorDomain, error.code == LPError.Code.metadataFetchTimedOut.rawValue {
                return .unreachable
            }
            if error.domain == NSURLErrorDomain, [
                NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
            ].contains(error.code) {
                return .unreachable
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unavailable
    }
}

/// Reads the image an item provider holds, as LinkPresentation hands over a page's picture and icon.
enum ItemProviderImage {
    /// The image `provider` holds, as its website sent it, or nil when it has none, it is larger than `largest` bytes,
    /// or it doesn't arrive within `timeout` seconds. Cancelled, it stops waiting at once, and the load still under way
    /// is stopped; cancelled before it begins, nothing is loaded.
    static func data(of provider: NSItemProvider?, largest: Int, timeout: TimeInterval) async -> Data? {
        guard let provider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let answer = Answer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard answer.wait(with: continuation) else { return }
                let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    answer.give(data.flatMap { $0.count <= largest ? $0 : nil })
                }
                answer.keep(progress)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer.give(nil) }
            }
        } onCancel: {
            answer.give(nil)
        }
    }

    /// The one answer to a wait, whichever comes first: the image, nothing when the time runs out, or nothing when the
    /// wait is cancelled, which can come before the wait begins. The load is stopped once there is an answer.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var isAnswered = false
        private var progress: Progress?

        /// Waits for the answer with `continuation`, and says whether to load: not when the answer, which can only be
        /// nothing then, came before, which resumes `continuation` at once.
        func wait(with continuation: CheckedContinuation<Data?, Never>) -> Bool {
            let answered = lock.withLock {
                if !isAnswered { self.continuation = continuation }
                return isAnswered
            }
            if answered { continuation.resume(returning: nil) }
            return !answered
        }

        func keep(_ progress: Progress) {
            let answered = lock.withLock {
                if !isAnswered { self.progress = progress }
                return isAnswered
            }
            if answered { progress.cancel() }
        }

        func give(_ data: Data?) {
            let (waiting, loading): (CheckedContinuation<Data?, Never>?, Progress?) = lock.withLock {
                guard !isAnswered else { return (nil, nil) }
                isAnswered = true
                defer {
                    continuation = nil
                    progress = nil
                }
                return (continuation, progress)
            }
            waiting?.resume(returning: data)
            loading?.cancel()
        }
    }
}
