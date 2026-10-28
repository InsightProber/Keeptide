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
        guard supportedTypes.contains(normalizedType), !bytes.isEmpty else { return nil }

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
}
