import XCTest
@testable import Keeptide

final class DetentScrollerTests: XCTestCase {
    func testThirtyPointsPerDetentWithOneTickEach() {
        var s = DetentScroller(); var out = [DetentOutput]()
        for i in 0..<9 { out.append(s.handle(.precise(dx: 10, t: Double(i) * 0.05), olderRoom: 10, newerRoom: 10)) }
        XCTAssertEqual(out.map(\.steps).reduce(0, +), 3); XCTAssertEqual(out.map(\.ticks).reduce(0, +), 3)
        XCTAssertEqual(out[0].progress, 1.0 / 3, accuracy: 0.001)
    }

    func testTicksAreCappedButStepsAreNot() {
        var s = DetentScroller()
        let o = s.handle(.precise(dx: 150, t: 0), olderRoom: 10, newerRoom: 10)
        XCTAssertEqual(o.steps, 5); XCTAssertEqual(o.ticks, 1)
        XCTAssertEqual(s.handle(.precise(dx: 30, t: 0.01), olderRoom: 5, newerRoom: 15).ticks, 0)
    }

    func testTrackpadIgnoresVerticalMovement() {
        var s = DetentScroller()
        XCTAssertEqual(s.handle(.precise(dx: 0, dy: -90, t: 0), olderRoom: 10, newerRoom: 10).steps, 0)
    }

    func testMomentumIsIgnoredAndReleaseSettlesOnTheNearestFrame() {
        var s = DetentScroller()
        _ = s.handle(.precise(dx: 20, t: 0), olderRoom: 10, newerRoom: 10)
        let momentum = s.handle(.momentum(dx: 400, t: 0.1), olderRoom: 10, newerRoom: 10)
        XCTAssertEqual(momentum.steps, 0); XCTAssertEqual(momentum.ticks, 0)
        let release = s.handle(.ended(t: 0.2), olderRoom: 10, newerRoom: 10)
        XCTAssertEqual(release.steps, 1); XCTAssertEqual(release.progress, 0); XCTAssertEqual(release.rubberBand, 0)
    }

    func testEndTicksOnceThenRubberBandsAndReversingResumes() {
        var s = DetentScroller()
        let first = s.handle(.precise(dx: 30, t: 0), olderRoom: 0, newerRoom: 4)
        XCTAssertEqual(first.steps, 0); XCTAssertEqual(first.ticks, 1); XCTAssertGreaterThan(first.rubberBand, 0)
        let again = s.handle(.precise(dx: 30, t: 0.1), olderRoom: 0, newerRoom: 4)
        XCTAssertEqual(again.ticks, 0); XCTAssertGreaterThan(again.rubberBand, first.rubberBand)
        XCTAssertLessThanOrEqual(again.rubberBand, DetentScroller.maximumRubberBand)
        XCTAssertEqual(s.handle(.precise(dx: -90, t: 0.2), olderRoom: 0, newerRoom: 4).steps, -1)  // cancels the 60 pt of overscroll, then steps one frame newer
    }

    func testFastSwipesStopAtTheEnd() {
        var s = DetentScroller()
        let o = s.handle(.precise(dx: 150, t: 0), olderRoom: 2, newerRoom: 10)
        XCTAssertEqual(o.steps, 2); XCTAssertGreaterThan(o.rubberBand, 0)
    }

    func testMouseWheelStepsOnePerNotchWithoutTicks() {
        var s = DetentScroller()
        XCTAssertEqual(s.handle(.wheel(dy: -3, t: 0), olderRoom: 10, newerRoom: 10),
                       DetentOutput(steps: 1, ticks: 0, progress: 0, rubberBand: 0))
        XCTAssertEqual(s.handle(.wheel(dy: 2, t: 0.1), olderRoom: 0, newerRoom: 0).steps, 0)
    }
}

private extension DetentInput {
    static func precise(dx: CGFloat, dy: CGFloat = 0, t: TimeInterval) -> DetentInput {
        DetentInput(deltaX: dx, deltaY: dy, isPrecise: true, phase: .changed, isMomentum: false, time: t)
    }

    static func momentum(dx: CGFloat, t: TimeInterval) -> DetentInput {
        DetentInput(deltaX: dx, deltaY: 0, isPrecise: true, phase: .none, isMomentum: true, time: t)
    }

    static func ended(t: TimeInterval) -> DetentInput {
        DetentInput(deltaX: 0, deltaY: 0, isPrecise: true, phase: .ended, isMomentum: false, time: t)
    }

    static func wheel(dy: CGFloat, t: TimeInterval) -> DetentInput {
        DetentInput(deltaX: 0, deltaY: dy, isPrecise: false, phase: .none, isMomentum: false, time: t)
    }
}
