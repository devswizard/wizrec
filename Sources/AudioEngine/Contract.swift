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

    /// `resolve` maps a source-bin entry to its file (usually `ProjectBundle.resolve`).
    public init(project: Project, resolve: (SourceMedia) -> URL) {
        timebase = project.timebase
        duration = project.duration
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

    public init(scene: AudioScene, pool: MediaPool, format: MixFormat = MixFormat()) {
        self.scene = scene; self.pool = pool; self.format = format
    }

    /// Mixed PCM for timeline `range` (ticks), effects and loudness normalisation applied.
    public func render(_ range: Range<Int64>) async throws -> PCMBuffer {
        throw AudioError.notImplemented
    }
}

/// ITU-R BS.1770-4 / EBU R128 loudness measurement.
public enum Loudness {
    /// Integrated loudness in LUFS of `buffer` (gated). `-.infinity` for silence.
    public static func integratedLUFS(_ buffer: PCMBuffer) -> Double { -.infinity }
    /// True peak in dBTP.
    public static func truePeak(_ buffer: PCMBuffer) -> Double { -.infinity }
}
