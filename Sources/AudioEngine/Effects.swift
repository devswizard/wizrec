// Audio effects by `effectName` (AUD-3, aligned with docs/specs/audio.md §3 from AU1).
//
// Camtasia 2026.2.3 writes exactly these audio effects [obs, AU1]: `VSTEffect-DFN3NoiseRemoval`
// (AI Noise Removal), `WinCompression` (Audio Compression), `Emphasize` and `Pitch`. Fades and
// Clip Speed are not effects (volume keyframes and `metadata.clipSpeedAttribute`). Older projects
// may hold other names (classic noise removal, volume leveling, …): those still map by keyword so
// such projects keep sounding as before, and anything unknown passes through. WizRec never uses
// TechSmith's plug-ins: every effect below is WizRec's own DSP, and the effect's opaque `metadata`
// (`ExtandableEffectData`) is preserved untouched by TSCProjKit (AudioEngine never writes projects).

import Foundation

/// What an `effectName` does in WizRec's mixer.
enum AudioEffectKind: Equatable, Sendable {
    /// Spectral noise reduction (`Amount` 0–1): `VSTEffect-DFN3NoiseRemoval` and older names.
    case noiseRemoval
    /// Downward compressor with make-up gain: `WinCompression`.
    case compression
    /// Slow automatic gain toward a target level. Only for effect names of older versions
    /// (volume leveling); 2026.2.3 has no such panel item [obs].
    case leveling
    /// Ducks the other tracks at the same level while the clip sounds (track-level, Mixer.swift).
    case emphasize
    /// Pitch shift in cents, duration unchanged.
    case pitch
    /// Unknown or not an audio effect: passes the signal through.
    case passThrough

    /// The kind for an `effectName`: exact 2026.2.3 names first [obs, AU1], then keywords for
    /// older names [inf].
    init(effectName name: String) {
        switch name {
        case "VSTEffect-DFN3NoiseRemoval": self = .noiseRemoval; return
        case "WinCompression": self = .compression; return
        case "Emphasize": self = .emphasize; return
        case "Pitch": self = .pitch; return
        default: break
        }
        let n = name.lowercased()
        if n.contains("noiseremoval") || n.contains("noisereduction") || n.contains("denoise") {
            self = .noiseRemoval
        } else if n.contains("compress") {
            self = .compression
        } else if n.contains("leveling") || n.contains("leveler") || n.contains("dynamics") {
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

/// Default parameter values Camtasia 2026.2.3 writes when the effect is applied [obs, AU1].
enum AudioEffectDefaults {
    static let noiseAmount = 0.8
    static let compRatio = 10.0, compThreshold = -20.0, compGain = 9.0, compAttack = 0.0, compRelease = 3500.0
    static let emphasizeAmount = 0.8
    /// 1 s at editRate 705600000, ticks.
    static let emphasizeRamp = 705_600_000.0
    static let pitchCents = -200.0, pitchBlend = 100.0
}

extension AEffect {
    var kind: AudioEffectKind { AudioEffectKind(effectName: name) }

    /// The first present parameter among `keys` (constant or start value), else `d`.
    func value(_ keys: [String], default d: Double) -> Double {
        for k in keys { if let v = parameters[k]?.constant, v.isFinite { return v } }
        return d
    }

    /// Noise-removal strength 0–1 (`Amount`) [obs key and default 0.8].
    var amount: Double {
        min(max(value(["Amount", "amount", "Strength", "strength", "Level"], default: AudioEffectDefaults.noiseAmount), 0), 1)
    }

    /// `emphasizeAmount` 0–1: how much the other tracks are lowered [obs key/default; inf meaning].
    var emphasizeAmount: Double {
        min(max(value(["emphasizeAmount"], default: AudioEffectDefaults.emphasizeAmount), 0), 1)
    }

    /// Duck gain for `emphasize`, linear: `1 − emphasizeAmount` [WizRec: the dB mapping needs an
    /// export, audio.md §3.2].
    var duckGain: Double { 1 - emphasizeAmount }

    /// Duck ramp lengths, ticks (`emphasizeRampInTime` / `emphasizeRampOutTime`) [obs keys, 1 s default].
    var emphasizeRampIn: Double { max(0, value(["emphasizeRampInTime"], default: AudioEffectDefaults.emphasizeRamp)) }
    var emphasizeRampOut: Double { max(0, value(["emphasizeRampOutTime"], default: AudioEffectDefaults.emphasizeRamp)) }

    /// `emphasizeRampPosition` 0 = ramps inside the clip [inf]; other values [?] put them outside.
    var emphasizeRampsInside: Bool { value(["emphasizeRampPosition"], default: 0) == 0 }

    /// Pitch shift in semitones from `pitch` (cents, default −200) [obs key; inf unit], ±24 st.
    var semitones: Double { min(max(value(["pitch"], default: AudioEffectDefaults.pitchCents) / 100, -24), 24) }

    /// Wet share 0–1 from `effectBlend` (percent, default 100) [obs key; inf meaning].
    var pitchBlend: Double { min(max(value(["effectBlend"], default: AudioEffectDefaults.pitchBlend) / 100, 0), 1) }
}

enum EffectRegistry {
    /// The processor for an effect, or nil to pass the signal through unchanged. `emphasize` acts
    /// on the mix (Mixer.mixTracks) and `pitch` on placement (resample + WSOLA, Mixer.stretched).
    static func processor(for e: AEffect, sampleRate: Double) -> (any AudioProcessor)? {
        switch e.kind {
        case .noiseRemoval:
            let a = e.amount
            return a > 0 ? NoiseReducer(sampleRate: sampleRate, amount: a) : nil
        case .compression:
            return Compressor(sampleRate: sampleRate,
                              thresholdDB: e.value(["threshold"], default: AudioEffectDefaults.compThreshold),
                              ratio: e.value(["ratio"], default: AudioEffectDefaults.compRatio),
                              makeupDB: e.value(["gain"], default: AudioEffectDefaults.compGain),
                              attackMS: e.value(["attack"], default: AudioEffectDefaults.compAttack),
                              releaseMS: e.value(["release"], default: AudioEffectDefaults.compRelease))
        case .leveling:
            return Leveler(sampleRate: sampleRate)
        case .pitch, .emphasize, .passThrough:
            return nil
        }
    }
}
