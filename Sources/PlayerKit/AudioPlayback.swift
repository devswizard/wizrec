import AudioEngine
import AVFoundation
import Foundation
import MediaEngine
import RenderEngine

/// Plays the project's audio through `AVAudioEngine` and serves as the master
/// clock while it runs.
///
/// The timeline is mixed in fixed chunks (`chunkSeconds`) by AudioEngine's `AudioMixer`
/// (gain, volume keyframes, fades, effects, loudness) and fed to one `AVAudioPlayerNode`
/// about `lookaheadSeconds` ahead of what is audible.
@MainActor
public final class AudioPlayback {
    /// Scene whose timebase maps output samples to ticks; swap with `replaceScene(_:audioScene:)`.
    public private(set) var scene: SceneModel
    /// Mixer for the current `AudioScene`.
    public private(set) var mixer: AudioMixer
    public let pool: MediaPool
    /// Output sample rate, Hz (the project's `audioFormatSampleRate`).
    public let sampleRate: Double
    public let channels = 2
    public let chunkFrames: Int
    public let lookaheadSeconds: Double

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var generation = 0
    private var originTicks: Int64 = 0
    private var scheduledFrames: Int64 = 0
    private var pumpTask: Task<Void, Never>?
    public private(set) var isPlaying = false
    /// Chunks the mixer failed to render (decode errors); those play as silence.
    public private(set) var failedReads = 0
    /// Times the player ran out of scheduled audio (audible gap; cumulative).
    public private(set) var underruns = 0
    private var dry = false

    /// Nil when no audio output is available.
    /// `audioScene`: the project's audio, mixed by `AudioMixer`.
    public init?(scene: SceneModel, audioScene: AudioScene, pool: MediaPool, sampleRate: Double,
                 chunkSeconds: Double = 0.25, lookaheadSeconds: Double = 1.0) {
        let rate = sampleRate > 0 ? sampleRate : 44100
        guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return nil }
        self.scene = scene; self.pool = pool; self.sampleRate = rate; self.format = f
        self.mixer = AudioMixer(scene: audioScene, pool: pool, format: MixFormat(sampleRate: rate, channels: 2))
        self.chunkFrames = max(256, Int(rate * chunkSeconds))
        self.lookaheadSeconds = lookaheadSeconds
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: f)
        engine.prepare()
    }

    /// Starts playing the timeline from `ticks`. Returns once the first chunks are
    /// scheduled and the player is running; false if audio could not start.
    public func start(at ticks: Int64) async -> Bool {
        stop()
        let gen = generation
        // On the mixer's sample grid (sample k at tick k · editRate / rate), so chunks abut exactly.
        originTicks = AudioMix.alignedTicks(ticks, sampleRate: sampleRate, editRate: scene.timebase.editRate)
        scheduledFrames = 0
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return false
        }
        for _ in 0..<2 { await scheduleNext(gen) }
        guard gen == generation else { return false }
        player.play()
        isPlaying = true
        pumpTask = Task { [weak self] in await self?.pump(gen) }
        return true
    }

    /// Uses `newScene` and a fresh mixer for `audioScene` for chunks mixed from now on.
    /// Callers restart playback (`stop` + `start`) so already scheduled audio does not
    /// play the old mix.
    public func replaceScene(_ newScene: SceneModel, audioScene: AudioScene) {
        scene = newScene
        mixer = AudioMixer(scene: audioScene, pool: pool, format: MixFormat(sampleRate: sampleRate, channels: channels))
    }

    /// Stops playback and drops scheduled audio.
    public func stop() {
        generation += 1
        pumpTask?.cancel()
        pumpTask = nil
        if isPlaying || player.isPlaying { player.stop() }
        isPlaying = false
    }

    /// Shuts the engine down (document closing).
    public func shutdown() {
        stop()
        engine.stop()
    }

    /// Timeline time audible at host time `host` (seconds), or nil before the
    /// first sample has been rendered.
    public func timelineTicks(atHost host: Double) -> Int64? {
        guard isPlaying, let nodeTime = player.lastRenderTime, nodeTime.isHostTimeValid,
              let pt = player.playerTime(forNodeTime: nodeTime), pt.isSampleTimeValid else { return nil }
        let pos = PlaybackClock.audioPosition(
            sampleTime: pt.sampleTime, sampleRate: pt.sampleRate,
            renderHost: AVAudioTime.seconds(forHostTime: nodeTime.hostTime),
            atHost: host, latency: engine.outputNode.presentationLatency)
        guard pos >= 0 else { return nil }
        return originTicks + Int64((pos * Double(scene.timebase.editRate)).rounded())
    }

    private var playedFrames: Int64 {
        guard let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, pt.sampleTime)
    }

    private func pump(_ gen: Int) async {
        while !Task.isCancelled, gen == generation {
            let played = playedFrames
            if played >= scheduledFrames, !dry { underruns += 1 }
            dry = played >= scheduledFrames
            if Double(scheduledFrames - played) / sampleRate < lookaheadSeconds {
                await scheduleNext(gen)
            } else {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func scheduleNext(_ gen: Int) async {
        let chunk = AudioChunk(originTicks: originTicks, startSample: scheduledFrames, frameCount: chunkFrames)
        let samples = await render(chunk)
        guard gen == generation,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frameCount)),
              let data = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(chunk.frameCount)
        for c in 0..<channels {
            samples[c].withUnsafeBufferPointer { src in
                data[c].update(from: src.baseAddress!, count: min(src.count, chunk.frameCount))
            }
        }
        enqueue(buf)
        scheduledFrames += Int64(chunk.frameCount)
    }

    /// Synchronous on purpose: the buffer is queued; completion is tracked via `playedFrames`.
    private func enqueue(_ buf: AVAudioPCMBuffer) {
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Mixed PCM for `chunk`: `channels` arrays of `chunk.frameCount` samples.
    func render(_ chunk: AudioChunk) async -> [[Float]] {
        let editRate = scene.timebase.editRate
        let span = AudioMix.tickRange(of: chunk, sampleRate: sampleRate, editRate: editRate)
        do {
            let pcm = try await mixer.render(span)
            return AudioMix.fit(pcm, frameCount: chunk.frameCount, channels: channels)
        } catch {
            failedReads += 1
            return [[Float]](repeating: [Float](repeating: 0, count: chunk.frameCount), count: channels)
        }
    }
}
