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

    /// The legacy `NSFilenamesPboardType` and the dynamic identifiers the system gives it. Its payload
    /// is a property list of the full paths of the files.
    static let filenamesListIdentifiers: Set<String> = [
        "nsfilenamespboardtype",
        // Dynamic UTI produced by the system for NSFilenamesPboardType.
        "dyn.agu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",
        "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"
    ]

    private static let unconditionalIdentifiers: Set<String> = filenamesListIdentifiers.union([
        UTType.fileURL.identifier,
        "com.apple.pasteboard.promised-file-url",
        "com.apple.alias-record",
        "com.apple.alias-file",
        "com.apple.bookmark",
        "com.apple.security.bookmark",
        "com.apple.cocoa.pasteboard.alias",
        "com.apple.cocoa.pasteboard.bookmark",
        "public.bookmark"
    ])

    private static let urlPayloadIdentifiers: Set<String> = [
        UTType.url.identifier,
        "apple url pasteboard type",
        "corepasteboardflavortype 0x6675726c",
        // Dynamic UTIs produced by the system for the two legacy URL pasteboard tags above.
        "dyn.agu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
        "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
        "dyn.agu8yg55wqzkgc65yqzvg82pwqvdg22p0r73fk8puqyuda8b0g25xnr3wg3bu"
    ]

    private static func urlPayloadMustRemainLocal(_ bytes: Data) -> Bool {
        if let propertyList = try? PropertyListSerialization.propertyList(
            from: bytes,
            options: [],
            format: nil
        ) {
            return propertyListMustRemainLocal(propertyList)
        }

        return candidatesMustRemainLocal(decodedStrings(bytes))
    }

    private static func propertyListMustRemainLocal(_ value: Any) -> Bool {
        let candidates: [String]
        if let string = value as? String {
            candidates = [string]
        } else if let values = value as? [Any], !values.isEmpty,
                  values.allSatisfy({ $0 is String }) {
            candidates = values.compactMap { $0 as? String }
        } else {
            // Legacy URL producers use a string or a string array. Dictionaries,
            // binary leaves, numbers and mixed arrays have no unambiguous URL-only
            // contract, so never let their ignored fields escape as cloud content.
            return true
        }
        return candidatesMustRemainLocal(candidates)
    }

    private static func candidatesMustRemainLocal(_ candidates: [String]) -> Bool {
        var foundPortableURL = false
        for string in candidates {
            guard let classification = classifyCandidate(string) else { continue }
            switch classification {
            case .localOrAmbiguous:
                return true
            case .portable:
                foundPortableURL = true
            }
        }
        return !foundPortableURL
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

        if let value = String(data: bytes, encoding: .utf8) {
            result.append(value)
        } else if bytes.count.isMultiple(of: 2) {
            append(bytes, encoding: .utf16LittleEndian)
            append(bytes, encoding: .utf16BigEndian)
        }
        return result
    }

    private enum URLClassification {
        case portable
        case localOrAmbiguous
    }

    private static func classifyCandidate(_ string: String) -> URLClassification? {
        var candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.unicodeScalars.last?.value == 0 { candidate.removeLast() }
        guard !candidate.isEmpty else { return nil }
        guard !candidate.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return .localOrAmbiguous
        }

        let components = candidate.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        guard !components.isEmpty else { return nil }
        var foundPortable = false
        for component in components {
            let value = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if isPathLike(value) { return .localOrAmbiguous }
            guard let url = URL(string: value),
                  let scheme = url.scheme,
                  !scheme.isEmpty else {
                return .localOrAmbiguous
            }
            if url.isFileURL || scheme.count == 1 { return .localOrAmbiguous }
            foundPortable = true
        }
        return foundPortable ? .portable : nil
    }

    private static func isPathLike(_ string: String) -> Bool {
        if string.hasPrefix("/") || string.hasPrefix("~/")
            || string.hasPrefix("\\\\") || string.hasPrefix("//") {
            return true
        }
        let scalars = Array(string.unicodeScalars)
        return scalars.count >= 3
            && scalars[0].properties.isAlphabetic
            && scalars[1].value == 58
            && (scalars[2].value == 47 || scalars[2].value == 92)
    }
}
