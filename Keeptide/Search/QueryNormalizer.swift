import Foundation

/// Index-only normalization. The result never replaces stored content and never
/// participates in identity or deduplication.
enum SearchNormalizer {
    static let version = 1

    static func normalize(_ text: String) -> String {
        let withoutNUL = text.utf8.contains(0) ? String(text.unicodeScalars.filter { $0.value != 0 }) : text
        return withoutNUL.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// A literal query split into normalized terms. Terms of three or more scalars
/// can use the trigram index; shorter ones need a scan.
struct ParsedQuery: Equatable, Sendable {
    static let maximumScalarCount = 4_096
    /// Keeps generated SQL far below SQLite's expression-depth limit.
    static let maximumTermCount = 64
    static let minimumIndexedScalarCount = 3

    let terms: [String]
    let longTerms: [String]
    let shortTerms: [String]
    let phrase: String
    let wasTruncated: Bool

    init(_ raw: String) {
        var bounded = String.UnicodeScalarView()
        var scalarCount = 0
        var truncated = false
        for scalar in raw.unicodeScalars {
            guard scalarCount < Self.maximumScalarCount else {
                truncated = true
                break
            }
            bounded.append(scalar)
            scalarCount += 1
        }
        var seen = Set<String>()
        var terms: [String] = []
        for piece in String(bounded).split(whereSeparator: \.isWhitespace) {
            let term = SearchNormalizer.normalize(String(piece))
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            guard terms.count < Self.maximumTermCount else {
                truncated = true
                break
            }
            terms.append(term)
        }
        self.terms = terms
        longTerms = terms.filter { $0.unicodeScalars.count >= Self.minimumIndexedScalarCount }
        shortTerms = terms.filter { $0.unicodeScalars.count < Self.minimumIndexedScalarCount }
        phrase = terms.joined(separator: " ")
        wasTruncated = truncated
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Every long term becomes one quoted FTS5 string, so no user text is ever
    /// parsed as FTS5 syntax. Adjacent strings mean "all of these".
    var ftsExpression: String? {
        guard !longTerms.isEmpty else { return nil }
        return longTerms
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }
}
