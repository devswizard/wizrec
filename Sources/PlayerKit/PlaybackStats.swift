/// Playback performance figures, refreshed about once per second.
public struct PlaybackStats: Sendable, Equatable {
    /// Canvas draws per second.
    public var drawFPS = 0.0
    /// Distinct project frames presented per second.
    public var contentFPS = 0.0
    /// Mean CPU time per draw (evaluate lookups + encode), milliseconds.
    public var cpuMs = 0.0
    /// Mean GPU time per draw, milliseconds.
    public var gpuMs = 0.0
    /// Display refreshes missed by the display link since playback began (cumulative).
    public var droppedDisplayFrames = 0
    /// Project frames that were never presented during playback (cumulative).
    public var skippedFrames = 0
    /// Draws that showed an older frame for at least one layer because the
    /// exact one was still decoding (cumulative).
    public var staleDraws = 0
    /// Frame fetches in the last window.
    public var fetches = 0
    /// Share of fetches answered in under 2 ms (≈ frame-cache hits), 0–1.
    public var fastFetchRatio = 0.0
    /// Mean fetch latency in the last window, milliseconds.
    public var fetchMs = 0.0
    /// Times the host clock was re-anchored to the audio clock (> 15 ms apart; cumulative).
    public var resyncs = 0
    /// Audio underruns since the document opened (cumulative).
    public var audioUnderruns = 0
    /// `"audio"` when the audio clock drives playback, else `"host"`.
    public var clock = "host"

    public init() {}

    /// One-line summary for logs.
    public var line: String {
        func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }
        return "draw=\(f(drawFPS))fps content=\(f(contentFPS))fps cpu=\(f(cpuMs, 2))ms gpu=\(f(gpuMs, 2))ms "
            + "dropped=\(droppedDisplayFrames) skipped=\(skippedFrames) stale=\(staleDraws) "
            + "fetch=\(fetches) fast=\(f(fastFetchRatio * 100, 0))% fetchAvg=\(f(fetchMs, 2))ms resyncs=\(resyncs) underruns=\(audioUnderruns) clock=\(clock)"
    }
}

/// Accumulates raw events into `PlaybackStats` windows. Pure value type.
public struct StatsAccumulator: Sendable {
    public private(set) var cumulative = PlaybackStats()
    private var windowStart: Double
    private var draws = 0, contentFrames = 0, cpuSum = 0.0, gpuSum = 0.0, gpuCount = 0
    private var fetches = 0, fastFetches = 0, fetchSum = 0.0
    private var lastDisplay: Double?
    private var lastDrawnFrame: Int64?

    public init(now: Double) { windowStart = now }

    public mutating func draw(frame: Int64, cpuMs: Double, stale: Bool) {
        draws += 1; cpuSum += cpuMs
        if frame != lastDrawnFrame { contentFrames += 1; lastDrawnFrame = frame }
        if stale { cumulative.staleDraws += 1 }
    }

    public mutating func gpu(ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        gpuSum += ms; gpuCount += 1
    }

    public mutating func fetch(ms: Double) {
        fetches += 1; fetchSum += ms
        if ms < 2 { fastFetches += 1 }
    }

    public mutating func skipped(_ n: Int) { cumulative.skippedFrames += n }

    public mutating func resynced() { cumulative.resyncs += 1 }

    /// A display-link callback at `timestamp` for a refresh of `period` seconds.
    /// Counts refreshes missed since the previous callback while `counting`.
    public mutating func display(timestamp: Double, period: Double, counting: Bool) {
        defer { lastDisplay = timestamp }
        guard counting, let last = lastDisplay, period > 0 else { return }
        let missed = Int(((timestamp - last) / period).rounded()) - 1
        if missed > 0 { cumulative.droppedDisplayFrames += missed }
    }

    /// Ends playback counting for the display gap (pauses would look like drops).
    public mutating func resetDisplay() { lastDisplay = nil }

    /// Closes the window when at least `interval` seconds have passed; returns the stats.
    public mutating func flush(now: Double, clock: String, interval: Double = 1) -> PlaybackStats? {
        let dt = now - windowStart
        guard dt >= interval else { return nil }
        var s = cumulative
        s.drawFPS = Double(draws) / dt
        s.contentFPS = Double(contentFrames) / dt
        s.cpuMs = draws > 0 ? cpuSum / Double(draws) : 0
        s.gpuMs = gpuCount > 0 ? gpuSum / Double(gpuCount) : 0
        s.fetches = fetches
        s.fastFetchRatio = fetches > 0 ? Double(fastFetches) / Double(fetches) : 1
        s.fetchMs = fetches > 0 ? fetchSum / Double(fetches) : 0
        s.clock = clock
        windowStart = now
        draws = 0; contentFrames = 0; cpuSum = 0; gpuSum = 0; gpuCount = 0
        fetches = 0; fastFetches = 0; fetchSum = 0
        return s
    }
}
