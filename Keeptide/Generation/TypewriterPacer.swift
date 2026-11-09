import Foundation

/// Decides how much of a growing text to show at a given moment. Every character appears no later than
/// `maximumDelay` after it arrives, and while any is waiting, at least `minimumRate` appear a second: a trickle types
/// at an even pace, and a burst is written out evenly within the delay. It is a value driven by explicit times, so the
/// display link and tests run the same code. It counts characters (`Character`), so an emoji or an accented letter
/// never appears in halves.
struct TypewriterPacer: Equatable, Sendable {
    /// Starting values, to be checked on a signed build with Chinese and English text.
    struct Tuning: Equatable, Sendable {
        /// Characters a second while any are waiting.
        var minimumRate: Double = 40
        /// The longest a character waits between arriving and appearing, in seconds.
        var maximumDelay: Double = 0.3
    }

    var tuning: Tuning
    /// Characters shown.
    private(set) var revealed = 0
    /// Characters received.
    private(set) var received = 0

    private struct Batch: Equatable, Sendable {
        var count: Int
        var deadline: Double
    }

    /// Characters received but not shown, oldest first, each batch with the time it must appear by.
    private var batches: [Batch] = []
    /// Part of a character earned at the current pace and not shown yet.
    private var budget = 0.0
    private var lastTime: Double?

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    var isCaughtUp: Bool { revealed >= received }

    /// Records that the text has `total` characters as of `time`.
    mutating func receive(total: Int, at time: Double) {
        guard total > received else { return }
        if isCaughtUp {
            // Time spent caught up, and pace left from the last burst, don't carry over to new text.
            lastTime = time
            budget = 0
        }
        batches.append(Batch(count: total - received, deadline: time + tuning.maximumDelay))
        received = total
    }

    /// Moves to `time` and returns how many characters to show.
    @discardableResult
    mutating func advance(to time: Double) -> Int {
        let elapsed = max(0, time - (lastTime ?? time))
        lastTime = time
        guard !isCaughtUp else {
            budget = 0
            return revealed
        }
        // Batches whose time has come are due now. Each later batch sets the pace that gets it, and everything
        // before it, out by its deadline.
        var due = 0
        var waiting = 0
        var rate = tuning.minimumRate
        for batch in batches {
            waiting += batch.count
            let left = batch.deadline - time
            if left <= 0 {
                due = waiting
            } else {
                rate = max(rate, Double(waiting) / left)
            }
        }
        budget += rate * elapsed
        let step = min(received - revealed, max(due, Int(min(budget, Double(received)))))
        budget = min(max(0, budget - Double(step)), Double(received - revealed - step))
        show(step)
        return revealed
    }

    /// Shows everything received: when a generation stops, or a display that was away comes back.
    mutating func revealAll() {
        show(received - revealed)
        budget = 0
    }

    /// Starts over with `total` characters, all of them shown: for a surface that opens on text already there, or
    /// text that changed other than by growing.
    mutating func reset(showing total: Int) {
        revealed = total
        received = total
        batches = []
        budget = 0
        lastTime = nil
    }

    private mutating func show(_ count: Int) {
        guard count > 0 else { return }
        revealed += count
        var left = count
        while left > 0, !batches.isEmpty {
            let taken = min(left, batches[0].count)
            batches[0].count -= taken
            left -= taken
            if batches[0].count == 0 { batches.removeFirst() }
        }
    }
}
