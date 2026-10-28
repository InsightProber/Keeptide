import AppKit

/// Where a scroll event sits in its gesture. `began` starts a new gesture from rest. An ordinary
/// mouse wheel has no phase, and neither does a trackpad event that carries no movement, such as
/// the fingers resting before a swipe.
enum DetentPhase {
    case began, changed, ended, cancelled, none
}

/// One scroll event. The system has already applied the user's natural scrolling setting, so a
/// positive `deltaX` always means the content moved right and an older clip came toward the centre.
struct DetentInput: Equatable {
    var deltaX: CGFloat
    var deltaY: CGFloat
    /// True for a trackpad. An ordinary mouse wheel reports whole notches instead of points.
    var isPrecise: Bool
    var phase: DetentPhase
    /// The coasting the system sends after the fingers have left the trackpad.
    var isMomentum: Bool
    var time: TimeInterval
}

struct DetentOutput: Equatable {
    /// Clips to move: positive toward older, negative toward newer, never beyond the room given.
    var steps: Int
    /// Haptic ticks to play, 0 or 1.
    var ticks: Int
    /// The push toward the next clip as a share of one clip, from -1 to 1. The strip follows the
    /// fingers by this much; it is 0 once they lift and for a mouse wheel.
    var progress: CGFloat
    /// The stretch past an end in points, positive past the oldest clip and capped at
    /// `DetentScroller.maximumRubberBand`. It is 0 once the fingers lift and for a mouse wheel.
    var rubberBand: CGFloat
}

private extension DetentOutput {
    /// Steps and ticks with nothing left over: no push toward the next clip and no stretch.
    static func atRest(steps: Int = 0, ticks: Int = 0) -> DetentOutput {
        DetentOutput(steps: steps, ticks: ticks, progress: 0, rubberBand: 0)
    }
}

/// Turns scroll events into whole-clip steps, at most one haptic tick per event, and the leftover
/// movement to show while the fingers are down. It does not know the selection: every event says
/// how many clips are left in each direction, and the caller applies `steps` before the next one.
struct DetentScroller {
    /// Horizontal travel of the fingers for one clip.
    static let distance: CGFloat = 30
    /// Ticks closer together than this blur into a buzz.
    static let minimumTickInterval: TimeInterval = 0.033
    static let maximumRubberBand: CGFloat = 24
    /// Stretch shown per point pushed past an end.
    private static let rubberBandRatio: CGFloat = 0.3
    /// The most push kept past an end: just enough to stretch the band to its maximum.
    private static let overscrollLimit = maximumRubberBand / rubberBandRatio

    /// Push not yet turned into steps, positive toward older clips. Where no clip is left to move
    /// to it is overscroll. Only up to `overscrollLimit` of it is kept, so however long the lean on
    /// an end, pushing back unwinds at most that much before the strip moves again.
    private var pending: CGFloat = 0
    /// Whether the current push past an end has had its tick. A step or a lift starts it over.
    private var hasTickedAtEnd = false
    private var lastTick: TimeInterval?
    /// The progress and stretch last reported. An event that changes nothing repeats them, so the
    /// strip does not snap back to rest in the middle of a gesture.
    private var shownProgress: CGFloat = 0
    private var shownRubberBand: CGFloat = 0

    /// The output of an event that changes nothing.
    private var unchanged: DetentOutput {
        DetentOutput(steps: 0, ticks: 0, progress: shownProgress, rubberBand: shownRubberBand)
    }

    /// `olderRoom` and `newerRoom` are how many more clips the selection can move each way; a
    /// negative count is taken as none. An event that changes nothing, coasting or a trackpad
    /// event without a phase, gives no steps or ticks and repeats the progress and stretch last
    /// reported, so every output can be applied as it comes.
    mutating func handle(_ input: DetentInput, olderRoom: Int, newerRoom: Int) -> DetentOutput {
        let older = max(0, olderRoom), newer = max(0, newerRoom)
        // Coasting is ignored: the strip stops on the clip the fingers chose, and a tick played
        // after they lift would not be felt.
        if input.isMomentum { return unchanged }
        guard input.isPrecise else {
            // One clip per notch and no tick: the wheel's own click is the feedback. A wheel turned
            // so the content scrolls down (negative `deltaY`) goes toward older clips, as in a list.
            let direction = input.deltaX != 0 ? input.deltaX : -input.deltaY
            return .atRest(steps: direction > 0 ? min(1, older) : direction < 0 ? -min(1, newer) : 0)
        }
        // A swipe starts at rest. The last one may never have ended, for example when the panel
        // closed with the fingers down, and must not leak into this one.
        if input.phase == .began { reset() }
        switch input.phase {
        case .began, .changed: return track(input, older: older, newer: newer)
        case .ended, .cancelled: return release(at: input.time, older: older, newer: newer)
        case .none: return unchanged
        }
    }

    /// Fingers moving. Only the horizontal movement counts, so a stray vertical drag does nothing.
    private mutating func track(_ input: DetentInput, older: Int, newer: Int) -> DetentOutput {
        pending += input.deltaX
        let whole = Int((pending / Self.distance).rounded(.towardZero))
        let steps = whole > 0 ? min(whole, older) : -min(-whole, newer)
        pending -= CGFloat(steps) * Self.distance
        // What is left leans toward the next clip while there is one; with none left that way it
        // is overscroll, which stretches the end.
        let room = pending > 0 ? older - steps : newer + steps
        let overscroll = room > 0 ? 0 : pending
        // Only what the band can show is kept. With room left the push is under one clip, so this
        // only ever trims overscroll.
        pending = max(-Self.overscrollLimit, min(Self.overscrollLimit, pending))
        if steps != 0 { hasTickedAtEnd = false }
        var wantsTick = steps != 0
        if abs(overscroll) >= Self.distance, !hasTickedAtEnd {
            hasTickedAtEnd = true
            wantsTick = true
        }
        shownProgress = room > 0 ? pending / Self.distance : 0
        shownRubberBand = max(-Self.maximumRubberBand, min(Self.maximumRubberBand, overscroll * Self.rubberBandRatio))
        return DetentOutput(
            steps: steps, ticks: pacedTick(wanted: wantsTick, at: input.time),
            progress: shownProgress, rubberBand: shownRubberBand
        )
    }

    /// Fingers lifted: settle on the nearest clip, so half a clip or more of push completes its step.
    private mutating func release(at time: TimeInterval, older: Int, newer: Int) -> DetentOutput {
        let room = pending > 0 ? older : newer
        let steps = abs(pending) >= Self.distance / 2 && room > 0 ? (pending > 0 ? 1 : -1) : 0
        reset()
        return .atRest(steps: steps, ticks: pacedTick(wanted: steps != 0, at: time))
    }

    /// Forgets the gesture so far. The time of the last tick stays, because the minimum interval
    /// between ticks holds across gestures.
    private mutating func reset() {
        pending = 0
        hasTickedAtEnd = false
        shownProgress = 0
        shownRubberBand = 0
    }

    /// 1 when a tick is wanted and the last one is far enough back. A tick that comes too soon is
    /// dropped, not postponed: a late one would no longer coincide with the clip reaching the centre.
    private mutating func pacedTick(wanted: Bool, at time: TimeInterval) -> Int {
        guard wanted, lastTick.map({ time - $0 >= Self.minimumTickInterval }) ?? true else { return 0 }
        lastTick = time
        return 1
    }
}

/// Plays the tick as a clip passes the centre.
@MainActor
protocol HapticPerforming {
    func tick()
}

/// The system's alignment haptic, timed to the frame in which the clip settles. The system may
/// suppress it, for example when no finger is on the trackpad, so a call is only a request. The
/// performer is fetched on every call because the system can change it while the app runs.
@MainActor
struct SystemHaptics: HapticPerforming {
    func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }
}
