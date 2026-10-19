/// Playback clock: timeline ticks as a function of host time (seconds on the
/// `CACurrentMediaTime` / mach host clock). Pure value type.
///
/// While running, `ticks(atHost:)` = `anchorTicks + (host − anchorHost) × editRate × rate`.
/// The audio path slaves this clock with `resync(toTicks:atHost:tolerance:)`.
public struct PlaybackClock: Sendable, Equatable {
    /// Ticks per second.
    public let editRate: Int64
    /// Playback speed (1 = real time).
    public var rate: Double
    public private(set) var isRunning = false
    private var anchorTicks: Int64
    private var anchorHost: Double = 0

    public init(editRate: Int64, at ticks: Int64 = 0, rate: Double = 1) {
        self.editRate = max(1, editRate)
        self.rate = rate
        self.anchorTicks = ticks
    }

    /// Timeline time at `host` seconds. Frozen at the anchor while stopped.
    public func ticks(atHost host: Double) -> Int64 {
        guard isRunning else { return anchorTicks }
        return anchorTicks + Int64(((host - anchorHost) * Double(editRate) * rate).rounded())
    }

    /// Starts running so that the clock reads `ticks` at `host`.
    public mutating func start(at ticks: Int64, host: Double) {
        anchorTicks = ticks; anchorHost = host; isRunning = true
    }

    /// Stops, holding the time reached at `host`.
    public mutating func stop(host: Double) {
        anchorTicks = ticks(atHost: host); isRunning = false
    }

    /// Jumps to `ticks`; keeps running if it was running.
    public mutating func seek(to ticks: Int64, host: Double) {
        anchorTicks = ticks; anchorHost = host
    }

    /// Re-anchors to an external (audio) time when the two disagree by more
    /// than `tolerance` seconds. Returns true when it re-anchored.
    @discardableResult
    public mutating func resync(toTicks external: Int64, atHost host: Double, tolerance: Double) -> Bool {
        guard isRunning else { return false }
        let drift = Double(external - ticks(atHost: host)) / Double(editRate)
        guard abs(drift) > tolerance else { return false }
        anchorTicks = external; anchorHost = host
        return true
    }

    /// Audio position, in seconds since the player started, at host time `host`.
    ///
    /// `sampleTime` is the player's sample position at the render timestamp
    /// `renderHost` (host seconds); time advances in real time from there.
    /// `latency` (s) is subtracted so the result is what is audible at `host`.
    public static func audioPosition(sampleTime: Int64, sampleRate: Double, renderHost: Double,
                                     atHost host: Double, latency: Double = 0) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleTime) / sampleRate + (host - renderHost) - latency
    }
}
