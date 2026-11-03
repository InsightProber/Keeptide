import Foundation
import Darwin

struct DiskPressurePolicy: Equatable, Sendable {
    /// Inspect structured error domains only; never infer a destructive recovery action from message text.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        while !pending.isEmpty, visited.count < 32 {
            let next = pending.removeLast()
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            if next.domain == NSCocoaErrorDomain && next.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
            if next.domain == NSPOSIXErrorDomain && [Int(ENOSPC), Int(EDQUOT)].contains(next.code) { return true }
            if next.domain == "NSSQLiteErrorDomain" && next.code == 13 { return true } // SQLITE_FULL
            if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let detailed = next.userInfo["NSDetailedErrors"] as? [NSError] { pending.append(contentsOf: detailed.prefix(32)) }
        }
        return false
    }

    static let defaultWarningLimitBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    var warningLimitBytes: UInt64?

    init(warningLimitBytes: UInt64? = defaultWarningLimitBytes) {
        self.warningLimitBytes = warningLimitBytes
    }

    func assess(
        _ usage: StorageUsageReport,
        writeFailedForLackOfSpace: Bool = false
    ) -> DiskPressureAssessment {
        let warning = warningLimitBytes.flatMap { limit in
            usage.totalAllocatedBytes >= limit
                ? DiskPressureWarning(allocatedBytes: usage.totalAllocatedBytes, warningLimitBytes: limit,
                                      isLowerBound: usage.isPartialCoverage)
                : nil
        }
        let action: DiskPressureWriteFailureAction?
        if writeFailedForLackOfSpace {
            let searchBytes = usage[.search]
            action = searchBytes > 0
                ? .evictSearchIndex(reclaimableBytes: searchBytes)
                : .pauseWritesPreservingDrafts
        } else {
            action = nil
        }
        return DiskPressureAssessment(warning: warning, writeFailureAction: action)
    }
}

struct DiskPressureAssessment: Equatable, Sendable {
    let warning: DiskPressureWarning?
    let writeFailureAction: DiskPressureWriteFailureAction?
}

struct DiskPressureWarning: Equatable, Sendable {
    let allocatedBytes: UInt64
    let warningLimitBytes: UInt64
    /// True when unreadable or intentionally skipped paths mean the measured size is only a lower bound.
    let isLowerBound: Bool
}

/// Recommendations only. The policy can name the rebuildable search index, but cannot express eviction of primary
/// content, permanent items, or drafts.
enum DiskPressureWriteFailureAction: Equatable, Sendable {
    case evictSearchIndex(reclaimableBytes: UInt64)
    case pauseWritesPreservingDrafts
}
