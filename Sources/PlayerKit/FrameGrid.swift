import TSCProjKit

/// The project's frame grid: maps timeline ticks to frame indices at the
/// project frame rate and back. All times are ticks (`timebase.editRate`/s).
public struct FrameGrid: Sendable, Equatable {
    public let timebase: Timebase
    /// Project frames per second (`videoFormatFrameRate`).
    public let fps: Rational
    /// Timeline length, ticks.
    public let duration: Int64

    public init(timebase: Timebase, fps: Rational, duration: Int64) {
        self.timebase = timebase
        // Untrusted project data: never divide by a zero or negative rate.
        self.fps = fps.num > 0 && fps.den > 0 ? fps : Rational(30)
        self.duration = max(0, duration)
    }

    /// Frame on screen at `ticks` (floor). Negative times map to frame 0.
    public func index(of ticks: Int64) -> Int64 {
        guard ticks > 0 else { return 0 }
        return (ticks * fps.num) / (timebase.editRate * fps.den)
    }

    /// First tick of frame `i` (ceiling, so `index(of: ticks(ofFrame: i)) == i`
    /// even when frame boundaries fall between ticks).
    public func ticks(ofFrame i: Int64) -> Int64 {
        guard i > 0 else { return 0 }
        let n = i * timebase.editRate * fps.den
        return (n + fps.num - 1) / fps.num
    }

    /// Last frame that starts before the end of the timeline.
    public var lastFrame: Int64 { index(of: max(0, duration - 1)) }

    /// Number of frames in the timeline.
    public var frameCount: Int64 { lastFrame + 1 }

    /// `i` limited to the timeline's frames.
    public func clamp(frame i: Int64) -> Int64 { min(max(0, i), lastFrame) }

    /// Start of the frame containing `ticks`, clamped to the timeline.
    public func snap(_ ticks: Int64) -> Int64 { self.ticks(ofFrame: clamp(frame: index(of: ticks))) }

    /// Frame duration in seconds.
    public var frameSeconds: Double { Double(fps.den) / Double(fps.num) }
}
