import Foundation
import UniformTypeIdentifiers

enum SystemFileReferenceClassifier {
    static func isLocalFileReference(typeIdentifier: String, bytes: Data?) -> Bool {
        let normalizedIdentifier = typeIdentifier.lowercased()
        if unconditionalIdentifiers.contains(normalizedIdentifier) {
            return true
        }

        let type = UTType(typeIdentifier) ?? UTType(normalizedIdentifier)
        if type?.conforms(to: .fileURL) == true {
            return true
        }

        guard urlPayloadIdentifiers.contains(normalizedIdentifier)
                || type?.conforms(to: .url) == true else {
            return false
        }
        guard let bytes else { return true }
        return urlPayloadMustRemainLocal(bytes)
    }

    private static let unconditionalIdentifiers: Set<String> = [
        UTType.fileURL.identifier,
        "nsfilenamespboardtype",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.alias-record",
        "com.apple.alias-file",
        "com.apple.bookmark",
        "com.apple.security.bookmark",
        "com.apple.cocoa.pasteboard.alias",
        "com.apple.cocoa.pasteboard.bookmark",
        "public.bookmark",
        // Dynamic UTI produced by the system for NSFilenamesPboardType.
        "dyn.agu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"
    ]

    private static let urlPayloadIdentifiers: Set<String> = [
        UTType.url.identifier,
        "apple url pasteboard type",
        "corepasteboardflavortype 0x6675726c",
        // Dynamic UTIs produced by the system for the two legacy URL pasteboard tags above.
        "dyn.agu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
        "dyn.agu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0g25xnr3wg3bu"
    ]

    private static func urlPayloadMustRemainLocal(_ bytes: Data) -> Bool {
        var candidates = decodedStrings(bytes)
        if let propertyList = try? PropertyListSerialization.propertyList(
            from: bytes,
            options: [],
            format: nil
        ) {
            appendStrings(in: propertyList, to: &candidates)
        }

        var foundPortableURL = false
        for string in candidates {
            guard let url = parsedAbsoluteURL(string) else { continue }
            if url.isFileURL { return true }
            foundPortableURL = true
        }
        return !foundPortableURL
    }

    private static func appendStrings(in value: Any, to result: inout [String]) {
        switch value {
        case let string as String:
            result.append(string)
        case let values as [Any]:
            values.forEach { appendStrings(in: $0, to: &result) }
        case let values as [String: Any]:
            values.values.forEach { appendStrings(in: $0, to: &result) }
        default:
            break
        }
    }

    private static func decodedStrings(_ bytes: Data) -> [String] {
        var result: [String] = []
        func append(_ data: Data, encoding: String.Encoding) {
            if let value = String(data: data, encoding: encoding), !result.contains(value) {
                result.append(value)
            }
        }

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            append(bytes.dropFirst(3), encoding: .utf8)
            return result
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            append(bytes.dropFirst(2), encoding: .utf16LittleEndian)
            return result
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            append(bytes.dropFirst(2), encoding: .utf16BigEndian)
            return result
        }

        append(bytes, encoding: .utf8)
        if bytes.count.isMultiple(of: 2) {
            append(bytes, encoding: .utf16LittleEndian)
            append(bytes, encoding: .utf16BigEndian)
        }
        return result
    }

    private static func parsedAbsoluteURL(_ string: String) -> URL? {
        let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.unicodeScalars.contains(where: { $0.value == 0 }),
              let url = URL(string: candidate),
              url.scheme?.isEmpty == false else {
            return nil
        }
        return url
    }
}
