import Foundation

enum StorageUsageCategory: String, CaseIterable, Sendable {
    case contentDatabase
    case localDatabase
    case externalData
    case drafts
    case search
    case unknown
}

struct StorageUsageIssue: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case symbolicLinkSkipped
        case unreadable
        case metadataUnavailable
    }

    let relativePath: String
    let reason: Reason
}

struct StorageUsageReport: Equatable, Sendable {
    let allocatedBytes: [StorageUsageCategory: UInt64]
    let issues: [StorageUsageIssue]

    init(allocatedBytes: [StorageUsageCategory: UInt64] = [:], issues: [StorageUsageIssue]) {
        self.allocatedBytes = allocatedBytes
        self.issues = issues
    }

    subscript(category: StorageUsageCategory) -> UInt64 { allocatedBytes[category, default: 0] }

    var totalAllocatedBytes: UInt64 {
        StorageUsageCategory.allCases.reduce(0) { $0 + self[$1] }
    }

    var isPartialCoverage: Bool { !issues.isEmpty }
}

/// A read-only inventory of files below one Keeptide library root. Symbolic links are never followed, and files that
/// share a filesystem identity are counted once. A report with issues is a lower bound, never a claim of full usage.
struct StorageUsageScanner {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileResourceIdentifierKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
    ]

    func scan(libraryRoot: URL) -> StorageUsageReport {
        let root = libraryRoot.standardizedFileURL
        var allocated: [StorageUsageCategory: UInt64] = [:]
        var issues: [StorageUsageIssue] = []
        var identities: Set<AnyHashable> = []

        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            return StorageUsageReport(
                issues: [StorageUsageIssue(relativePath: ".", reason: .unreadable)]
            )
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [],
            errorHandler: { url, _ in
                issues.append(StorageUsageIssue(relativePath: relativePath(of: url, below: root), reason: .unreadable))
                return true
            }
        ) else {
            return StorageUsageReport(
                issues: [StorageUsageIssue(relativePath: ".", reason: .unreadable)]
            )
        }

        for case let url as URL in enumerator {
            let relative = relativePath(of: url, below: root)
            guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else {
                issues.append(StorageUsageIssue(relativePath: relative, reason: .unreadable))
                continue
            }
            if values.isSymbolicLink == true {
                issues.append(StorageUsageIssue(relativePath: relative, reason: .symbolicLinkSkipped))
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }

            if let identity = values.fileResourceIdentifier as? AnyHashable {
                guard identities.insert(identity).inserted else { continue }
            } else {
                issues.append(StorageUsageIssue(relativePath: relative, reason: .metadataUnavailable))
            }

            guard let rawSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize, rawSize >= 0 else {
                issues.append(StorageUsageIssue(relativePath: relative, reason: .metadataUnavailable))
                continue
            }
            allocated[category(for: relative), default: 0] += UInt64(rawSize)
        }

        return StorageUsageReport(allocatedBytes: allocated, issues: issues)
    }
}

private func relativePath(of url: URL, below root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return "." }
    return String(path.dropFirst(rootPath.count + 1))
}

private func category(for relativePath: String) -> StorageUsageCategory {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let first = components.first else { return .unknown }
    if ["Content.sqlite", "Content.sqlite-wal", "Content.sqlite-shm"].contains(first) {
        return .contentDatabase
    }
    if ["Local.sqlite", "Local.sqlite-wal", "Local.sqlite-shm"].contains(first) {
        return .localDatabase
    }
    if ["Content_SUPPORT", "ExternalData", "_EXTERNAL_DATA"].contains(first)
        || components.contains("_EXTERNAL_DATA") {
        return .externalData
    }
    if first == "Drafts" { return .drafts }
    if first == "Search" { return .search }
    return .unknown
}
