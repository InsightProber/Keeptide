import Foundation

/// Whether Keeptide may load a copied link to show a preview of it: the page's title and picture, or the page itself.
/// Loading a link tells its website the address and this Mac's IP address, so only a web link is loaded, and never one
/// that, as far as its address shows, leads to this Mac or the local network, names a user or a password, or may carry
/// a secret. A link that carries another, as a click tracker's does, is held to the same rules for that one too.
///
/// What the address can't show: a public name that leads to a local address, which only looking it up would tell; where
/// the page redirects; the pictures the page names; and a secret in the path that doesn't look like one.
enum LinkAddress {
    /// Why a link isn't loaded.
    enum Refusal: Error, Equatable, Sendable {
        /// Not one http or https address, or one longer than any link Keeptide loads.
        case notWebLink
        /// The address names a user, or a user and a password.
        case credentials
        /// The address leads to this Mac or the local network: a local name, a name of one label, or an IP address,
        /// written any way a browser reads one; or a name written with escapes, which could hide one, as could a name
        /// in another script written that way. An IP address is never loaded, a public one included.
        case localNetwork
        /// A part of the address may be a secret: a parameter, in the query, the fragment or the path, named for a
        /// token, a key, a session, a signature, a code that isn't plainly a country's, a postal one or the like; or a
        /// JSON Web Token anywhere, escaped or not.
        case mayHoldSecret
    }

    /// The longest link loaded, in characters.
    static let longestLink = 8_192
    /// How deep links inside links are read, and how many times escapes are undone to find a token.
    private static let deepest = 3

    /// The last labels of names no one outside the local network can reach, or that are kept for tests.
    private static let localDomains: Set<String> = [
        "localhost", "local", "localdomain", "internal", "intranet", "private", "lan", "corp", "home", "arpa", "test",
        "invalid",
    ]

    /// Words that, as a whole word of a parameter's name, may name a secret.
    private static let secretWords: Set<String> = [
        "key", "apikey", "sig", "otp", "totp", "mfa", "sid", "auth", "authorization", "bearer", "pass", "pwd", "jwt",
        "ticket", "session",
    ]

    /// Parts that, anywhere in a parameter's name, may name a secret: "authtoken" holds "token" though it is one word.
    private static let secretParts = [
        "token", "secret", "passw", "passcode", "signature", "credential", "sessid", "sessionid", "sesskey", "jsession",
        "phpsess", "csrf", "xsrf", "hmac", "apikey", "accesskey", "privatekey", "authcode", "accesscode", "verifycode",
        "resetcode", "otpcode", "smscode", "securitycode", "logincode",
    ]

    /// Words before "code" that make it no secret: a country's, a postal code, a colour, an offer and the like. Any
    /// other code, or "code" alone, may be one to sign in with.
    private static let plainCodes: Set<String> = [
        "country", "zip", "postal", "post", "area", "color", "colour", "display", "promo", "promotion", "coupon",
        "discount", "currency", "lang", "language", "locale", "region", "state", "status", "error", "product", "sku",
        "ref", "referral", "item", "category", "airport", "station", "zone", "link", "affiliate", "partner", "campaign",
        "tracking", "source", "goods", "prod", "model", "style", "size", "store", "stock", "property", "rate", "qr",
        "iso",
    ]

    /// The address to load for the link `text`, or why it isn't loaded. White space around the link is ignored; white
    /// space or a control character within it means it isn't one address.
    static func loadable(_ text: String) -> Result<URL, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= longestLink,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              let components = webLink(trimmed), let url = components.url
        else { return .failure(.notWebLink) }
        if let refusal = refusal(of: components, text: trimmed, depth: 0) { return .failure(refusal) }
        return .success(url)
    }

    /// What a link's preview is kept under: its address with the scheme and the host in lower case, without the port
    /// its scheme takes anyway or a trailing dot, and without the fragment, which only the page reads.
    static func key(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased() ?? ""
        // The encoded host gives a name in other scripts in its ASCII form.
        var host = (components.encodedHost ?? "").lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        let port = components.port.flatMap { port -> String? in
            (scheme == "http" && port == 80) || (scheme == "https" && port == 443) ? nil : ":\(port)"
        } ?? ""
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return "\(scheme)://\(host)\(port)\(path)\(query)"
    }

    /// `text` read as an http or https address, or nil.
    private static func webLink(_ text: String) -> URLComponents? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return components
    }

    /// Why the link isn't loaded, or nil. `depth` is how far inside another link this one is: a link a parameter of
    /// this one holds is read too, unless it is too deep, and its refusal is this one's.
    private static func refusal(of components: URLComponents, text: String, depth: Int) -> Refusal? {
        let host = normalizedHost(components.host ?? "")
        guard !host.isEmpty else { return .notWebLink }
        if components.user != nil || components.password != nil { return .credentials }
        // Escapes in a name hide what it is: a browser undoes them, and makes their wide characters narrow, after the
        // name is read here. No real link needs them. A name in other scripts is in its ASCII form here, without any.
        if components.encodedHost?.contains("%") == true || isLocal(host) { return .localNetwork }
        let parameters = parameters(of: components)
        if parameters.contains(where: { namesSecret($0.name) }) || holdsWebToken(text) { return .mayHoldSecret }
        guard depth < deepest else { return nil }
        // A link a parameter holds, as its value, or as its name when it has none, as some redirectors write it; also
        // with its escapes undone once more, as a link escaped twice has them.
        for parameter in parameters {
            for candidate in [parameter.value, parameter.name] {
                for written in Set([candidate, undoingEscapes(candidate)]) {
                    guard let inner = webLink(written),
                          let refusal = refusal(of: inner, text: written, depth: depth + 1),
                          refusal != .notWebLink else { continue }
                    return refusal
                }
            }
        }
        return nil
    }

    /// The host in lower case and without a trailing dot. A name written without escapes has had its wide characters
    /// and other scripts' full stops made ASCII by `URLComponents`; one written with them is refused before it matters.
    private static func normalizedHost(_ host: String) -> String {
        var normalized = host.lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }

    /// Whether `host` leads to this Mac or the local network as far as its name tells: an IPv6 address, a name of one
    /// label, a name whose last label is a number (an IPv4 address in any of the ways browsers read one: dotted,
    /// shortened, one number, hexadecimal or octal), or a name in a local domain.
    private static func isLocal(_ host: String) -> Bool {
        if host.contains(":") || host.hasPrefix("[") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, let last = labels.last, !last.isEmpty else { return true }
        let digits = last.allSatisfy { $0.isASCII && $0.isNumber }
        let hexadecimal = last.hasPrefix("0x") && last.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
        return digits || hexadecimal || localDomains.contains(String(last))
    }

    /// The parameters of a link, each with its value, escapes undone once: in the query, in the fragment (read as
    /// parameters after its last "?", as a route in it would have them) and in the path, as `;name=value`, as servers
    /// put a session there. A name given twice is there twice; a name without a value has an empty one.
    private static func parameters(of components: URLComponents) -> [(name: String, value: String)] {
        var parameters = (components.queryItems ?? []).map { (name: $0.name, value: $0.value ?? "") }
        func read(_ pairs: [Substring]) {
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let value = parts.count > 1 ? String(parts[1]) : ""
                parameters.append((name: undoingEscapes(String(parts[0])), value: undoingEscapes(value)))
            }
        }
        if let fragment = components.percentEncodedFragment {
            let route = fragment.contains("?")
            let tail = fragment.split(separator: "?", omittingEmptySubsequences: false).last.map(String.init)
                ?? fragment
            read(tail.split(whereSeparator: { $0 == "&" || $0 == ";" }).filter { route || $0.contains("=") })
        }
        for segment in components.percentEncodedPath.split(separator: "/") {
            read(Array(segment.split(separator: ";", omittingEmptySubsequences: false).dropFirst()))
        }
        return parameters
    }

    /// Whether a parameter's name may name a secret: a word of it is one of `secretWords`, a part of it one of
    /// `secretParts`, or it is a code that isn't plainly harmless.
    static func namesSecret(_ name: String) -> Bool {
        let words = words(of: name)
        if words.contains(where: secretWords.contains) { return true }
        let joined = words.joined()
        if secretParts.contains(where: joined.contains) { return true }
        guard let index = words.lastIndex(of: "code") else { return false }
        return index == 0 || !plainCodes.contains(words[index - 1])
    }

    /// Whether `text` holds a JSON Web Token, as written or with its escapes undone, up to three times over: a run of
    /// the characters tokens are written in that begins with `eyJ` and has three parts, the first two long, between
    /// full stops. Each reading is one pass, so a long run can't make it slow.
    private static func holdsWebToken(_ text: String) -> Bool {
        func isTokenCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_"
                                  || character == ".")
        }
        var reading = text
        for _ in 0...deepest {
            let found = reading.split(whereSeparator: { !isTokenCharacter($0) }).contains { run in
                guard run.hasPrefix("eyJ") else { return false }
                let parts = run.split(separator: ".", omittingEmptySubsequences: false)
                return parts.count >= 3 && parts[0].count >= 10 && parts[1].count >= 8
            }
            guard !found else { return true }
            let decoded = undoingEscapes(reading)
            guard decoded != reading else { return false }
            reading = decoded
        }
        return false
    }

    /// `text` with its escapes undone, each `%` and two hexadecimal digits; anything else, an escape that isn't one
    /// included, stays as written, so that one bad escape can't keep the rest from being read.
    private static func undoingEscapes(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var undone: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexadecimalValue(bytes[index + 1]), let low = hexadecimalValue(bytes[index + 2]) {
                undone.append(high << 4 | low)
                index += 3
            } else {
                undone.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: undone, as: UTF8.self)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// The words of a parameter's name, in lower case. A word ends where a character that is neither a letter nor a
    /// digit comes, where a lower-case letter meets a capital, where a run of capitals meets a capital that begins a
    /// word ("APIKey" is "api" and "key"), and where letters meet digits.
    static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let last = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if (last.isLowercase && character.isUppercase) || last.isNumber != character.isNumber
                    || (last.isUppercase && character.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}
