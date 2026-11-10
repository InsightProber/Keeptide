import Foundation
import NaturalLanguage

/// What language a text is judged to be in, before it is translated.
enum LanguageJudgement: Equatable, Sendable {
    /// Natural Language is sure enough of this language.
    case detected(Locale.Language, confidence: Double)
    /// Not sure: the likeliest languages, up to three, likeliest first.
    case uncertain([Locale.Language])
    /// Too little text to tell.
    case tooShort
    /// Mostly code, links or numbers, which language detection misreads and a translation leaves as it is.
    case notProse
}

/// Tells the language of a text with Natural Language, on this Mac. It judges only prose of some length: links and
/// code come back as Dutch or English with confidence, so they are set aside first, and a few words of an alphabet
/// say too little. A few characters of Chinese, Japanese or Korean say plenty, and Simplified and Traditional Chinese
/// are told apart.
///
/// It gives Natural Language no hints: a hint for a language outweighs the text itself, so Japanese with a hint for
/// Chinese comes back as Chinese.
enum LanguageDetection {
    /// How sure Natural Language must be of a language.
    static let threshold = 0.6
    /// Letters text in an alphabet needs before its language is judged.
    static let minimumLetters = 12
    /// Characters text in Chinese, Japanese or Korean needs: each says as much as a word.
    static let minimumIdeographs = 2

    /// The language of `text`, from the languages in `constraints` when there are any.
    static func judge(_ original: String, constraints: [Locale.Language]? = nil) -> LanguageJudgement {
        // A heading's underline, or a rule between parts, is neither code nor words.
        let text = withoutRules(original)
        let counts = Counts(text)
        guard counts.nonSpace > 0 else { return text == original ? .tooShort : .notProse }
        if isMostlyLinks(text, counts) || isMostlyNumbers(counts) || isCode(text, counts) { return .notProse }
        guard counts.ideographs >= minimumIdeographs || counts.letters >= minimumLetters else { return .tooShort }
        let recognizer = NLLanguageRecognizer()
        if let constraints { recognizer.languageConstraints = constraints.map { NLLanguage($0.translationCode) } }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        guard let top = hypotheses.first else { return .uncertain([]) }
        if top.value >= threshold {
            return .detected(Locale.Language(identifier: top.key.rawValue), confidence: top.value)
        }
        return .uncertain(hypotheses.map { Locale.Language(identifier: $0.key.rawValue) })
    }

    /// How much text there is, to weigh one language against another: a letter counts one, and a character of Chinese,
    /// Japanese or Korean three, as it says about as much as a short word.
    static func weight(of text: String) -> Int {
        let counts = Counts(text)
        return counts.letters + 3 * counts.ideographs
    }

    // MARK: Text that isn't prose

    /// The text without its rules: lines of three or more `=`, `-`, `~`, `_`, `*` or `#` and nothing else.
    private static func withoutRules(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let kept = lines.filter { line in
            let marks = line.filter { !$0.isWhitespace }
            return marks.count < 3 || !marks.allSatisfy { "=-~_*#".contains($0) }
        }
        return kept.count == lines.count ? text : kept.joined(separator: "\n")
    }

    /// Links cover half the text or more. Only what is surely a link counts, an address with its scheme or "www.", or
    /// an email address: names of files such as "setup.py" are taken for links too.
    private static func isMostlyLinks(_ text: String, _ counts: Counts) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }
        let linked = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).reduce(0) { total, match in
            guard let range = Range(match.range, in: text) else { return total }
            let link = text[range]
            let isSure = link.contains("://") || link.lowercased().hasPrefix("www.") || link.contains("@")
            return isSure ? total + match.range.length : total
        }
        return linked * 2 >= counts.nonSpaceUTF16
    }

    /// Fewer than three in ten characters are letters: numbers, dates, sums.
    private static func isMostlyNumbers(_ counts: Counts) -> Bool {
        (counts.letters + counts.ideographs) * 10 < counts.nonSpace * 3
    }

    /// Code: a line only code writes, such as an assignment after `let`, a function's first line, an import, a query, a
    /// command with its flag or path, or a shell prompt. Or, where code's marks make up a twenty-fifth of the text, a
    /// line that ends in a brace or a semicolon with an assignment or a call in it; or, where they make up an eighth, an
    /// operator or a call.
    private static func isCode(_ text: String, _ counts: Counts) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        if lines.contains(where: { line in isCommand(line) || codeLines.contains { line.contains($0) } }) { return true }
        if counts.codeSymbols * 25 >= counts.nonSpace, lines.contains(where: endsLikeCode) { return true }
        guard counts.codeSymbols * 8 >= counts.nonSpace else { return false }
        return codeMarks.contains { text.contains($0) } || text.contains(callPattern)
    }

    /// Lines only code writes. Keywords and commands are in lowercase, as code writes them, so a sentence starting "Let
    /// me" or "Open ~/Library" is no code; queries are in capitals, in the shape of their clauses, so "SELECT ALL THAT
    /// APPLY" is none either. An import names a module: capitalised, dotted, or closed by a semicolon.
    private static var codeLines: [Regex<Substring>] {
        [
            /^\s*(?:let|var|const)\s+[A-Za-z_]\w*\s*(?::[^=]*)?=(?:[^=]|$)/,
            /^\s*(?:def|func|fn|function)\s+[A-Za-z_]\w*\s*[(<]/,
            /^\s*(?:class|struct|enum|protocol|interface)\s+[A-Z]\w*\s*[:{(<]/,
            /^\s*import\s+(?:[A-Z]\w*|\w+(?:\.\w+)+)\s*;?\s*$/,
            /^\s*import\s+[\w.]+\s*;\s*$/,
            /^\s*from\s+[A-Za-z_][\w.]*\s+import\s+\S/,
            /^\s*#(?:include|import)\s*[<"]/,
            /^\s*return\s+(?:[\w.]+\(.*\)\s*;?|[\w.]+\s*;)\s*$/,
            /^\s*SELECT\s+.+\s+FROM\s+\S/,
            /^\s*UPDATE\s+\w+\s+SET\s/,
            /^\s*(?:INSERT\s+INTO|DELETE\s+FROM)\s+\w/,
            /^\s*(?:CREATE|ALTER|DROP)\s+(?:TABLE|INDEX|VIEW)\s+\w/,
            /^\s*\$\s+[a-z][\w.+-]*/,
        ]
    }

    /// A command with its flag or path, as in `cp ~/a/b.pdf /c/` or `git commit -m "…"`: a lowercase word, perhaps a
    /// second, then a flag or a path, and after it no run of three plain words, which a sentence starting in lowercase,
    /// or a line wrapped from one, has.
    private static func isCommand(_ line: Substring) -> Bool {
        guard let start = line.firstMatch(
            of: /^\s*[a-z][\w.+-]*(?:\s+[a-z][\w.+-]*)?\s+(?:--?[A-Za-z][\w-]*|(?:~|\.{1,2})?\/[\w.\-]+\/)/) else {
            return false
        }
        var plainWords = 0
        for word in line[start.range.upperBound...].split(whereSeparator: \.isWhitespace) {
            plainWords = word.allSatisfy(\.isLetter) ? plainWords + 1 : 0
            if plainWords == 3 { return false }
        }
        return true
    }

    /// A line that ends in a semicolon or a brace and has more of code in it: an assignment, a call, or nothing but
    /// braces. The items of a list end in semicolons too, and start with a mark or a letter or number in brackets.
    private static func endsLikeCode(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, ";{}".contains(last) else { return false }
        if trimmed.allSatisfy({ ";{}".contains($0) }) { return true }
        guard !trimmed.contains(/^(?:[-*•–]\s|\(?[A-Za-z0-9]{1,3}[.)]\s)/) else { return false }
        return trimmed.contains("=") || trimmed.contains(callPattern)
    }

    private static let codeMarks = ["{", "}", "=>", "==", "!=", "->", "::", "</", "/>", "&&", "||", "+=", ":=", "$("]
    /// A name with brackets right after it holding nothing, or what only code holds there, a number, a quote, a dot or
    /// an underscore, as in `print()`, `reduce(0)` or `printf("%d", total)`; not "file(s)".
    private static var callPattern: Regex<Substring> {
        /[A-Za-z_]\w*\((?:[^()]*[0-9_."'$][^()]*)?\)/
    }

    /// What the rules count: characters other than white space, letters of an alphabet, ideographs and the like, and
    /// the punctuation code is full of.
    private struct Counts {
        var nonSpace = 0
        var nonSpaceUTF16 = 0
        var letters = 0
        var ideographs = 0
        var codeSymbols = 0

        init(_ text: String) {
            let symbols = Set("{}[]()<>;=+*/\\|&!$#@%^~`\"':-".unicodeScalars)
            let scalars = Array(text.unicodeScalars)
            for (index, scalar) in scalars.enumerated() where !scalar.properties.isWhitespace {
                nonSpace += 1
                nonSpaceUTF16 += scalar.utf16.count
                if Self.isIdeographic(scalar) {
                    ideographs += 1
                } else if scalar.properties.isAlphabetic {
                    letters += 1
                } else if symbols.contains(scalar), !Self.isWithinAWord(scalars, at: index) {
                    codeSymbols += 1
                }
            }
        }

        /// An apostrophe or a hyphen between letters, as in "don't", "l'erreur" or "e-mail", is part of a word.
        private static func isWithinAWord(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
            guard scalars[index] == "'" || scalars[index] == "-", index > 0, index + 1 < scalars.count else {
                return false
            }
            return scalars[index - 1].properties.isAlphabetic && scalars[index + 1].properties.isAlphabetic
        }

        /// Han, kana and Hangul: scripts where a character is about a word.
        private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.properties.isIdeographic { return true }
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

extension Locale.Language {
    /// Whether two languages are one for translation: the same language in the same script, in any region.
    func isSameLanguage(as other: Locale.Language) -> Bool {
        let (mine, theirs) = (maximal, other.maximal)
        return mine.languageCode == theirs.languageCode && mine.script == theirs.script
    }

    /// The language as a translation keeps it: its code, and for Chinese, the one language Translation knows in two
    /// scripts, its script. Regions are left out: "en", "ja", "zh-Hans", "zh-Hant".
    var translationCode: String {
        let full = maximal
        let code = full.languageCode?.identifier ?? minimalIdentifier
        guard code == "zh", let script = full.script?.identifier else { return code }
        return code + "-" + script
    }

    /// The language's name in English, as Keeptide shows it and as the system's Translate writes it: "English",
    /// "Chinese (Simplified)".
    var displayName: String {
        let code = translationCode
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        // Foundation writes "Chinese, Simplified".
        guard let comma = name.range(of: ", ") else { return name }
        return String(name[..<comma.lowerBound]) + " (" + String(name[comma.upperBound...]) + ")"
    }

    private var maximal: Locale.Language { Locale.Language(identifier: maximalIdentifier) }
}
