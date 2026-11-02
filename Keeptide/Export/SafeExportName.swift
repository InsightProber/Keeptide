import Foundation
import UniformTypeIdentifiers

enum SafeExportName {
    static func payloadPath(for id: UUID, typeIdentifier: String) -> String {
        "payloads/\(id.uuidString.lowercased()).\(safeExtension(typeIdentifier))"
    }

    static func readablePath(ordinal: Int, ref: ContentRef, kind: ArchiveContentKind) -> String {
        let facet = ref.facet == .history ? "history" : "memo"
        let ext = kind == .markdown ? "md" : "txt"
        return String(format: "readable/%06d-%@-%@.%@", ordinal,
                      ref.itemID.rawValue.uuidString.lowercased(), facet, ext)
    }

    static func exportDirectoryName(createdAt: Date, exportID: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Keeptide Export \(formatter.string(from: createdAt))-\(exportID.uuidString.prefix(8).lowercased())"
    }

    private static func safeExtension(_ typeIdentifier: String) -> String {
        guard let candidate = UTType(typeIdentifier)?.preferredFilenameExtension?.lowercased(),
              (1...16).contains(candidate.utf8.count),
              candidate.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }) else {
            return "bin"
        }
        return candidate
    }
}
