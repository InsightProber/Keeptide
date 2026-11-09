import XCTest
@testable import Keeptide

final class TypewriterPacerTests: XCTestCase {
    private let frame = 1.0 / 60

    func testABurstIsWrittenEvenlyWithinTheDelay() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 60, at: 0)
        run(&pacer, from: 0, to: 0.15)
        XCTAssertEqual(Double(pacer.revealed), 30, accuracy: 4)
        run(&pacer, from: 0.15, to: 0.3)
        XCTAssertEqual(pacer.revealed, 60)
        XCTAssertTrue(pacer.isCaughtUp)
    }

    func testATrickleTypesAtTheMinimumRate() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 10, at: 0)
        run(&pacer, from: 0, to: 0.1)
        // Ten characters may take 0.3 seconds, but never less than 40 a second appear.
        XCTAssertEqual(Double(pacer.revealed), 4, accuracy: 1)
        run(&pacer, from: 0.1, to: 0.3)
        XCTAssertEqual(pacer.revealed, 10)
    }

    func testEveryCharacterAppearsWithinTheDelayOfArriving() {
        // A bursty stream: small pieces, a large burst, then the last pieces right before the source finishes.
        let chunks: [(time: Double, count: Int)] = [
            (0.45, 18), (0.62, 40), (0.70, 12), (1.30, 60), (1.42, 8), (2.10, 50), (2.15, 20),
        ]
        var pacer = TypewriterPacer()
        var arrivals: [Double] = []
        var shownAt: [Double] = []
        var next = 0
        var time = 0.0
        while time <= 3 {
            while next < chunks.count, chunks[next].time <= time {
                arrivals += Array(repeating: chunks[next].time, count: chunks[next].count)
                pacer.receive(total: arrivals.count, at: chunks[next].time)
                next += 1
            }
            pacer.advance(to: time)
            while shownAt.count < pacer.revealed { shownAt.append(time) }
            time += frame
        }
        XCTAssertEqual(shownAt.count, 208)
        for (index, arrival) in arrivals.enumerated() {
            XCTAssertLessThanOrEqual(shownAt[index] - arrival, 0.3 + frame, "character \(index)")
        }
    }

    func testRevealAllShowsEverythingAtOnce() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 50, at: 0)
        pacer.advance(to: frame)
        pacer.revealAll()
        XCTAssertEqual(pacer.revealed, 50)
        XCTAssertEqual(pacer.advance(to: 1), 50)
    }

    func testResetStartsFromTheTextAlreadyShown() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 20, at: 0)
        pacer.reset(showing: 120)
        XCTAssertEqual(pacer.revealed, 120)
        XCTAssertTrue(pacer.isCaughtUp)
        pacer.receive(total: 130, at: 5)
        run(&pacer, from: 5, to: 5.3)
        XCTAssertEqual(pacer.revealed, 130)
    }

    func testADisplayThatWasAwayCatchesUpWhenItReturns() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 100, at: 0)
        pacer.advance(to: 0)
        XCTAssertEqual(pacer.advance(to: 5), 100)
    }

    func testTimeSpentCaughtUpDoesNotCountTowardTheNextText() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 5, at: 0)
        run(&pacer, from: 0, to: 1)
        pacer.receive(total: 45, at: 10)
        pacer.advance(to: 10)
        XCTAssertEqual(pacer.revealed, 5, "nothing new appears in the instant the text arrives")
    }

    func testPaceLeftFromABurstDoesNotCarryOverToTheNextText() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 2_000, at: 0)
        run(&pacer, from: 0, to: 0.3)
        XCTAssertTrue(pacer.isCaughtUp)
        pacer.receive(total: 2_100, at: 0.3)
        pacer.advance(to: 0.3 + frame)
        // The new text sets its own pace: 100 characters over 0.3 seconds is under 6 a frame.
        XCTAssertLessThanOrEqual(pacer.revealed, 2_000 + 7)
    }

    func testAShorterTotalIsIgnored() {
        var pacer = TypewriterPacer()
        pacer.receive(total: 10, at: 0)
        pacer.receive(total: 4, at: 0.1)
        run(&pacer, from: 0, to: 1)
        XCTAssertEqual(pacer.revealed, 10)
    }

    private func run(_ pacer: inout TypewriterPacer, from start: Double, to end: Double) {
        var time = start
        while time < end - 1e-9 {
            time = min(end, time + frame)
            pacer.advance(to: time)
        }
    }
}
