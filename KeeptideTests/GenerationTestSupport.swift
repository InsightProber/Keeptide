import Foundation
import XCTest
@testable import Keeptide

/// A clock that moves only when a test moves it.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    var now: Instant { lock.withLock { current } }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// A source a test drives by hand. It sends events, ends or fails the stream, and records whether the job
/// cancelled it.
final class ControlledSource: GenerationSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation?
    private var starts = 0
    private var cancelled = false

    var startCount: Int { lock.withLock { starts } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func events() -> AsyncThrowingStream<GenerationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self, throwing: (any Error).self)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.markCancelled() }
        }
        lock.withLock {
            self.continuation = continuation
            starts += 1
        }
        return stream
    }

    func send(_ events: GenerationEvent..., file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation = lock.withLock({ continuation }) else {
            return XCTFail("The source hasn't started", file: file, line: line)
        }
        for event in events { continuation.yield(event) }
    }

    func end(throwing error: (any Error)? = nil) {
        lock.withLock { continuation }?.finish(throwing: error)
    }

    private func markCancelled() {
        lock.withLock { cancelled = true }
    }
}

/// Waits, a few milliseconds at a time, until `condition` holds.
@MainActor
func waitUntil(
    _ description: String, timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline {
            return XCTFail("Timed out waiting until \(description)", file: file, line: line)
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
