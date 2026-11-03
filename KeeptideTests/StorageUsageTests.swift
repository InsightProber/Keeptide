import Foundation
import XCTest
@testable import Keeptide

final class StorageUsageTests: XCTestCase {
    func testOutOfSpaceRecognizesOnlyStructuredErrorsIncludingUnderlyingFailures() {
        let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertTrue(DiskPressurePolicy.isOutOfSpace(full))
        XCTAssertTrue(DiskPressurePolicy.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: 134030,
            userInfo: [NSUnderlyingErrorKey: full])))
        XCTAssertTrue(DiskPressurePolicy.isOutOfSpace(NSError(domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteOutOfSpace.rawValue)))
        XCTAssertFalse(DiskPressurePolicy.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(DiskPressurePolicy.isOutOfSpace(NSError(domain: "synthetic", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "disk full"])))
    }

    func testScannerClassifiesAllocatedStorageAndDeduplicatesHardLinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let content = try write(Data(repeating: 1, count: 8_193), to: root.appendingPathComponent("Content.sqlite"))
        let contentWAL = try write(Data(repeating: 2, count: 4_097), to: root.appendingPathComponent("Content.sqlite-wal"))
        let contentSHM = try write(Data(repeating: 3, count: 1_025), to: root.appendingPathComponent("Content.sqlite-shm"))
        let local = try write(Data(repeating: 4, count: 2_049), to: root.appendingPathComponent("Local.sqlite"))
        let localWAL = try write(Data(repeating: 5, count: 3_073), to: root.appendingPathComponent("Local.sqlite-wal"))
        let localSHM = try write(Data(repeating: 6, count: 1_537), to: root.appendingPathComponent("Local.sqlite-shm"))
        let external = try write(Data(repeating: 7, count: 5_121), to: root.appendingPathComponent("Content_SUPPORT/_EXTERNAL_DATA/payload"))
        let draft = try write(Data(repeating: 8, count: 6_145), to: root.appendingPathComponent("Drafts/draft.json"))
        let search = try write(Data(repeating: 9, count: 7_169), to: root.appendingPathComponent("Search/Search.sqlite"))
        let searchWAL = try write(Data(repeating: 10, count: 2_561), to: root.appendingPathComponent("Search/Search.sqlite-wal"))
        let searchSHM = try write(Data(repeating: 11, count: 1_281), to: root.appendingPathComponent("Search/Search.sqlite-shm"))
        let unknown = try write(Data(repeating: 9, count: 9_217), to: root.appendingPathComponent("future/cache.bin"))
        try FileManager.default.linkItem(at: unknown, to: root.appendingPathComponent("future/cache-hardlink.bin"))

        let report = StorageUsageScanner().scan(libraryRoot: root)

        XCTAssertFalse(report.isPartialCoverage)
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report[.contentDatabase], try allocatedSize(of: content) + allocatedSize(of: contentWAL)
                       + allocatedSize(of: contentSHM))
        XCTAssertEqual(report[.localDatabase], try allocatedSize(of: local) + allocatedSize(of: localWAL)
                       + allocatedSize(of: localSHM))
        XCTAssertEqual(report[.externalData], try allocatedSize(of: external))
        XCTAssertEqual(report[.drafts], try allocatedSize(of: draft))
        XCTAssertEqual(report[.search], try allocatedSize(of: search) + allocatedSize(of: searchWAL)
                       + allocatedSize(of: searchSHM))
        XCTAssertEqual(report[.unknown], try allocatedSize(of: unknown), "Hard links count once")
        XCTAssertEqual(report.totalAllocatedBytes, StorageUsageCategory.allCases.reduce(0) { $0 + report[$1] })
    }

    func testScannerSkipsSymbolicLinksAndReportsPartialCoverage() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = try write(Data(repeating: 1, count: 16_385), to: outside.appendingPathComponent("private.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link"),
            withDestinationURL: outsideFile
        )

        let report = StorageUsageScanner().scan(libraryRoot: root)

        XCTAssertTrue(report.isPartialCoverage)
        XCTAssertEqual(report.totalAllocatedBytes, 0)
        XCTAssertEqual(report.issues, [StorageUsageIssue(relativePath: "outside-link", reason: .symbolicLinkSkipped)])
    }

    func testMissingLibraryReturnsAnExplicitCoverageError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-missing-\(UUID().uuidString)", isDirectory: true)

        let report = StorageUsageScanner().scan(libraryRoot: root)

        XCTAssertTrue(report.isPartialCoverage)
        XCTAssertEqual(report.totalAllocatedBytes, 0)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(report.issues.first?.relativePath, ".")
        XCTAssertEqual(report.issues.first?.reason, .unreadable)
    }

    func testDiskPressureWarningCanBeAdjustedOrDisabledWithoutAQuota() {
        let usage = StorageUsageReport(
            allocatedBytes: [.contentDatabase: 3 * 1_024 * 1_024 * 1_024],
            issues: []
        )

        XCTAssertNotNil(DiskPressurePolicy(warningLimitBytes: 2 * 1_024 * 1_024 * 1_024).assess(usage).warning)
        XCTAssertNil(DiskPressurePolicy(warningLimitBytes: 4 * 1_024 * 1_024 * 1_024).assess(usage).warning)
        XCTAssertNil(DiskPressurePolicy(warningLimitBytes: nil).assess(usage).warning)
        XCTAssertNil(DiskPressurePolicy(warningLimitBytes: nil).assess(usage).writeFailureAction)
    }

    func testWriteFailureEvictsOnlyDerivedSearchOrPausesWhilePreservingDrafts() {
        let withSearch = StorageUsageReport(
            allocatedBytes: [.contentDatabase: 10_000, .drafts: 2_000, .search: 3_000],
            issues: []
        )
        let withoutSearch = StorageUsageReport(
            allocatedBytes: [.contentDatabase: 10_000, .drafts: 2_000],
            issues: []
        )
        let policy = DiskPressurePolicy(warningLimitBytes: nil)

        XCTAssertEqual(
            policy.assess(withSearch, writeFailedForLackOfSpace: true).writeFailureAction,
            .evictSearchIndex(reclaimableBytes: 3_000)
        )
        XCTAssertEqual(
            policy.assess(withoutSearch, writeFailedForLackOfSpace: true).writeFailureAction,
            .pauseWritesPreservingDrafts
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ data: Data, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func allocatedSize(of url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
