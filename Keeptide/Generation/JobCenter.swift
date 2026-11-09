import Foundation
import Observation

/// One item and one action. At most one job runs for it: starting another stops the first, and the latest request
/// wins.
struct GenerationKey: Hashable, Sendable {
    /// The item, as the feature identifies it.
    var item: String
    /// What is being made, such as "translate" or "extractText".
    var action: String
}

/// Where a job runs. Work on this Mac goes one job at a time, and cloud requests up to three at once.
enum JobLane: Hashable, Sendable {
    case onDevice
    case cloud
}

/// Jobs a person started go ahead of automatic ones waiting in the same lane, and their work runs at a higher priority.
enum JobPriority: Int, Comparable, Sendable {
    case automatic
    case user

    static func < (lhs: JobPriority, rhs: JobPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Every generation that is waiting or running. It queues them per lane, limits how many run at once and keeps one job
/// per item and action. Status marks on cards and Library rows read `jobs`. A job leaves when it ends, and its final
/// snapshot goes to the completion given when it started, which saves the result as `saveDecision` says.
@MainActor
@Observable
final class JobCenter {
    /// Jobs waiting or running, by item and action.
    private(set) var jobs: [GenerationKey: GenerationJob] = [:]

    @ObservationIgnored private let limits: [JobLane: Int]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var waiting: [JobLane: [GenerationJob]] = [:]
    @ObservationIgnored private var running: [JobLane: [GenerationJob]] = [:]

    init(limits: [JobLane: Int] = [.onDevice: 1, .cloud: 3], clock: any Clock<Duration> = ContinuousClock()) {
        self.limits = limits
        self.clock = clock
    }

    func job(for key: GenerationKey) -> GenerationJob? {
        jobs[key]
    }

    /// Queues a job and starts it as soon as its lane has room. A job waiting or running for the same item and action
    /// is stopped as superseded. `completion` receives the final snapshot once, on the main thread, and may start
    /// another job.
    @discardableResult
    func start(
        _ key: GenerationKey, lane: JobLane, priority: JobPriority, options: GenerationJob.Options = .init(),
        source: any GenerationSource, completion: @escaping (GenerationSnapshot) -> Void
    ) -> GenerationJob {
        let previous = jobs[key]
        let job = GenerationJob(key: key, lane: lane, priority: priority, options: options, source: source) {
            [weak self] job in
            self?.remove(job)
            completion(job.snapshot)
        }
        jobs[key] = job
        var queue = waiting[lane, default: []]
        queue.insert(job, at: queue.firstIndex { $0.priority < priority } ?? queue.endIndex)
        waiting[lane] = queue
        previous?.stop(.superseded)
        startWaitingJobs(in: lane)
        return job
    }

    func stop(_ key: GenerationKey) {
        jobs[key]?.stop(.person)
    }

    /// Stops everything, as when Keeptide quits or switches libraries.
    func stopAll() {
        for job in Array(jobs.values) { job.stop(.shutdown) }
    }

    private func startWaitingJobs(in lane: JobLane) {
        let limit = limits[lane] ?? 1
        while running[lane, default: []].count < limit, var queue = waiting[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[lane] = queue
            running[lane, default: []].append(next)
            next.start(clock: clock)
        }
    }

    private func remove(_ job: GenerationJob) {
        waiting[job.lane]?.removeAll { $0 === job }
        running[job.lane]?.removeAll { $0 === job }
        if jobs[job.key] === job { jobs[job.key] = nil }
        startWaitingJobs(in: job.lane)
    }
}
