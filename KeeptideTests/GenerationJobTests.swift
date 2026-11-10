import XCTest
@testable import Keeptide

@MainActor
final class GenerationJobTests: XCTestCase {
    private let key = GenerationKey(item: "clip-1", action: "translate")

    func testAJobGoesFromWaitingThroughStreamingToFinished() async {
        let center = makeCenter()
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .onDevice, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        XCTAssertEqual(job.snapshot.phase, .waiting)
        XCTAssertTrue(center.job(for: key) === job)

        source.send(.started(GenerationInfo(engine: "On this Mac")), .delta("Hel"))
        await waitUntil("text arrives") { job.snapshot.text() == "Hel" }
        XCTAssertEqual(job.snapshot.phase, .streaming)
        XCTAssertEqual(job.snapshot.info?.engine, "On this Mac")

        source.send(.delta("lo"), .finished(.completed))
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .finished(.completed))
        XCTAssertEqual(job.snapshot.text(), "Hello")
        XCTAssertEqual(job.snapshot.progress, 1)
        XCTAssertEqual(finals, [job.snapshot])
        XCTAssertEqual(finals.first?.saveDecision, .replace)
        XCTAssertNil(center.job(for: key))
    }

    func testStoppingKeepsTheTextReceivedSoFar() async {
        let center = makeCenter()
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("A partial"))
        await waitUntil("text arrives") { job.snapshot.text() == "A partial" }

        center.stop(key)
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .stopped(.person))
        XCTAssertEqual(job.snapshot.text(), "A partial")
        XCTAssertEqual(job.snapshot.saveDecision, .keepIfNoCompleteResult)
        XCTAssertTrue(source.wasCancelled, "stopping cancels the request")
    }

    func testAnErrorAfterStoppingStillEndsAsStopped() async {
        let center = makeCenter()
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("Text"))
        await waitUntil("text arrives") { job.snapshot.hasText }
        job.stop()
        source.end(throwing: URLError(.cancelled))
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .stopped(.person))
    }

    func testStoppingAsTheResultCompletesEndsOnce() async {
        let center = makeCenter()
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("Done"), .finished(.completed))
        job.stop()
        await waitUntil("the job ends") { !finals.isEmpty }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(finals.count, 1)
        XCTAssertTrue([.finished(.completed), .stopped(.person)].contains(job.snapshot.phase))
    }

    func testAFailureKeepsTheTextAndTheReason() async {
        let center = makeCenter()
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("Some text"))
        await waitUntil("text arrives") { job.snapshot.hasText }

        let busy = GenerationError(kind: .overloaded, message: "Claude is busy right now. Try again.")
        source.end(throwing: busy)
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .failed(busy))
        XCTAssertEqual(job.snapshot.text(), "Some text")
        XCTAssertEqual(job.snapshot.saveDecision, .discard)
    }

    func testAStreamThatStopsWithoutFinishingIsInterrupted() async {
        let center = makeCenter()
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("Cut"))
        source.end()
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .failed(.interrupted))
        XCTAssertEqual(job.snapshot.text(), "Cut")
    }

    func testNoTextWithinTheFirstTextLimitFails() async {
        let clock = ManualClock()
        let center = makeCenter(clock: clock)
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.started(GenerationInfo(engine: "Claude Haiku 5.5")))

        clock.advance(by: .seconds(44))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(job.snapshot.phase.isActive, "events without text don't count, but the limit hasn't passed")

        clock.advance(by: .seconds(2))
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .failed(.interrupted))
        XCTAssertTrue(source.wasCancelled)
    }

    func testSilenceAfterTextFailsAfterTheIdleLimitAndKeepsTheText() async {
        let clock = ManualClock()
        let center = makeCenter(clock: clock)
        let source = ControlledSource()
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: options(), source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("First words"))
        await waitUntil("text arrives") { job.snapshot.hasText }

        clock.advance(by: .seconds(59))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(job.snapshot.phase, .streaming)

        clock.advance(by: .seconds(2))
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.phase, .failed(.interrupted))
        XCTAssertEqual(job.snapshot.text(), "First words")
    }

    func testANewRequestForTheSameItemAndActionReplacesTheRunningOne() async {
        let center = makeCenter()
        let first = ControlledSource()
        let second = ControlledSource()
        var firstFinals: [GenerationSnapshot] = []
        let firstJob = center.start(key, lane: .onDevice, priority: .user, options: options(), source: first) {
            firstFinals.append($0)
        }
        await waitUntil("the first source starts") { first.startCount == 1 }
        first.send(.delta("Chinese so far"))
        await waitUntil("text arrives") { firstJob.snapshot.hasText }

        let secondJob = center.start(key, lane: .onDevice, priority: .user, options: options(), source: second) { _ in }
        XCTAssertTrue(center.job(for: key) === secondJob)
        await waitUntil("the first job ends") { !firstFinals.isEmpty }
        XCTAssertEqual(firstFinals.first?.phase, .stopped(.superseded))
        XCTAssertEqual(firstFinals.first?.saveDecision, .discard, "a replaced request's text isn't kept")
        await waitUntil("the second source starts once the lane is free") { second.startCount == 1 }
        XCTAssertTrue(center.job(for: key) === secondJob)
    }

    func testWorkOnThisMacRunsOneJobAtATimeAndPeopleGoFirst() async {
        let center = makeCenter()
        let automaticA = ControlledSource()
        let automaticB = ControlledSource()
        let person = ControlledSource()
        let a = center.start(item("a"), lane: .onDevice, priority: .automatic, options: options(), source: automaticA) { _ in }
        let b = center.start(item("b"), lane: .onDevice, priority: .automatic, options: options(), source: automaticB) { _ in }
        let c = center.start(item("c"), lane: .onDevice, priority: .user, options: options(), source: person) { _ in }
        await waitUntil("the first job starts") { automaticA.startCount == 1 }
        XCTAssertEqual(b.snapshot.phase, .queued)
        XCTAssertEqual(c.snapshot.phase, .queued)
        XCTAssertEqual(center.jobs.count, 3)

        automaticA.send(.delta("Done"), .finished(.completed))
        await waitUntil("the person's job starts next") { person.startCount == 1 }
        XCTAssertEqual(a.snapshot.phase, .finished(.completed))
        XCTAssertEqual(b.snapshot.phase, .queued)
        XCTAssertEqual(automaticB.startCount, 0)
    }

    func testJobsOfTheSamePriorityStartInTheOrderTheyCame() async {
        let center = makeCenter()
        let sources = (0..<3).map { _ in ControlledSource() }
        for (index, source) in sources.enumerated() {
            center.start(item("\(index)"), lane: .onDevice, priority: .automatic, options: options(), source: source) { _ in }
        }
        await waitUntil("the first job starts") { sources[0].startCount == 1 }
        sources[0].send(.delta("One"), .finished(.completed))
        await waitUntil("the second job starts") { sources[1].startCount == 1 }
        XCTAssertEqual(sources[2].startCount, 0)
    }

    func testCloudRequestsRunThreeAtATime() async {
        let center = makeCenter()
        let sources = (0..<4).map { _ in ControlledSource() }
        let jobs = sources.enumerated().map { index, source in
            center.start(item("\(index)"), lane: .cloud, priority: .user, options: options(), source: source) { _ in }
        }
        await waitUntil("three requests start") { sources.prefix(3).allSatisfy { $0.startCount == 1 } }
        XCTAssertEqual(jobs[3].snapshot.phase, .queued)
        XCTAssertEqual(sources[3].startCount, 0)

        jobs[1].stop()
        await waitUntil("the fourth request starts") { sources[3].startCount == 1 }
    }

    func testStoppingAQueuedJobEndsItWithoutStartingIt() async {
        let center = makeCenter()
        let running = ControlledSource()
        let queued = ControlledSource()
        center.start(item("a"), lane: .onDevice, priority: .user, options: options(), source: running) { _ in }
        var finals: [GenerationSnapshot] = []
        let job = center.start(item("b"), lane: .onDevice, priority: .user, options: options(), source: queued) {
            finals.append($0)
        }
        await waitUntil("the first job starts") { running.startCount == 1 }

        center.stop(item("b"))
        XCTAssertEqual(job.snapshot.phase, .stopped(.person))
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.saveDecision, .discard)
        XCTAssertNil(center.job(for: item("b")))
        XCTAssertEqual(queued.startCount, 0)
    }

    func testStoppingEverythingDiscardsWhatWasRunning() async {
        let center = makeCenter()
        let running = ControlledSource()
        let queued = ControlledSource()
        var finals: [GenerationSnapshot] = []
        center.start(item("a"), lane: .onDevice, priority: .user, options: options(), source: running) { finals.append($0) }
        center.start(item("b"), lane: .onDevice, priority: .user, options: options(), source: queued) { finals.append($0) }
        await waitUntil("the first job starts") { running.startCount == 1 }
        running.send(.delta("Half"))
        await waitUntil("text arrives") { center.job(for: item("a"))?.snapshot.hasText == true }

        center.stopAll()
        await waitUntil("both jobs end") { finals.count == 2 }
        XCTAssertTrue(finals.allSatisfy { $0.phase == .stopped(.shutdown) })
        XCTAssertTrue(finals.allSatisfy { $0.saveDecision == .discard })
        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertEqual(queued.startCount, 0)
    }

    func testATaggedRequestFillsBothChannelsAndReportsProgress() async {
        let center = makeCenter()
        let source = ControlledSource()
        var tagged = options()
        tagged.taggedChannels = StreamAccumulator.TaggedChannels(["text": OutputChannel("text"), "translation": .main])
        tagged.expectedParagraphs = 2
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: tagged, source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("<text>One\n\nTwo</text><translation>一\n\n二"))
        await waitUntil("the translation starts") { job.snapshot.text() == "一\n\n二" }
        XCTAssertEqual(job.snapshot.text(OutputChannel("text")), "One\n\nTwo")
        XCTAssertEqual(job.snapshot.progress, 0.5)

        source.send(.delta("</translation>"), .finished(.completed))
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertEqual(job.snapshot.progress, 1)
        XCTAssertFalse(job.snapshot.separationFailed)
    }

    func testSnapshotsArriveOncePerIntervalAndTheLastAlwaysArrives() async {
        let center = makeCenter(clock: ContinuousClock())
        let source = ControlledSource()
        var throttled = GenerationJob.Options()
        throttled.publishInterval = .milliseconds(20)
        var finals: [GenerationSnapshot] = []
        let job = center.start(key, lane: .cloud, priority: .user, options: throttled, source: source) {
            finals.append($0)
        }
        await waitUntil("the source starts") { source.startCount == 1 }
        source.send(.delta("Quiet after this"))
        await waitUntil("the text arrives without another event") { job.snapshot.text() == "Quiet after this" }

        for word in 0..<200 { source.send(.delta(" \(word)")) }
        source.send(.finished(.completed))
        await waitUntil("the job ends") { !finals.isEmpty }
        XCTAssertTrue(job.snapshot.text().hasSuffix(" 199"))
        XCTAssertEqual(job.snapshot.phase, .finished(.completed))
    }

    func testDisplayModesFollowThePhase() {
        XCTAssertEqual(StreamingTextDisplay.Mode(.queued), .still, "nothing is written while a job waits its turn")
        XCTAssertEqual(StreamingTextDisplay.Mode(.waiting), .writing)
        XCTAssertEqual(StreamingTextDisplay.Mode(.streaming), .writing)
        XCTAssertEqual(StreamingTextDisplay.Mode(.finished(.truncated)), .finishing)
        XCTAssertEqual(StreamingTextDisplay.Mode(.stopped(.person)), .still)
        XCTAssertEqual(StreamingTextDisplay.Mode(.failed(.interrupted)), .still)
    }

    func testAWholeResultReplacesAnEarlierOneWithTextOrWithout() {
        func decision(_ phase: GenerationSnapshot.Phase, text: String = "Text") -> SaveDecision {
            GenerationSnapshot(phase: phase, texts: [.main: text]).saveDecision
        }
        XCTAssertEqual(decision(.finished(.completed)), .replace)
        // Finding nothing, as in an image without text, is a whole result too: it leaves no earlier one.
        XCTAssertEqual(decision(.finished(.completed), text: ""), .clear)
        XCTAssertEqual(decision(.finished(.truncated)), .keepIfNoCompleteResult)
        XCTAssertEqual(decision(.stopped(.person)), .keepIfNoCompleteResult)
        XCTAssertEqual(decision(.stopped(.person), text: ""), .discard)
        XCTAssertEqual(decision(.stopped(.superseded)), .discard)
        XCTAssertEqual(decision(.stopped(.shutdown)), .discard)
        XCTAssertEqual(decision(.finished(.refused)), .discard)
        XCTAssertEqual(decision(.failed(.interrupted)), .discard)
        XCTAssertEqual(decision(.failed(.interrupted), text: ""), .discard)
    }

    /// A center whose jobs stop when the test ends, with snapshots published for every event unless a test says
    /// otherwise.
    private func makeCenter(clock: any Clock<Duration> = ManualClock()) -> JobCenter {
        let center = JobCenter(clock: clock)
        addTeardownBlock { @MainActor in center.stopAll() }
        return center
    }

    private func options() -> GenerationJob.Options {
        var options = GenerationJob.Options()
        options.publishInterval = .zero
        return options
    }

    private func item(_ name: String) -> GenerationKey {
        GenerationKey(item: name, action: "translate")
    }
}
