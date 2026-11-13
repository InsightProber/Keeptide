import Foundation
import Observation
import os

/// Anything that generates text: a cloud provider's stream, an engine on this Mac, a scripted source in tests.
///
/// A source:
/// - returns its stream at once and does the work in a task, so stopping and the time limits always work;
/// - ends a whole result with `.finished(.completed)`, sending `.usage` before it, since events after it are ignored;
///   a stream that ends without `.finished` counts as interrupted;
/// - cancels its work from the stream's `onTermination`, which reports `.cancelled` whenever the job stops reading:
///   after `.finished`, at a time limit, or synchronously on the main thread when a person stops the job;
/// - sends paragraphs in order, separated by a blank line, when its output has paragraphs.
protocol GenerationSource: Sendable {
    func events() -> AsyncThrowingStream<GenerationEvent, any Error>
}

/// One generation for one item and action. The job owns the task that reads its source: events are joined off the
/// main thread, and `snapshot`, which surfaces observe, changes at most once per `publishInterval`. `JobCenter`
/// queues, starts and stops jobs. A job doesn't depend on any surface: it runs to its end with the panel closed, and a
/// surface that opens later shows its latest snapshot.
@MainActor
@Observable
final class GenerationJob {
    struct Options: Sendable {
        /// Tags that split the stream into channels, when one request asks for two texts.
        var taggedChannels: StreamAccumulator.TaggedChannels?
        /// How many paragraphs the result should have, such as the original's for a translation. With it, snapshots
        /// report progress. A source that learns the count only once it runs says it with `.expecting`, which wins.
        var expectedParagraphs: Int?
        /// The channel whose paragraphs count toward progress.
        var progressChannel: OutputChannel = .main
        /// The longest wait for the first text: 45 seconds, or 90 for an image.
        var firstTextTimeout: Duration = .seconds(45)
        /// The longest silence between events once text has started.
        var idleTimeout: Duration = .seconds(60)
        /// Snapshots are built and published at most this often: about 30 times a second. Zero publishes one for
        /// every event, which tests use.
        var publishInterval: Duration = .milliseconds(33)
    }

    let key: GenerationKey
    let lane: JobLane
    let priority: JobPriority
    private(set) var snapshot = GenerationSnapshot(phase: .queued)

    @ObservationIgnored private let options: Options
    @ObservationIgnored private let source: any GenerationSource
    @ObservationIgnored private let onEnd: (GenerationJob) -> Void
    /// The task reading the source, kept where `deinit` can cancel it, so a dropped job doesn't run on.
    @ObservationIgnored private let producer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    @ObservationIgnored private var stopReason: GenerationSnapshot.StopReason?
    /// Whether it has left its lane's queue. Observed, so that a card can tell a running job from a waiting one
    /// without following every snapshot.
    private(set) var hasStarted = false
    @ObservationIgnored private var hasEnded = false

    /// `onEnd` is called once, on the main thread, when the job has ended and `snapshot` is final.
    init(
        key: GenerationKey, lane: JobLane, priority: JobPriority, options: Options, source: any GenerationSource,
        onEnd: @escaping (GenerationJob) -> Void
    ) {
        self.key = key
        self.lane = lane
        self.priority = priority
        self.options = options
        self.source = source
        self.onEnd = onEnd
    }

    deinit {
        producer.withLock { $0?.cancel() }
    }

    /// Starts reading the source. Only `JobCenter` calls this, when the job's lane has room.
    func start(clock: any Clock<Duration>) {
        guard !hasStarted, !hasEnded else { return }
        hasStarted = true
        snapshot.phase = .waiting
        let (snapshots, continuation) = AsyncStream.makeStream(
            of: GenerationSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let source = source
        let options = options
        let task = Task.detached(priority: priority == .user ? .userInitiated : .utility) {
            let last = await GenerationJob.produce(source: source, options: options, clock: clock) {
                continuation.yield($0)
            }
            continuation.yield(last)
            continuation.finish()
        }
        producer.withLock { $0 = task }
        // Only the newest snapshot waits, so a busy main thread takes one change at a time and the last always arrives.
        Task { [weak self] in
            for await next in snapshots {
                guard let self else { return }
                var next = next
                if case .stopped = next.phase { next.phase = .stopped(self.stopReason ?? .person) }
                self.snapshot = next
            }
            self?.end()
        }
    }

    /// Stops the job. The text received so far stays in `snapshot`, and the job ends as stopped for `reason`.
    func stop(_ reason: GenerationSnapshot.StopReason = .person) {
        guard !hasEnded, stopReason == nil else { return }
        stopReason = reason
        if hasStarted {
            producer.withLock { $0?.cancel() }
        } else {
            snapshot.phase = .stopped(reason)
            end()
        }
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        producer.withLock { $0 = nil }
        onEnd(self)
    }

    // MARK: Off the main thread

    private enum Part: Sendable {
        case read(Reading)
        case watchdog(fired: Bool)
        case publisher
    }

    private enum Reading: Sendable {
        case ended
        case failed(GenerationError)
        case cancelled
    }

    /// What the reader, the watchdog and the publisher share.
    private struct State<Instant: InstantProtocol>: Sendable {
        var accumulator: StreamAccumulator
        var lastEvent: Instant
        var sawText = false
        /// Whether the accumulator changed since the last snapshot.
        var changed = false
    }

    /// Reads the source to its end, within the time limits, and returns the final snapshot.
    nonisolated private static func produce<C: Clock<Duration>>(
        source: any GenerationSource, options: Options, clock: C,
        deliver: @escaping @Sendable (GenerationSnapshot) -> Void
    ) async -> GenerationSnapshot {
        let start = clock.now
        let state = OSAllocatedUnfairLock(
            initialState: State(accumulator: StreamAccumulator(taggedChannels: options.taggedChannels), lastEvent: start))
        let (reading, timedOut) = await withTaskGroup(of: Part.self) { group in
            group.addTask { await read(source: source, options: options, clock: clock, state: state, deliver: deliver) }
            group.addTask { await watch(clock: clock, start: start, state: state, options: options) }
            if options.publishInterval > .zero {
                group.addTask { await publish(clock: clock, state: state, options: options, deliver: deliver) }
            }
            var reading = Reading.cancelled
            var timedOut = false
            for await part in group {
                switch part {
                case .read(let result):
                    reading = result
                    group.cancelAll()
                case .watchdog(let fired):
                    if fired {
                        timedOut = true
                        group.cancelAll()
                    }
                case .publisher:
                    break
                }
            }
            return (reading, timedOut)
        }
        let accumulator = state.withLock { state -> StreamAccumulator in
            state.accumulator.finish()
            return state.accumulator
        }
        let phase: GenerationSnapshot.Phase = switch reading {
        case .ended: accumulator.finishReason.map { GenerationSnapshot.Phase.finished($0) } ?? .failed(.interrupted)
        case .failed(let error): .failed(error)
        // The main thread replaces the reason with the one the job was stopped for.
        case .cancelled: timedOut ? .failed(.interrupted) : .stopped(.person)
        }
        return snapshot(of: accumulator, phase: phase, options: options)
    }

    nonisolated private static func read<C: Clock<Duration>>(
        source: any GenerationSource, options: Options, clock: C, state: OSAllocatedUnfairLock<State<C.Instant>>,
        deliver: @Sendable (GenerationSnapshot) -> Void
    ) async -> Part {
        // A job stopped before its task ran never asks its source for anything, so no request goes out.
        guard !Task.isCancelled else { return .read(.cancelled) }
        let publishesEveryEvent = options.publishInterval == .zero
        do {
            for try await event in source.events() {
                let now = clock.now
                let update = state.withLock { state -> GenerationSnapshot? in
                    state.accumulator.apply(event)
                    state.lastEvent = now
                    if event.carriesText { state.sawText = true }
                    state.changed = true
                    guard publishesEveryEvent else { return nil }
                    state.changed = false
                    return streamingSnapshot(of: state.accumulator, options: options)
                }
                if case .finished = event { break }
                if let update { deliver(update) }
            }
        } catch {
            if Task.isCancelled { return .read(.cancelled) }
            return .read(.failed(error as? GenerationError ?? .interrupted))
        }
        // A stream ends early when its reader is cancelled, so an end without a finish reason is a stop here.
        if Task.isCancelled, state.withLock({ $0.accumulator.finishReason }) == nil { return .read(.cancelled) }
        return .read(.ended)
    }

    /// Fires when no text arrives within the first-text limit, or nothing at all within the idle limit after that.
    nonisolated private static func watch<C: Clock<Duration>>(
        clock: C, start: C.Instant, state: OSAllocatedUnfairLock<State<C.Instant>>, options: Options
    ) async -> Part {
        func deadline() -> C.Instant {
            state.withLock { state in
                state.sawText
                    ? state.lastEvent.advanced(by: options.idleTimeout)
                    : start.advanced(by: options.firstTextTimeout)
            }
        }
        while true {
            do {
                try await clock.sleep(until: deadline(), tolerance: nil)
            } catch {
                return .watchdog(fired: false)
            }
            if clock.now >= deadline() { return .watchdog(fired: true) }
        }
    }

    /// Publishes the latest text once per interval, when it changed. Building a snapshot copies the text, so doing it
    /// at most this often keeps long outputs cheap.
    nonisolated private static func publish<C: Clock<Duration>>(
        clock: C, state: OSAllocatedUnfairLock<State<C.Instant>>, options: Options,
        deliver: @Sendable (GenerationSnapshot) -> Void
    ) async -> Part {
        while true {
            do {
                try await clock.sleep(for: options.publishInterval)
            } catch {
                return .publisher
            }
            let changed = state.withLock { state -> StreamAccumulator? in
                guard state.changed else { return nil }
                state.changed = false
                return state.accumulator
            }
            if let changed { deliver(streamingSnapshot(of: changed, options: options)) }
        }
    }

    nonisolated private static func streamingSnapshot(
        of accumulator: StreamAccumulator, options: Options
    ) -> GenerationSnapshot {
        snapshot(of: accumulator, phase: accumulator.hasText ? .streaming : .waiting, options: options)
    }

    nonisolated private static func snapshot(
        of accumulator: StreamAccumulator, phase: GenerationSnapshot.Phase, options: Options
    ) -> GenerationSnapshot {
        var progress: Double?
        if case .finished(.completed) = phase {
            progress = 1
        } else if let expected = accumulator.expectedParagraphs ?? options.expectedParagraphs, expected > 0 {
            let done = accumulator.completedParagraphCount(in: options.progressChannel)
            progress = min(1, Double(done) / Double(expected))
        }
        return GenerationSnapshot(
            phase: phase, info: accumulator.info, texts: accumulator.texts, usage: accumulator.usage,
            progress: progress, separationFailed: accumulator.separationFailed)
    }
}
