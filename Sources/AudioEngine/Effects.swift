// Audio effects by `effectName` (AUD-3). Names come from one table; unknown effects pass through.
//
// Only `VSTEffect-DFN3NoiseRemoval` (parameter `Amount`, 0–1) is observed in projects
// (docs/specs/audio.md §3). The other names are [?] until experiment AU1, so the table matches
// them loosely by keyword; fix the spellings here once AU1 is in. WizRec never uses TechSmith's
// plug-ins: every effect below is WizRec's own DSP, and the effect's opaque `metadata` is
// preserved untouched by TSCProjKit (AudioEngine never writes projects).

import Foundation

/// What an `effectName` does in WizRec's mixer.
enum AudioEffectKind: Equatable, Sendable {
    /// Spectral noise reduction (`Amount` 0–1).
    case noiseRemoval
    /// Slow automatic gain toward a target level (dynamics processor / volume leveling).
    case leveling
    /// Ducks the other tracks at the same level while the clip sounds (track-level, Mixer.swift).
    case emphasize
    /// Pitch shift in semitones, duration unchanged.
    case pitch
    /// Unknown or not an audio effect: passes the signal through.
    case passThrough

    /// The kind for an `effectName` [obs for VSTEffect-DFN3NoiseRemoval; inf for the rest].
    init(effectName name: String) {
        let n = name.lowercased()
        if n.contains("noiseremoval") || n.contains("noisereduction") || n.contains("denoise") {
            self = .noiseRemoval
        } else if n.contains("leveling") || n.contains("leveler") || n.contains("dynamics") || n.contains("compress") {
            self = .leveling
        } else if n.contains("emphasi") {
            self = .emphasize
        } else if n.contains("pitch") {
            self = .pitch
        } else {
            self = .passThrough
        }
    }
}

extension AEffect {
    var kind: AudioEffectKind { AudioEffectKind(effectName: name) }

    /// The first present parameter among `keys` (constant or start value), else `d`.
    func value(_ keys: [String], default d: Double) -> Double {
        for k in keys { if let v = parameters[k]?.constant, v.isFinite { return v } }
        return d
    }

    /// Strength 0–1 (`Amount`) [obs key on DFN3; inf elsewhere].
    var amount: Double { min(max(value(["Amount", "amount", "Strength", "strength", "Level"], default: 0.8), 0), 1) }

    /// Duck level for `emphasize`: other tracks are attenuated by `amount × 24` dB [inf: placeholder until AU1].
    var duckGain: Double { pow(10, -amount * 24 / 20) }

    /// Pitch shift in semitones [inf: key and unit placeholder until AU1].
    var semitones: Double { value(["pitch", "Pitch", "semitones", "Semitones", "Shift"], default: 0) }
}

enum EffectRegistry {
    /// The processor for an effect, or nil to pass the signal through unchanged. `emphasize` acts
    /// on the mix (Mixer.mixTracks) and `pitch` on placement (resample + WSOLA, Mixer.stretched).
    static func processor(for e: AEffect, sampleRate: Double) -> (any AudioProcessor)? {
        switch e.kind {
        case .noiseRemoval:
            let a = e.amount
            return a > 0 ? NoiseReducer(sampleRate: sampleRate, amount: a) : nil
        case .leveling:
            return Leveler(sampleRate: sampleRate)
        case .pitch, .emphasize, .passThrough:
            return nil
        }
    }
}
