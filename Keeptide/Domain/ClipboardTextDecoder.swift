import Foundation

struct ClipTextPreview: Equatable, Sendable {
    let text: String
    let isTruncated: Bool
}

enum ClipboardTextDecoder {
    private static let supportedTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
        "public.plain-text",
        "public.url",
        "nsstringpboardtype",
        "corepasteboardflavortype 0x75743136",
    ]

    nonisolated static func title(_ items: [CapturedPasteboardItem]) -> String? {
        for item in items {
            for representation in item.representations {
                guard let decoded = decode(
                    representation.bytes,
                    typeIdentifier: representation.typeIdentifier,
                    maximumBytes: 4_096
                ) else { continue }
                let line = decoded.text
                    .split(whereSeparator: \.isNewline)
                    .lazy
                    .map { sanitize(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let line { return String(line.prefix(160)) }
            }
        }
        return nil
    }

    nonisolated static func preview(
        _ representations: [RepresentationValue],
        maximumBytes: Int = 8_192
    ) -> ClipTextPreview? {
        for representation in representations {
            guard let bytes = representation.bytes,
                  let decoded = decodeText(
                    bytes,
                    typeIdentifier: representation.typeIdentifier,
                    maximumBytes: maximumBytes
                  ) else { continue }
            return decoded
        }
        return nil
    }

    /// The whole text of the first representation that decodes, in the order `preview` tries them
    /// and without its byte limit.
    nonisolated static func fullText(_ representations: [RepresentationValue]) -> String? {
        preview(representations, maximumBytes: .max)?.text
    }

    /// A link's URL as text, without the whitespace around it. The plain text stored beside a link
    /// can be a title or a Markdown link, so the `public.url` representations are tried first and the
    /// other text only stands in when none of them holds a URL.
    nonisolated static func linkText(_ representations: [RepresentationValue]) -> String? {
        for representation in representations where representation.typeIdentifier.lowercased() == "public.url" {
            if let url = trimmed(fullText([representation])) { return url }
        }
        return trimmed(fullText(representations))
    }

    /// The title of the page a link was copied from, which a browser writes as `public.url-name` beside the URL,
    /// decoded as any text is, from its first 4 KB as a clip's title is, and without the whitespace around it. Nil
    /// when there is none or it is blank. It is not a text type of its own, so titles and previews never read it.
    nonisolated static func linkTitle(_ representations: [RepresentationValue]) -> String? {
        for representation in representations where representation.typeIdentifier.lowercased() == "public.url-name" {
            guard let bytes = representation.bytes,
                  let decoded = decodeBytes(bytes, normalizedType: "public.url-name", maximumBytes: 4_096),
                  let title = trimmed(sanitize(decoded.text)) else { continue }
            return title
        }
        return nil
    }

    nonisolated static func decodeText(
        _ bytes: Data,
        typeIdentifier: String,
        maximumBytes: Int
    ) -> ClipTextPreview? {
        guard maximumBytes > 0,
              let decoded = decode(bytes, typeIdentifier: typeIdentifier, maximumBytes: maximumBytes) else {
            return nil
        }
        return ClipTextPreview(text: sanitize(decoded.text), isTruncated: decoded.isTruncated)
    }

    nonisolated static func isTextType(_ typeIdentifier: String) -> Bool {
        supportedTypes.contains(typeIdentifier.lowercased())
    }

    private nonisolated static func decode(
        _ bytes: Data,
        typeIdentifier: String,
        maximumBytes: Int
    ) -> ClipTextPreview? {
        let normalizedType = typeIdentifier.lowercased()
        guard supportedTypes.contains(normalizedType) else { return nil }
        return decodeBytes(bytes, normalizedType: normalizedType, maximumBytes: maximumBytes)
    }

    /// Decodes text of a known type: a byte order mark chooses UTF-16, the UTF-16 types are UTF-16 without one, and
    /// everything else is UTF-8. A prefix cut inside a character is shortened until it decodes.
    private nonisolated static func decodeBytes(
        _ bytes: Data,
        normalizedType: String,
        maximumBytes: Int
    ) -> ClipTextPreview? {
        guard !bytes.isEmpty else { return nil }

        let encoding: String.Encoding
        let bomByteCount: Int
        if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            bomByteCount = 2
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            bomByteCount = 2
        } else if normalizedType == "public.utf16-plain-text"
                    || normalizedType == "public.utf16-external-plain-text"
                    || normalizedType == "corepasteboardflavortype 0x75743136" {
            encoding = .utf16LittleEndian
            bomByteCount = 0
        } else {
            encoding = .utf8
            bomByteCount = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        }

        let availableCount = max(0, bytes.count - bomByteCount)
        var prefixCount = min(availableCount, maximumBytes)
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian {
            prefixCount -= prefixCount % 2
        }
        guard prefixCount > 0 else { return nil }
        let payload = bytes.dropFirst(bomByteCount)

        let maximumTrim = encoding == .utf8 ? 3 : 2
        for trim in stride(from: 0, through: min(maximumTrim, prefixCount - 1), by: 1) {
            let candidateCount = prefixCount - trim
            if (encoding == .utf16LittleEndian || encoding == .utf16BigEndian), !candidateCount.isMultiple(of: 2) {
                continue
            }
            if let text = String(data: Data(payload.prefix(candidateCount)), encoding: encoding) {
                return ClipTextPreview(
                    text: text,
                    isTruncated: bomByteCount + candidateCount < bytes.count
                )
            }
        }
        return nil
    }

    private nonisolated static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value != 0 })
    }

    /// The text without the whitespace and newlines around it; nil when nothing else is left.
    private nonisolated static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
