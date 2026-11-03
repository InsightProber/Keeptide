import Foundation
import XCTest
@testable import Keeptide

final class FilePreviewAccessTests: XCTestCase {
    func testSuccessfulLeaseStartsOnceAndExplicitCloseStopsExactlyOnce() throws {
        let platform = FakeFilePreviewAccessPlatform(url: fileURL)
        let input = Data("bookmark descriptor, not file content".utf8)

        let lease = try FilePreviewAccessLease.open(bookmarkData: input, platform: platform)
        XCTAssertEqual(lease.url, fileURL)
        XCTAssertEqual(platform.resolvedData, input)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 0)
        XCTAssertEqual(platform.refreshCount, 0)
        XCTAssertNil(lease.refreshedBookmarkData)

        lease.close()
        lease.close()
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testDeinitBalancesAnOpenScopeExactlyOnce() throws {
        let platform = FakeFilePreviewAccessPlatform(url: fileURL)
        var lease: FilePreviewAccessLease? = try FilePreviewAccessLease.open(
            bookmarkData: Data([1]), platform: platform
        )
        XCTAssertNotNil(lease)

        lease = nil

        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testResolutionFailureAndNonFileURLNeverStartOrStop() {
        let resolutionFailure = FakeFilePreviewAccessPlatform(url: fileURL)
        resolutionFailure.resolveError = TestError.expected
        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([1]), platform: resolutionFailure
        ))
        XCTAssertEqual(resolutionFailure.startCount, 0)
        XCTAssertEqual(resolutionFailure.stopCount, 0)

        let nonFile = FakeFilePreviewAccessPlatform(url: URL(string: "https://example.invalid/file")!)
        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([2]), platform: nonFile
        )) { XCTAssertEqual($0 as? FilePreviewAccessError, .nonFileURL) }
        XCTAssertEqual(nonFile.startCount, 0)
        XCTAssertEqual(nonFile.stopCount, 0)
    }

    func testFailedStartDoesNotStopAnUnownedScope() {
        let platform = FakeFilePreviewAccessPlatform(url: fileURL)
        platform.startResult = false

        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([1]), platform: platform
        )) { XCTAssertEqual($0 as? FilePreviewAccessError, .accessDenied) }
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 0)
    }

    func testStaleBookmarkRefreshesWhileScopeIsHeld() throws {
        let platform = FakeFilePreviewAccessPlatform(url: fileURL, isStale: true)
        platform.refreshedData = Data("read-only refreshed bookmark".utf8)

        let lease = try FilePreviewAccessLease.open(bookmarkData: Data([1]), platform: platform)

        XCTAssertEqual(lease.refreshedBookmarkData, platform.refreshedData)
        XCTAssertEqual(platform.startCountSeenByRefresh, 1)
        XCTAssertEqual(platform.stopCountSeenByRefresh, 0)
        lease.close()
    }

    func testRefreshFailureStopsTheOwnedScope() {
        let platform = FakeFilePreviewAccessPlatform(url: fileURL, isStale: true)
        platform.refreshError = TestError.expected

        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([1]), platform: platform
        ))
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.stopCount, 1)
    }

    func testCancellationBeforeStartDoesNotAcquireScope() {
        let platform = FakeFilePreviewAccessPlatform(url: fileURL)
        let cancellation = CancellationSequence(cancelOnCheck: 2)

        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([1]), platform: platform, isCancelled: cancellation.check
        )) { XCTAssertEqual($0 as? FilePreviewAccessError, .cancelled) }
        XCTAssertEqual(platform.startCount, 0)
        XCTAssertEqual(platform.stopCount, 0)
    }

    func testCancellationAfterStartAndAfterRefreshBalancesScope() {
        let afterStart = FakeFilePreviewAccessPlatform(url: fileURL)
        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([1]),
            platform: afterStart,
            isCancelled: CancellationSequence(cancelOnCheck: 3).check
        ))
        XCTAssertEqual(afterStart.startCount, 1)
        XCTAssertEqual(afterStart.stopCount, 1)

        let afterRefresh = FakeFilePreviewAccessPlatform(url: fileURL, isStale: true)
        XCTAssertThrowsError(try FilePreviewAccessLease.open(
            bookmarkData: Data([1]),
            platform: afterRefresh,
            isCancelled: CancellationSequence(cancelOnCheck: 4).check
        ))
        XCTAssertEqual(afterRefresh.refreshCount, 1)
        XCTAssertEqual(afterRefresh.stopCount, 1)
    }

    private var fileURL: URL {
        URL(fileURLWithPath: "/private/tmp/keeptide-preview-synthetic.txt")
    }
}

private enum TestError: Error {
    case expected
}

private final class CancellationSequence {
    private let cancelOnCheck: Int
    private var count = 0

    init(cancelOnCheck: Int) {
        self.cancelOnCheck = cancelOnCheck
    }

    func check() -> Bool {
        count += 1
        return count == cancelOnCheck
    }
}

private final class FakeFilePreviewAccessPlatform: FilePreviewAccessPlatform {
    var resolvedData: Data?
    var resolveError: Error?
    var startResult = true
    var refreshedData = Data([9])
    var refreshError: Error?
    private let resolution: ResolvedFilePreviewBookmark

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    private(set) var startCountSeenByRefresh: Int?
    private(set) var stopCountSeenByRefresh: Int?

    init(url: URL, isStale: Bool = false) {
        resolution = ResolvedFilePreviewBookmark(url: url, isStale: isStale)
    }

    func resolveBookmark(_ data: Data) throws -> ResolvedFilePreviewBookmark {
        resolvedData = data
        if let resolveError { throw resolveError }
        return resolution
    }

    func startAccessing(_ url: URL) -> Bool {
        startCount += 1
        return startResult
    }

    func stopAccessing(_ url: URL) {
        stopCount += 1
    }

    func makeReadOnlyBookmark(for url: URL) throws -> Data {
        refreshCount += 1
        startCountSeenByRefresh = startCount
        stopCountSeenByRefresh = stopCount
        if let refreshError { throw refreshError }
        return refreshedData
    }
}
