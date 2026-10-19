import CoreMedia
import os

/// Current time of the host clock (`CMClockGetHostTimeClock`), the one clock every capture
/// source of a recording is converted to.
func hostNow() -> CMTime {
    CMClockGetTime(CMClockGetHostTimeClock())
}

/// Pure timeline arithmetic of one recording: maps host-clock times to recording time.
///
/// Recording time 0 is `start`; every pause interval `[pausedAt, resumedAt)` is cut out, so
/// samples after a resume continue exactly where the pre-pause samples ended (no gap).
/// Samples before the start, inside a pause or at/after the stop map to `nil` (dropped).
/// All times are `CMTime` on the host clock (input) or recording time (output).
struct TimelineStitcher: Sendable, Equatable {
    /// One pause; `resumedAt` is nil while the pause is open.
    struct Pause: Sendable, Equatable {
        var pausedAt: CMTime
        var resumedAt: CMTime?
    }

    private(set) var startTime: CMTime?
    private(set) var pauses: [Pause] = []
    private(set) var stopTime: CMTime?

    init() {}

    var isStarted: Bool { startTime != nil }
    var isPaused: Bool { pauses.last.map { $0.resumedAt == nil } ?? false }
    var isStopped: Bool { stopTime != nil }

    /// Starts the timeline at host time `t`. Ignored when already started.
    mutating func start(at t: CMTime) {
        guard startTime == nil else { return }
        startTime = t
    }

    /// Opens a pause at host time `t`. Ignored unless recording and not paused.
    mutating func pause(at t: CMTime) {
        guard let s = startTime, stopTime == nil, !isPaused else { return }
        pauses.append(Pause(pausedAt: CMTimeMaximum(t, max(s, lastResume ?? s)), resumedAt: nil))
    }

    /// Closes the open pause at host time `t`. Returns the recording time at which recording
    /// continues (the pause point), or nil when not paused.
    @discardableResult
    mutating func resume(at t: CMTime) -> CMTime? {
        guard isPaused, stopTime == nil, let i = pauses.indices.last else { return nil }
        pauses[i].resumedAt = CMTimeMaximum(t, pauses[i].pausedAt)
        return recordingTime(at: pauses[i].pausedAt)
    }

    /// Stops at host time `t` (an open pause ends the recording at its pause point) and returns
    /// the recording duration.
    @discardableResult
    mutating func stop(at t: CMTime) -> CMTime {
        guard let s = startTime else { return .zero }
        if stopTime == nil {
            if isPaused, let i = pauses.indices.last {
                stopTime = pauses[i].pausedAt
                pauses[i].resumedAt = pauses[i].pausedAt
            } else {
                stopTime = CMTimeMaximum(t, max(s, lastResume ?? s))
            }
        }
        return recordingTime(at: stopTime ?? s)
    }

    private var lastResume: CMTime? { pauses.last?.resumedAt }

    private func max(_ a: CMTime, _ b: CMTime) -> CMTime { CMTimeMaximum(a, b) }

    /// Recording time of host time `t`, or nil when `t` is dropped (before start, paused, stopped).
    func map(_ t: CMTime) -> CMTime? {
        guard let s = startTime, t.isNumeric, t >= s else { return nil }
        if let e = stopTime, t >= e { return nil }
        var paused = CMTime.zero
        for p in pauses {
            guard t >= p.pausedAt else { break }
            guard let r = p.resumedAt, t >= r else { return nil }
            paused = paused + (r - p.pausedAt)
        }
        return t - s - paused
    }

    /// Recording time of a sample covering host interval `[t, t + duration)`, or nil unless the
    /// whole interval lies in one recorded segment. Used for audio buffers, so a buffer that
    /// straddles a pause or the stop is dropped instead of overlapping the next segment.
    func map(_ t: CMTime, duration: CMTime) -> CMTime? {
        guard let out = map(t) else { return nil }
        guard duration.isNumeric, duration > .zero else { return out }
        let end = t + duration
        if let e = stopTime, end > e { return nil }
        for p in pauses where p.pausedAt > t && p.pausedAt < end { return nil }
        return out
    }

    /// Recording time "now" for a timer display: frozen at the pause point while paused, and
    /// at the duration once stopped. Zero before the start.
    func recordingTime(at t: CMTime) -> CMTime {
        guard let s = startTime, t.isNumeric else { return .zero }
        var clamped = CMTimeMaximum(t, s)
        if let e = stopTime { clamped = CMTimeMinimum(clamped, e) }
        var paused = CMTime.zero
        for p in pauses {
            guard clamped >= p.pausedAt else { break }
            guard let r = p.resumedAt else { return p.pausedAt - s - paused }
            if clamped < r { return p.pausedAt - s - paused }
            paused = paused + (r - p.pausedAt)
        }
        return clamped - s - paused
    }
}

/// Thread-safe shared clock of one recording: wraps a `TimelineStitcher` so capture queues,
/// the cursor logger and the main actor all map host times the same way.
final class RecordingClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TimelineStitcher())

    init() {}

    /// Snapshot of the timeline.
    var stitcher: TimelineStitcher { state.withLock { $0 } }

    func start(at t: CMTime) { state.withLock { $0.start(at: t) } }
    func pause(at t: CMTime) { state.withLock { $0.pause(at: t) } }
    @discardableResult func resume(at t: CMTime) -> CMTime? { state.withLock { $0.resume(at: t) } }
    @discardableResult func stop(at t: CMTime) -> CMTime { state.withLock { $0.stop(at: t) } }

    /// See `TimelineStitcher.map(_:)`.
    func map(_ t: CMTime) -> CMTime? { state.withLock { $0.map(t) } }
    /// See `TimelineStitcher.map(_:duration:)`.
    func map(_ t: CMTime, duration: CMTime) -> CMTime? { state.withLock { $0.map(t, duration: duration) } }
    /// See `TimelineStitcher.recordingTime(at:)`.
    func recordingTime(at t: CMTime) -> CMTime { state.withLock { $0.recordingTime(at: t) } }
}
