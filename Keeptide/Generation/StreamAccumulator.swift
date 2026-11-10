import Foundation

/// Builds a generation's text from its events: it joins deltas, routes tagged output to channels and splits a channel
/// into paragraphs. It is a plain value, so a job can run it off the main thread and tests can feed it any chunking:
/// however a text is cut into deltas, the result is the same.
struct StreamAccumulator: Sendable {
    /// Tags that split one stream into channels, as in `<text>…</text><translation>…</translation>`.
    ///
    /// Until a tag opens, text streams into `fallback`, so a response without tags still shows as it arrives. Once a tag
    /// opens, text outside the tags, such as "Here you go:", goes to `OutputChannel.untagged` instead. When the response
    /// ends without any tag, or with `fallback` still empty, its untagged text ends up in `fallback` and
    /// `separationFailed` is set. Nothing is lost either way.
    struct TaggedChannels: Equatable, Sendable {
        /// Each tag's name and the channel its contents go to.
        var channels: [String: OutputChannel]
        var fallback: OutputChannel

        init(_ channels: [String: OutputChannel], fallback: OutputChannel = .main) {
            self.channels = channels
            self.fallback = fallback
        }
    }

    private(set) var texts: [OutputChannel: String] = [:]
    private(set) var info: GenerationInfo?
    private(set) var usage: GenerationUsage?
    /// How many paragraphs the source said it will write, once it said.
    private(set) var expectedParagraphs: Int?
    private(set) var finishReason: FinishReason?
    /// True when a tagged response put its text in `fallback` because its tags didn't hold it.
    private(set) var separationFailed = false
    /// True after `finish()`: the stream is over and nothing is held back any more.
    private(set) var isFinished = false

    private let tagged: TaggedChannels?
    /// Tagged output not placed yet: it might be the start of a tag, or white space that belongs to the text only
    /// if more text follows.
    private var pending = ""
    /// The tag whose contents are arriving, if any.
    private var openTag: String?
    /// Whether any tag has opened.
    private var sawTag = false
    /// Whether the current run of text, inside a tag or between tags, has placed anything yet.
    private var segmentStarted = false

    init(taggedChannels: TaggedChannels? = nil) {
        tagged = taggedChannels
    }

    var hasText: Bool { texts.values.contains { !$0.isEmpty } }

    func text(_ channel: OutputChannel = .main) -> String {
        texts[channel, default: ""]
    }

    mutating func apply(_ event: GenerationEvent) {
        guard !isFinished, finishReason == nil else { return }
        switch event {
        case .started(let info):
            self.info = info
        case .delta(let text, let channel):
            if let tagged, channel == .main {
                pending += text
                route(tagged, final: false)
            } else {
                texts[channel, default: ""] += text
            }
        case .replace(let text, let channel):
            if let tagged, channel == .main {
                restart(tagged)
                pending = text
                route(tagged, final: false)
            } else {
                texts[channel] = text
            }
        case .usage(let usage):
            self.usage = usage
        case .expecting(let paragraphs):
            expectedParagraphs = paragraphs
        case .finished(let reason):
            finishReason = reason
        }
    }

    /// Places everything held back. Call it once, when the stream ends for any reason.
    mutating func finish() {
        guard !isFinished else { return }
        if let tagged {
            route(tagged, final: true)
            if sawTag, tagged.fallback != .untagged, text(tagged.fallback).isEmpty, !text(.untagged).isEmpty {
                texts[tagged.fallback] = texts[.untagged]
                texts[.untagged] = nil
                separationFailed = true
            }
        }
        isFinished = true
    }

    func paragraphs(in channel: OutputChannel = .main) -> [String] {
        Self.paragraphs(of: text(channel))
    }

    /// Paragraphs that are done: all of them once the stream has finished, and while it runs, those a blank line
    /// has followed.
    func completedParagraphCount(in channel: OutputChannel = .main) -> Int {
        let text = text(channel)
        let count = Self.paragraphs(of: text).count
        guard !isFinished, count > 0 else { return count }
        return Self.endsWithBlankLine(text) ? count : count - 1
    }

    /// The paragraphs of `text`: runs of lines separated by blank lines.
    static func paragraphs(of text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) {
                if !lines.isEmpty {
                    paragraphs.append(lines.joined(separator: "\n"))
                    lines = []
                }
            } else {
                lines.append(line)
            }
        }
        if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
        return paragraphs
    }

    private static func endsWithBlankLine(_ text: String) -> Bool {
        var newlines = 0
        for character in text.reversed() {
            if character.isNewline {
                newlines += 1
                if newlines == 2 { return true }
            } else if !character.isWhitespace {
                return false
            }
        }
        return false
    }

    // MARK: Tagged output

    private mutating func route(_ tagged: TaggedChannels, final: Bool) {
        while !pending.isEmpty {
            if let tag = openTag {
                let closing = "</\(tag)>"
                let channel = tagged.channels[tag] ?? tagged.fallback
                if let range = pending.range(of: closing) {
                    place(pending[..<range.lowerBound], in: channel, trimmingEnd: true)
                    pending = String(pending[range.upperBound...])
                    openTag = nil
                    segmentStarted = false
                } else {
                    let cut = Self.holdBack(in: pending, possibleStartsOf: [closing], final: final)
                    place(pending[..<cut], in: channel, trimmingEnd: final)
                    pending = final ? "" : String(pending[cut...])
                    return
                }
            } else {
                let tags = Array(tagged.channels.keys)
                if let opening = Self.firstOpening(in: pending, tags: tags) {
                    placeOutside(pending[..<opening.range.lowerBound], tagged, trimmingEnd: true)
                    pending = String(pending[opening.range.upperBound...])
                    open(opening.tag, tagged)
                } else {
                    let cut = Self.holdBack(in: pending, possibleStartsOf: tags.map { "<\($0)>" }, final: final)
                    placeOutside(pending[..<cut], tagged, trimmingEnd: final)
                    pending = final ? "" : String(pending[cut...])
                    return
                }
            }
        }
    }

    private mutating func open(_ tag: String, _ tagged: TaggedChannels) {
        if !sawTag {
            sawTag = true
            // What streamed into the fallback channel before the first tag was a preamble, not the result.
            if tagged.fallback != .untagged, let preamble = texts[tagged.fallback], !preamble.isEmpty {
                texts[tagged.fallback] = nil
                texts[.untagged, default: ""] += preamble
            }
            separationFailed = false
        }
        openTag = tag
        segmentStarted = false
    }

    /// Starts over for a source that replaced its whole response.
    private mutating func restart(_ tagged: TaggedChannels) {
        for channel in tagged.channels.values { texts[channel] = nil }
        texts[tagged.fallback] = nil
        texts[.untagged] = nil
        pending = ""
        openTag = nil
        sawTag = false
        segmentStarted = false
        separationFailed = false
    }

    /// Adds text to a channel. A run of text doesn't start with line breaks; a new run in a channel that already has
    /// text starts after a blank line; and the text before a closing tag doesn't end with white space.
    private mutating func place(_ text: Substring, in channel: OutputChannel, trimmingEnd: Bool) {
        var text = text
        let existing = texts[channel, default: ""]
        if existing.isEmpty || !segmentStarted { text = text.drop(while: \.isNewline) }
        if trimmingEnd {
            while let last = text.last, last.isWhitespace { text = text.dropLast() }
        }
        guard !text.isEmpty else { return }
        if !segmentStarted, !existing.isEmpty { texts[channel, default: ""] += "\n\n" }
        texts[channel, default: ""] += text
        segmentStarted = true
    }

    /// Adds text found outside every tag: to the fallback channel while no tag has opened, to the untagged channel
    /// after that. White space between tags is dropped.
    private mutating func placeOutside(_ text: Substring, _ tagged: TaggedChannels, trimmingEnd: Bool) {
        guard text.contains(where: { !$0.isWhitespace }) else { return }
        if sawTag {
            place(text, in: .untagged, trimmingEnd: trimmingEnd)
        } else {
            separationFailed = true
            place(text, in: tagged.fallback, trimmingEnd: trimmingEnd)
        }
    }

    /// Where the part of `text` that has to wait starts: a suffix that could begin one of `tags`, and while the stream
    /// runs, the white space before it, which belongs to the text only if more text follows. When the stream has
    /// ended, a cut-off tag of two characters or more is dropped, and a lone "<" stays as text.
    private static func holdBack(in text: String, possibleStartsOf tags: [String], final: Bool) -> String.Index {
        var cut = text.endIndex
        let length = text.count
        let shortest = final ? 2 : 1
        for tag in tags {
            for prefixLength in stride(from: min(tag.count - 1, length), through: shortest, by: -1)
            where text.hasSuffix(tag.prefix(prefixLength)) {
                cut = min(cut, text.index(text.endIndex, offsetBy: -prefixLength))
                break
            }
        }
        guard !final else { return cut }
        while cut > text.startIndex {
            let before = text.index(before: cut)
            guard text[before].isWhitespace else { break }
            cut = before
        }
        return cut
    }

    private static func firstOpening(in text: String, tags: [String]) -> (tag: String, range: Range<String.Index>)? {
        var first: (tag: String, range: Range<String.Index>)?
        for tag in tags {
            guard let range = text.range(of: "<\(tag)>") else { continue }
            if let current = first, current.range.lowerBound <= range.lowerBound { continue }
            first = (tag, range)
        }
        return first
    }
}
