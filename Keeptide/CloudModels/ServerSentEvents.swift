import Foundation

/// One server-sent event: its type, its data with its lines joined by newlines, and the last event ID the stream gave.
struct ServerSentEvent: Equatable, Sendable {
    var type: String
    var data: String
    var id: String?
}

/// Reads server-sent events from a body that arrives in parts, as the HTML standard reads an event stream: a line ends
/// at CR, LF or CRLF, a field ends at the line's first colon and loses one space after it, a blank line sends the event
/// read so far, and comments and unknown fields are skipped. A line is split into its field and value as bytes and only
/// then read as text, since a part can end within a character and a combining mark can follow a colon or a space. An
/// event the stream ends before sending is dropped, and a line or an event's data longer than `limit` bytes is refused.
struct ServerSentEventParser: Sendable {
    /// A line, or an event's data, grew past the limit.
    struct TooLong: Error {}

    private let limit: Int
    /// The bytes of the line not ended yet.
    private var line = Data()
    /// Whether the last line ended at a CR, so that an LF right after it ends nothing more.
    private var endedAtCR = false
    private var isFirstLine = true
    private var type = ""
    private var data = Data()
    private var hasData = false
    private var lastID: String?

    init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    /// The events `bytes` completes.
    mutating func feed(_ bytes: Data) throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\n") where endedAtCR:
                endedAtCR = false
            case UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                endedAtCR = byte == UInt8(ascii: "\r")
                if let event = try endLine() { events.append(event) }
            default:
                endedAtCR = false
                line.append(byte)
                if line.count > limit { throw TooLong() }
            }
        }
        return events
    }

    /// Reads the line just ended; a blank one sends the event, when it has data.
    private mutating func endLine() throws -> ServerSentEvent? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if bytes.starts(with: Self.byteOrderMark) { bytes.removeFirst(Self.byteOrderMark.count) }
        }
        guard !bytes.isEmpty else { return send() }
        // A comment, which starts with a colon, is a field with no name, skipped as unknown fields are.
        let field: Data
        var value: Data
        if let colon = bytes.firstIndex(of: UInt8(ascii: ":")) {
            field = bytes[..<colon]
            value = bytes[bytes.index(after: colon)...]
            if value.first == UInt8(ascii: " ") { value.removeFirst() }
        } else {
            field = bytes
            value = Data()
        }
        switch String(decoding: field, as: UTF8.self) {
        case "event":
            type = String(decoding: value, as: UTF8.self)
        case "data":
            if hasData { data.append(UInt8(ascii: "\n")) }
            data.append(value)
            hasData = true
            if data.count > limit { throw TooLong() }
        case "id" where !value.contains(0):
            lastID = String(decoding: value, as: UTF8.self)
        default:
            // `retry` and unknown fields: nothing Keeptide uses.
            break
        }
        return nil
    }

    private mutating func send() -> ServerSentEvent? {
        defer {
            type = ""
            data.removeAll(keepingCapacity: true)
            hasData = false
        }
        guard hasData else { return nil }
        return ServerSentEvent(type: type.isEmpty ? "message" : type, data: String(decoding: data, as: UTF8.self),
                               id: lastID)
    }

    /// UTF-8's byte order mark, which a stream may start with.
    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
}
