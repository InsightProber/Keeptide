import XCTest
@testable import Keeptide

/// Server-sent events as a model provider streams them, read as the HTML standard reads an event stream, however the
/// body is cut into parts.
final class ServerSentEventParserTests: XCTestCase {
    func testAnEventIsItsTypeAndItsDataSentAtABlankLine() {
        XCTAssertEqual(events(["event: message_start\ndata: {\"type\":\"message_start\"}\n\n"]),
                       [ServerSentEvent(type: "message_start", data: "{\"type\":\"message_start\"}")])
    }

    func testDataOnSeveralLinesIsJoinedByNewlinesAndAnUntypedEventIsAMessage() {
        XCTAssertEqual(events(["data: one\ndata: two\n\n"]), [ServerSentEvent(type: "message", data: "one\ntwo")])
    }

    func testLinesEndAtCRLFCROrLFEvenWhenAPartEndsBetweenCRAndLF() {
        XCTAssertEqual(events(["event: a\r", "\ndata: 1\r\r", "event: b\ndata: 2\r\n", "\r\n"]),
                       [ServerSentEvent(type: "a", data: "1"), ServerSentEvent(type: "b", data: "2")])
    }

    func testCommentsAndUnknownFieldsAreSkippedAndAFieldWithoutAColonHasNoValue() {
        XCTAssertEqual(events([": keep-alive\nretry: 3000\nfoo: bar\ndata\n\n"]),
                       [ServerSentEvent(type: "message", data: "")])
    }

    func testOnlyOneSpaceAfterTheColonIsDropped() {
        XCTAssertEqual(events(["data:  two spaces\ndata:none\n\n"]),
                       [ServerSentEvent(type: "message", data: " two spaces\nnone")])
    }

    func testABlankLineWithNoDataSendsNothingAndForgetsTheType() {
        XCTAssertEqual(events(["event: ping\n\ndata: x\n\n"]), [ServerSentEvent(type: "message", data: "x")])
    }

    func testTheLastEventIDStaysWithLaterEvents() {
        XCTAssertEqual(events(["id: 7\ndata: a\n\ndata: b\n\n"]),
                       [ServerSentEvent(type: "message", data: "a", id: "7"),
                        ServerSentEvent(type: "message", data: "b", id: "7")])
    }

    func testAnIDWithANullInItIsIgnored() {
        XCTAssertEqual(events(["id: 1\ndata: a\n\nid: 2\u{0}x\ndata: b\n\n"]),
                       [ServerSentEvent(type: "message", data: "a", id: "1"),
                        ServerSentEvent(type: "message", data: "b", id: "1")])
    }

    func testAByteOrderMarkAtTheStartIsDropped() {
        XCTAssertEqual(events(["\u{FEFF}data: a\n\n"]), [ServerSentEvent(type: "message", data: "a")])
    }

    func testACharacterCutBetweenPartsIsReadWhole() throws {
        let bytes = Data("data: 季度\n\n".utf8)
        // Inside the first character's three bytes.
        let cut = bytes.firstIndex(of: 0xE5)! + 1
        var parser = ServerSentEventParser()

        let read = try parser.feed(bytes[..<cut]) + parser.feed(bytes[cut...])

        XCTAssertEqual(read, [ServerSentEvent(type: "message", data: "季度")])
    }

    func testAnEventWithoutItsBlankLineIsNotSent() {
        XCTAssertEqual(events(["data: partial\n"]), [])
    }

    func testEachByteOnItsOwnReadsTheSame() throws {
        let stream = "event: a\r\ndata: 1\r\n\r\n: comment\nid: 9\ndata: x\ndata: y\n\n"
        let whole = events([stream])
        var parser = ServerSentEventParser()

        let byByte = try Data(stream.utf8).flatMap { try parser.feed(Data([$0])) }

        XCTAssertEqual(byByte, whole)
        XCTAssertEqual(whole.count, 2)
    }

    func testAByteOrderMarkCutBetweenPartsIsDroppedAndOneOnALaterLineIsNot() throws {
        let mark = Data("\u{FEFF}".utf8)
        var parser = ServerSentEventParser()

        let read = try parser.feed(mark.prefix(1)) + parser.feed(mark.dropFirst() + Data("data: a\n\n".utf8))
            + parser.feed(Data("\u{FEFF}data: b\n\ndata: c\n\n".utf8))

        XCTAssertEqual(read, [ServerSentEvent(type: "message", data: "a"), ServerSentEvent(type: "message", data: "c")],
                       "A mark on a later line makes its field unknown")
    }

    func testAFieldEndsAtTheFirstColonAndOneSpaceGoesWhateverMarkFollowsThem() {
        XCTAssertEqual(events(["data:\u{301}x\ndata: \u{301}y\n\n"]),
                       [ServerSentEvent(type: "message", data: "\u{301}x\n\u{301}y")])
    }

    func testALineOrAnEventLongerThanTheLimitIsRefused() {
        var parser = ServerSentEventParser(limit: 16)
        XCTAssertThrowsError(try parser.feed(Data("data: \(String(repeating: "x", count: 20))".utf8)))
        var events = ServerSentEventParser(limit: 16)
        XCTAssertNoThrow(try events.feed(Data("data: 12345678\n".utf8)))
        XCTAssertThrowsError(try events.feed(Data("data: 12345678\n".utf8)), "The event's data grows past it")
    }

    private func events(_ parts: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return parts.flatMap { (try? parser.feed(Data($0.utf8))) ?? [] }
    }
}
