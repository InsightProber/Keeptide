import Foundation

/// Conservative identity checks for local file-reference descriptor bytes.
/// A bookmark or opened security-scoped URL is usable only when it still names
/// the same standardized file URL that copying will publish.
enum FileReferenceIdentity {
    static func matches(_ access: LocalFileAccess, candidateURL: URL) -> Bool {
        matches(descriptorBytes: access.bytes, candidateURL: candidateURL)
    }

    static func matches(descriptorBytes: Data, candidateURL: URL) -> Bool {
        guard let descriptor = String(data: descriptorBytes, encoding: .utf8),
              descriptor.utf8.elementsEqual(descriptorBytes),
              !descriptor.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              let descriptorURL = URL(string: descriptor),
              let expected = standardizedFileURL(descriptorURL),
              let candidate = standardizedFileURL(candidateURL) else {
            return false
        }
        return expected == candidate
    }

    static func standardizedFileURL(_ url: URL) -> URL? {
        guard url.isFileURL,
              !url.absoluteString.utf8.contains(0),
              !url.path.utf8.contains(0) else { return nil }
        let foundationURL = url as NSURL
        let resolved: URL
        if foundationURL.isFileReferenceURL() {
            guard let pathURL = foundationURL.filePathURL else { return nil }
            resolved = pathURL
        } else {
            resolved = url
        }
        guard resolved.isFileURL,
              resolved.path.hasPrefix("/"),
              !resolved.path.isEmpty,
              !resolved.path.utf8.contains(0) else { return nil }
        return resolved.standardizedFileURL
    }
}
