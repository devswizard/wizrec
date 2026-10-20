// Loudness normalisation per clip (AUD-2, docs/specs/audio.md §2.2 working rule [inf]):
//
//   when project `shouldApplyLoudnessNormalization` × source `loudnessNormalization` ×
//   clip `attributes.loudnessNormalization` are all on:
//   gain = 10^((targetLoudness − integratedLUFS) / 20), capped so that peakLevel · gain ≤ 1.0.
//
// Peak cap vs limiter on output is still [?] (needs a licensed export, audio.md §2.2); WizRec keeps
// the peak cap and no limiter until then.
//
// `integratedLUFS` / `peakLevel` come from `sourceTracks[trackNumber]`; when missing (or the
// 100.0 / −1.0 sentinels) WizRec measures the whole stream the way Camtasia does (audio.md §2.1,
// AU2): resampled to the mix rate (`audioFormatSampleRate`, 44100 when absent), BS.1770-4 with a
// mono source as dual mono (+3 LU), and `peakLevel` = linear sample peak after resampling.
// Silence (−Infinity LUFS) → gain 1. The whole policy lives in `normalisationGain`.

import CoreMedia
import Foundation
import MediaEngine

extension AudioMixer {
    /// The normalisation policy, in one place: target − LUFS in dB, peak-capped at 1.0 (0 dBFS).
    nonisolated static func normalisationGain(target: Double, lufs: Double?, peak: Double?) -> Double {
        guard let l = lufs, l.isFinite else { return 1 }
        var g = pow(10, (target - l) / 20)
        if let p = peak, p > 0, p.isFinite { g = min(g, 1 / p) }
        return g.isFinite && g > 0 ? g : 1
    }

    /// Normalisation gain of a leaf; 1 when the leaf is not normalised.
    func loudnessGain(_ n: ANode) async throws -> Double {
        if let g = loudnessGains[n.key] { return g }
        guard case .leaf(let url, let stream, _, let loud?) = n.body else { return 1 }
        var lufs = loud.sourceLUFS, peak = loud.sourcePeak
        if lufs == nil || peak == nil, let m = try await measure(url: url, stream: stream) {
            if lufs == nil { lufs = m.lufs }
            if peak == nil { peak = m.peak }
        }
        let g = Self.normalisationGain(target: loud.target, lufs: lufs, peak: peak)
        loudnessGains[n.key] = g
        return g
    }

    /// Integrated loudness and linear sample peak of a whole source stream, measured like the
    /// stored `integratedLUFS` / `peakLevel` (`SourceLoudness.measure`); nil when the file is
    /// missing or unsupported.
    func measure(url: URL, stream: Int) async throws -> (lufs: Double, peak: Double)? {
        let key = StreamKey(url: url, stream: stream)
        if let v = measured[key] { return v }
        guard let m = try await SourceLoudness.measure(pool: pool, url: url, stream: stream,
                                                       mixRate: scene.sampleRate ?? SourceLoudness.defaultMixRate)
        else { return nil }
        let v = (lufs: m.integratedLUFS, peak: m.peakLevel)
        measured[key] = v
        return v
    }
}

/// How Camtasia measures a source's `sourceTracks[i].integratedLUFS` and `peakLevel` (audio.md
/// §2.1, AU2): the stream resampled to the project's mix rate, BS.1770-4 integrated loudness with
/// a mono source counted as dual mono (+3 LU), and the linear sample peak after resampling.
public struct SourceLoudness: Sendable, Equatable {
    /// Integrated loudness, LUFS; `-.infinity` for silence.
    public var integratedLUFS: Double
    /// Linear sample peak (1.0 = 0 dBFS; may exceed 1 after resampling).
    public var peakLevel: Double

    public init(integratedLUFS: Double, peakLevel: Double) {
        self.integratedLUFS = integratedLUFS; self.peakLevel = peakLevel
    }

    /// Mix rate used when the project has no `audioFormatSampleRate`, Hz [obs: 44100 everywhere].
    public static let defaultMixRate = 44_100.0

    /// Measures stream `stream` of `url` at `mixRate` Hz. Nil when the file is missing,
    /// unsupported or has no such audio stream; other decode failures throw
    /// `AudioError.decodeFailed`.
    public static func measure(pool: MediaPool, url: URL, stream: Int,
                               mixRate: Double = defaultMixRate) async throws -> SourceLoudness? {
        do {
            let src = try await pool.source(for: url)
            guard let info = src.info.streams.first(where: { $0.index == stream && $0.kind == .audio }) else {
                throw MediaError.noSuchStream(stream)
            }
            let rate = mixRate.isFinite && mixRate >= 8_000 ? mixRate.rounded() : defaultMixRate
            let ch = max(1, info.channelCount)
            var meter = LoudnessMeter(sampleRate: rate, channels: ch, dualMono: ch == 1)
            var peak: Float = 0
            let total = info.duration.isNumeric ? Int64((info.duration.seconds * rate).rounded(.up)) : 0
            let chunk = Int64(rate * 10)
            let scale = CMTimeScale(clamping: Int64(rate))
            var t: Int64 = 0
            while t < total {
                let len = min(chunk, total - t)
                let pcm = try await src.audio(stream: stream,
                                              range: CMTimeRange(start: CMTime(value: t, timescale: scale),
                                                                 duration: CMTime(value: len, timescale: scale)),
                                              format: PCMFormat(sampleRate: rate, channels: ch))
                meter.feed(pcm.channels, count: pcm.frameCount)
                for c in pcm.channels { for x in c { peak = max(peak, abs(x)) } }
                t += len
            }
            return SourceLoudness(integratedLUFS: meter.integrated, peakLevel: Double(peak))
        } catch let e as MediaError {
            switch e {
            case .fileNotFound, .unsupported, .noSuchStream: return nil
            default: throw AudioError.decodeFailed("\(url.lastPathComponent): \(e)")
            }
        }
    }
}
