import Foundation

struct ResolvedFilePreviewBookmark: Equatable, Sendable {
    var url: URL
    var isStale: Bool
}

protocol FilePreviewAccessPlatform: AnyObject {
    func resolveBookmark(_ data: Data) throws -> ResolvedFilePreviewBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func makeReadOnlyBookmark(for url: URL) throws -> Data
}

// Construction finishes before this lease crosses executors. Its immutable URL
// and bookmark are Sendable; the only mutable state is the locked, one-shot close.
final class FilePreviewAccessLease: @unchecked Sendable {
    let url: URL
    let refreshedBookmarkData: Data?
    private let platform: FilePreviewAccessPlatform
    private let stateLock = NSLock()
    private var ownsScope = true

    private init(
        url: URL,
        refreshedBookmarkData: Data?,
        platform: FilePreviewAccessPlatform
    ) {
        self.url = url
        self.refreshedBookmarkData = refreshedBookmarkData
        self.platform = platform
    }

    static func open(
        /// Opaque local bookmark descriptor. It is never interpreted as preview payload bytes.
        bookmarkData: Data,
        platform: FilePreviewAccessPlatform = SystemFilePreviewAccessPlatform(),
        isCancelled: () -> Bool = { false }
    ) throws -> FilePreviewAccessLease {
        guard !isCancelled() else { throw FilePreviewAccessError.cancelled }
        let resolved = try platform.resolveBookmark(bookmarkData)
        guard !isCancelled() else { throw FilePreviewAccessError.cancelled }
        guard resolved.url.isFileURL else { throw FilePreviewAccessError.nonFileURL }
        guard platform.startAccessing(resolved.url) else {
            throw FilePreviewAccessError.accessDenied
        }

        var mustStop = true
        defer {
            if mustStop { platform.stopAccessing(resolved.url) }
        }
        guard !isCancelled() else { throw FilePreviewAccessError.cancelled }
        let refreshedBookmarkData = resolved.isStale
            ? try platform.makeReadOnlyBookmark(for: resolved.url)
            : nil
        guard !isCancelled() else { throw FilePreviewAccessError.cancelled }

        let lease = FilePreviewAccessLease(
            url: resolved.url,
            refreshedBookmarkData: refreshedBookmarkData,
            platform: platform
        )
        mustStop = false
        return lease
    }

    func close() {
        stateLock.lock()
        guard ownsScope else {
            stateLock.unlock()
            return
        }
        ownsScope = false
        stateLock.unlock()
        platform.stopAccessing(url)
    }

    deinit {
        close()
    }
}

enum FilePreviewAccessError: Error, Equatable {
    case cancelled
    case nonFileURL
    case accessDenied
}

final class SystemFilePreviewAccessPlatform: FilePreviewAccessPlatform {
    func resolveBookmark(_ data: Data) throws -> ResolvedFilePreviewBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedFilePreviewBookmark(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func makeReadOnlyBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
