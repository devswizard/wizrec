import CoreMedia
import Foundation
import MediaEngine
import Observation
import QuartzCore
import RenderEngine

/// Transport state and the per-tick pipeline of the player:
/// clock → frame snap → `SceneModel.evaluate` → asynchronous frame fetches → draw state.
///
/// Drive it with `tick(host:…)` from a display link and draw `drawState()`.
/// Decoding never blocks the main actor: frames are requested asynchronously and
/// each layer draws the newest frame received for its stream.
@MainActor @Observable
public final class PlaybackEngine {
    public let scene: SceneModel
    public let grid: FrameGrid
    @ObservationIgnored public let pool: MediaPool

    public private(set) var isPlaying = false
    /// Frame index of the playhead (project frame rate).
    public private(set) var currentFrame: Int64 = 0
    /// Playhead time, ticks (start of `currentFrame`).
    public var currentTicks: Int64 { grid.ticks(ofFrame: currentFrame) }
    /// Refreshed about once per second.
    public private(set) var stats = PlaybackStats()
    /// Last frame-fetch error, for the UI.
    public private(set) var lastError: String?
    /// Seconds of frames requested ahead of the playhead during playback.
    @ObservationIgnored public var prefetchSeconds = 0.5
    /// Called with every new stats window (e.g. to log).
    @ObservationIgnored public var onStats: ((PlaybackStats) -> Void)?
    /// Called when playback reaches the end.
    @ObservationIgnored public var onEnded: (() -> Void)?

    private struct StreamKey: Hashable { var url: URL; var stream: Int }
    private struct Held { var request: FrameRequest; var frame: VideoFrame; var seq: Int }

    @ObservationIgnored private var clock: PlaybackClock
    @ObservationIgnored private let audio: AudioPlayback?
    @ObservationIgnored private var usingAudio = false
    @ObservationIgnored private var playToken = 0
    @ObservationIgnored private var plan: RenderPlan
    @ObservationIgnored private var held: [StreamKey: Held] = [:]
    /// Per-stream decode lane: requests fetched one at a time in order, plus decoded frames
    /// ahead of the playhead (sorted by presentation time).
    private struct Lane {
        var queue: [FrameRequest] = []
        var current: FrameRequest?
        var ready: [Held] = []
    }
    @ObservationIgnored private var lanes: [StreamKey: Lane] = [:]
    @ObservationIgnored private var failedURLs: Set<URL> = []
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var prefetchedThrough: Int64 = -1
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var acc: StatsAccumulator

    /// `audio`: the audio player and master clock; nil plays silently on the host clock.
    public init(scene: SceneModel, pool: MediaPool, audio: AudioPlayback?) {
        self.scene = scene
        self.pool = pool
        self.audio = audio
        grid = FrameGrid(timebase: scene.timebase, fps: scene.frameRate, duration: scene.duration)
        clock = PlaybackClock(editRate: scene.timebase.editRate)
        plan = scene.evaluate(at: 0)
        acc = StatsAccumulator(now: CACurrentMediaTime())
        request(plan.frameRequests)
    }

    // MARK: Transport

    public func togglePlay() { isPlaying ? pause() : play() }

    public func play() {
        guard !isPlaying, grid.duration > 0 else { return }
        if currentFrame >= grid.lastFrame { setFrame(0, playing: false) }
        isPlaying = true
        playToken += 1
        let token = playToken
        prefetchedThrough = currentFrame
        acc.resetDisplay()
        let start = currentTicks
        prefetchAhead()
        guard let audio else {
            usingAudio = false
            clock.start(at: start, host: CACurrentMediaTime())
            return
        }
        // The clock waits for the first audio chunks so picture and sound start together.
        Task { [weak self] in
            let ok = await audio.start(at: start)
            guard let self, token == self.playToken, self.isPlaying else {
                if ok { audio.stop() }
                return
            }
            self.usingAudio = ok
            self.clock.start(at: start, host: CACurrentMediaTime())
        }
    }

    public func pause() {
        guard isPlaying else { return }
        isPlaying = false
        playToken += 1
        clock.stop(host: CACurrentMediaTime())
        audio?.stop()
        usingAudio = false
        acc.resetDisplay()
    }

    /// Moves the playhead to frame `i` (clamped). Playback continues from there.
    public func seek(toFrame i: Int64) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        dropQueuedFetches()
        setFrame(i, playing: false)
        if wasPlaying { play() }
    }

    /// Moves the playhead to the frame containing `ticks`.
    public func seek(toTicks ticks: Int64) { seek(toFrame: grid.index(of: ticks)) }

    /// Steps `n` frames (negative = back). Pauses playback.
    public func step(by n: Int64) {
        pause()
        setFrame(currentFrame + n, playing: false)
    }

    public func goToStart() { seek(toFrame: 0) }
    public func goToEnd() { pause(); setFrame(grid.lastFrame, playing: false) }

    /// Releases audio and cached media (document closing).
    public func shutdown() {
        pause()
        audio?.shutdown()
        let pool = pool
        Task { await pool.purge() }
    }

    // MARK: Tick

    /// Advances the pipeline for a display refresh presented at `host` (host seconds,
    /// e.g. the display link's `targetTimestamp`). `timestamp`/`period` feed the
    /// dropped-refresh counter. Returns true when the canvas needs a redraw.
    @discardableResult
    public func tick(host: Double, timestamp: Double? = nil, period: Double = 0) -> Bool {
        acc.display(timestamp: timestamp ?? host, period: period, counting: isPlaying)
        if isPlaying, clock.isRunning {
            if usingAudio, let a = audio?.timelineTicks(atHost: host) {
                clock.resync(toTicks: a, atHost: host, tolerance: 0.015)
            }
            let t = clock.ticks(atHost: host)
            if t >= grid.duration {
                setFrame(grid.lastFrame, playing: true)
                pause()
                onEnded?()
            } else {
                setFrame(grid.index(of: t), playing: true)
                prefetchAhead()
            }
        }
        if let s = acc.flush(now: CACurrentMediaTime(), clock: usingAudio ? "audio" : "host") {
            stats = s
            onStats?(s)
        }
        defer { dirty = false }
        return dirty
    }

    /// Forces a redraw on the next tick (e.g. after a resize).
    public func setNeedsDraw() { dirty = true }

    /// What to draw now: the current plan, the newest frame available for each of
    /// its video layers, and how many layers show an older frame than requested.
    public func drawState() -> (plan: RenderPlan, frames: [FrameRequest: VideoFrame], frame: Int64, stale: Int) {
        var frames: [FrameRequest: VideoFrame] = [:]
        var stale = 0
        for r in plan.frameRequests {
            if let h = held[key(r)] {
                frames[r] = h.frame
                if !Self.covers(h.frame, r.time) { stale += 1 }
            } else if !failedURLs.contains(r.url) {
                stale += 1
            }
        }
        return (plan, frames, currentFrame, stale)
    }

    /// True when every video layer of the current plan shows its exact frame
    /// (or its media failed) and no fetch is outstanding.
    public var isSettled: Bool {
        lanes.values.allSatisfy { $0.current == nil && $0.queue.isEmpty } && drawState().stale == 0
    }

    /// Waits (without blocking the main actor) until `isSettled`, up to `timeout` seconds.
    @discardableResult
    public func waitUntilSettled(timeout: Double = 5) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !isSettled {
            if CACurrentMediaTime() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// Records a finished draw (from the canvas).
    public func recordDraw(frame: Int64, cpuMs: Double, stale: Bool) {
        acc.draw(frame: frame, cpuMs: cpuMs, stale: stale && isPlaying)
    }

    /// Records GPU time of a finished command buffer.
    public func recordGPU(ms: Double) { acc.gpu(ms: ms) }

    // MARK: Internals

    private func setFrame(_ i: Int64, playing: Bool) {
        let i = grid.clamp(frame: i)
        guard i != currentFrame else { return }
        if playing, i > currentFrame + 1 { acc.skipped(Int(i - currentFrame - 1)) }
        currentFrame = i
        plan = scene.evaluate(at: grid.ticks(ofFrame: i))
        dirty = true
        request(plan.frameRequests)
    }

    /// Forgets queued (not yet started) fetches and decoded look-ahead after a jump.
    private func dropQueuedFetches() {
        for k in lanes.keys {
            lanes[k]?.queue.removeAll()
            lanes[k]?.ready.removeAll()
        }
    }

    private func key(_ r: FrameRequest) -> StreamKey { StreamKey(url: r.url, stream: r.stream) }

    /// True when `frame` is the one on screen at stream time `t`.
    nonisolated static func covers(_ frame: VideoFrame, _ t: CMTime) -> Bool {
        guard frame.presentationTime <= t || t < .zero else { return false }
        guard frame.duration.isValid, frame.duration.isNumeric else { return true }
        return t < frame.presentationTime + frame.duration
    }

    /// Brings the current plan's frames on screen: takes exact frames from the lanes'
    /// ready lists, otherwise puts the request at the head of its lane.
    private func request(_ requests: [FrameRequest]) {
        for r in requests {
            let k = key(r)
            if failedURLs.contains(r.url) { continue }
            if let h = held[k], h.request == r || Self.covers(h.frame, r.time) { continue }
            var lane = lanes[k] ?? Lane()
            if isPlaying {
                // Forward playback: frames before the playhead are no longer needed.
                lane.ready.removeAll { Self.ends(before: r.time, $0.frame) }
                lane.queue.removeAll { $0.time < r.time }
            } else {
                // Seek/step while paused: only this frame matters (the pool cache keeps the rest).
                lane.queue.removeAll()
                lane.ready.removeAll { !Self.covers($0.frame, r.time) }
            }
            if let h = lane.ready.first(where: { Self.covers($0.frame, r.time) }) {
                held[k] = Held(request: r, frame: h.frame, seq: h.seq)
                dirty = true
            } else if lane.current != r, lane.queue.first != r {
                lane.queue.removeAll { $0 == r }
                lane.queue.insert(r, at: 0)
            }
            lanes[k] = lane
            runLane(k)
        }
    }

    /// True when `frame` stops being on screen at or before `t`.
    nonisolated static func ends(before t: CMTime, _ frame: VideoFrame) -> Bool {
        guard frame.duration.isValid, frame.duration.isNumeric else { return false }
        return frame.presentationTime + frame.duration <= t
    }

    /// Starts the lane's next fetch unless one is running. One fetch per stream at a
    /// time, in queue order, so the decoder only ever moves forward during playback.
    private func runLane(_ k: StreamKey) {
        guard var lane = lanes[k], lane.current == nil else { return }
        while let next = lane.queue.first, lane.ready.contains(where: { Self.covers($0.frame, next.time) }) {
            lane.queue.removeFirst()
        }
        guard !lane.queue.isEmpty else { lanes[k] = lane; return }
        let r = lane.queue.removeFirst()
        lane.current = r
        lanes[k] = lane
        seq += 1
        let s = seq
        let pool = pool
        let t0 = CACurrentMediaTime()
        Task { [weak self] in
            let result: Result<VideoFrame, any Error>
            do { result = .success(try await pool.frame(r)) } catch { result = .failure(error) }
            self?.laneFinished(k, r, result, seq: s, ms: (CACurrentMediaTime() - t0) * 1000)
        }
    }

    private func laneFinished(_ k: StreamKey, _ r: FrameRequest, _ result: Result<VideoFrame, any Error>,
                              seq s: Int, ms: Double) {
        var lane = lanes[k] ?? Lane()
        lane.current = nil
        acc.fetch(ms: ms)
        switch result {
        case .success(let f):
            if !lane.ready.contains(where: { $0.frame.presentationTime == f.presentationTime }) {
                let h = Held(request: r, frame: f, seq: s)
                let i = lane.ready.firstIndex { $0.frame.presentationTime > f.presentationTime } ?? lane.ready.count
                lane.ready.insert(h, at: i)
                if lane.ready.count > Self.maxReady { lane.ready.removeFirst(lane.ready.count - Self.maxReady) }
            }
            // Present it if the current plan wants it.
            for want in plan.frameRequests where key(want) == k && Self.covers(f, want.time) {
                if (held[k]?.seq ?? -1) < s || !(held[k].map { Self.covers($0.frame, want.time) } ?? false) {
                    held[k] = Held(request: want, frame: f, seq: s)
                    dirty = true
                }
            }
        case .failure(let e):
            failedURLs.insert(r.url)
            lane.queue.removeAll()
            lastError = "\(r.url.lastPathComponent): \(e)"
        }
        lanes[k] = lane
        runLane(k)
    }

    /// Decoded frames kept per stream ahead of the playhead.
    static let maxReady = 48

    /// Queues the frames of the next `prefetchSeconds` into their lanes, in time order.
    private func prefetchAhead() {
        let ahead = max(1, Int64((prefetchSeconds / grid.frameSeconds).rounded(.up)))
        let horizon = min(grid.lastFrame, currentFrame + ahead)
        let from = max(prefetchedThrough, currentFrame) + 1
        guard from <= horizon else { return }
        var touched: Set<StreamKey> = []
        for f in from...horizon {
            for r in scene.evaluate(at: grid.ticks(ofFrame: f)).frameRequests where !failedURLs.contains(r.url) {
                let k = key(r)
                var lane = lanes[k] ?? Lane()
                if lane.ready.contains(where: { Self.covers($0.frame, r.time) }) { continue }
                if let last = lane.queue.last, last.time >= r.time { continue }
                lane.queue.append(r)
                lanes[k] = lane
                touched.insert(k)
            }
        }
        prefetchedThrough = horizon
        for k in touched { runLane(k) }
    }
}
