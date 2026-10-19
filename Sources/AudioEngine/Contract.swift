// Public interface of AudioEngine (agent "audio", M8), frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import CoreMedia
import Foundation
import MediaEngine
import TSCProjKit

/// Output layout of a mix: Float32 non-interleaved.
public struct MixFormat: Sendable, Equatable {
    /// Samples per second.
    public var sampleRate: Double
    public var channels: Int
    public init(sampleRate: Double = 48_000, channels: Int = 2) { self.sampleRate = sampleRate; self.channels = channels }
}

/// Immutable, Sendable projection of a project's audio: every audible clip with its
/// time mapping, `gain`, `volume` keyframes, fades/transitions, mute/solo and audio effects.
/// Build on the main actor; render anywhere.
public struct AudioScene: Sendable {
    public let timebase: Timebase
    /// Timeline length, ticks.
    public let duration: Int64

    /// Top-level tracks, `trackIndex` ascending.
    let tracks: [ATrack]
    /// `timeline.gain` (linear master gain, default 1) [obs key, inf meaning].
    let masterGain: Double

    /// `resolve` maps a source-bin entry to its file (usually `ProjectBundle.resolve`).
    public init(project: Project, resolve: (SourceMedia) -> URL) {
        timebase = project.timebase
        duration = project.duration
        var b = AudioSceneBuilder(project: project, resolve: resolve)
        tracks = b.tracks(project.tracks, attributes: project.timeline?.trackAttributes ?? [])
        masterGain = project.timeline?.object["gain"]?.double ?? 1
    }
}

public enum AudioError: Error, Sendable, Equatable {
    case notImplemented
    case decodeFailed(String)
}

/// Renders the mixed project audio. Deterministic: same range → same samples.
public actor AudioMixer {
    public let scene: AudioScene
    public let pool: MediaPool
    public let format: MixFormat

    // Render state (Mixer.swift). Caches only ever hold pure functions of the scene.
    let grid: SampleGrid
    let blockSize = 16_384
    let stretcher: Stretcher
    var blocks = BlockCache(limitBytes: 128 << 20)
    var chains: [ChainKey: [Int]] = [:]
    var loudnessGains: [Int: Double] = [:]
    var measured: [StreamKey: (lufs: Double, peak: Double)] = [:]
    var processorCache: [Int: [any AudioProcessor]] = [:]
    var sourceChannels: [StreamKey: Int] = [:]
    /// Source reads that failed because the file is missing or unsupported (played as silence).
    var missingReads = 0

    public init(scene: AudioScene, pool: MediaPool, format: MixFormat = MixFormat()) {
        self.scene = scene; self.pool = pool; self.format = format
        let rate = max(1, Int64(format.sampleRate.rounded()))
        grid = SampleGrid(editRate: max(1, scene.timebase.editRate), rate: rate)
        stretcher = Stretcher(sampleRate: Double(rate))
    }

    /// Mixed PCM for timeline `range` (ticks), effects and loudness normalisation applied.
    ///
    /// Output sample k sits at tick k · editRate / sampleRate; the buffer holds the samples whose
    /// tick lies in `range` (so consecutive ranges join sample-exactly) and `startTime` is the first
    /// one's time (timescale = sample rate). Missing or unsupported media plays as silence; other
    /// decode failures throw `AudioError.decodeFailed`.
    public func render(_ range: Range<Int64>) async throws -> PCMBuffer {
        try await renderMix(range)
    }
}

/// ITU-R BS.1770-4 / EBU R128 loudness measurement.
public enum Loudness {
    /// Integrated loudness in LUFS of `buffer` (gated). `-.infinity` for silence.
    /// Channel weights follow BS.1770-4 (mono weight 1, as `ffmpeg -af ebur128`).
    public static func integratedLUFS(_ buffer: PCMBuffer) -> Double {
        var m = LoudnessMeter(sampleRate: buffer.format.sampleRate, channels: buffer.channels.count)
        m.feed(buffer.channels, count: buffer.frameCount)
        return m.integrated
    }
    /// True peak in dBTP.
    public static func truePeak(_ buffer: PCMBuffer) -> Double {
        var m = TruePeakMeter(sampleRate: buffer.format.sampleRate, channels: buffer.channels.count)
        m.feed(buffer.channels, count: buffer.frameCount)
        return m.dBTP
    }
}
