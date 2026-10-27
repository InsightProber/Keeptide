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
        return bytes.map(payloadContainsFileURL) ?? false
    }

    private static let unconditionalIdentifiers: Set<String> = [
        UTType.fileURL.identifier,
        "nsfilenamespboardtype",
        "com.apple.pasteboard.promised-file-url",
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

    private static func payloadContainsFileURL(_ bytes: Data) -> Bool {
        if let string = String(data: bytes, encoding: .utf8), isFileURL(string) {
            return true
        }
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: bytes,
            options: [],
            format: nil
        ) else {
            return false
        }
        return propertyListContainsFileURL(propertyList)
    }

    private static func propertyListContainsFileURL(_ value: Any) -> Bool {
        switch value {
        case let string as String:
            isFileURL(string)
        case let values as [Any]:
            values.contains(where: propertyListContainsFileURL)
        case let values as [String: Any]:
            values.values.contains(where: propertyListContainsFileURL)
        default:
            false
        }
    }

    private static func isFileURL(_ string: String) -> Bool {
        let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: candidate)?.isFileURL == true
    }
}
