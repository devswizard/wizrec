// Sendable projection of a project's audio (AudioScene's internals) and the builder that reads it
// from TSCProjKit. Time rules follow docs/specs/time-mapping.md; gain nesting and defaults follow
// docs/specs/defaults.md; transition windows follow docs/specs/transitions.md.

import Foundation
import TSCProjKit

/// Sendable copy of one numeric parameter (constant or keyframed).
///
/// Same semantics as `TSCProjKit.Parameter.value(at:)` and RenderEngine's `SParam`: each keyframe
/// animates from the previous value (the first from `defaultValue`) to its own `value` across
/// `[time, endTime]`; between keyframes the value holds. Times are ticks on the clip's media axis.
struct AParam: Sendable, Equatable {
    struct Key: Sendable, Equatable {
        var time: Double
        var endTime: Double
        var value: Double
        var easeInOut: Bool
    }

    var base: Double?
    var keys: [Key]

    init(base: Double?, keys: [Key] = []) { self.base = base; self.keys = keys }

    /// Keyframe `interp` when neither the keyframe nor the parameter names one [?] (time-mapping.md §8).
    static let defaultInterp = "eioe"

    init?(_ raw: JSON) {
        func num(_ j: JSON?) -> Double? {
            switch j {
            case .number(let n)?: n.double
            case .bool(let b)?: b ? 1 : 0
            default: nil
            }
        }
        if let o = raw.object {
            let paramInterp = o["interp"]?.string
            let keys = (o["keyframes"]?.array?.items ?? []).compactMap(\.object).compactMap { k -> Key? in
                guard let v = num(k["value"]) else { return nil }
                let t = k["time"]?.double ?? 0
                let interp = k["interp"]?.string ?? paramInterp ?? Self.defaultInterp
                return Key(time: t, endTime: max(t, k["endTime"]?.double ?? t), value: v, easeInOut: interp == "eioe")
            }
            let base = num(o["defaultValue"])
            if base == nil && keys.isEmpty { return nil }
            self.init(base: base, keys: keys)
        } else {
            guard let v = num(raw) else { return nil }
            self.init(base: v)
        }
    }

    var isAnimated: Bool { !keys.isEmpty }

    /// The value when not animated (or the start value).
    var constant: Double? { base ?? keys.first?.value }

    func value(at t: Double) -> Double? {
        guard !keys.isEmpty else { return base }
        var current = base ?? keys[0].value
        for k in keys {
            if t < k.time { return current }
            if t >= k.endTime || k.endTime == k.time { current = k.value; continue }
            let x = (t - k.time) / (k.endTime - k.time)
            // eioe ≈ smoothstep, matching TSCProjKit/RenderEngine until docs/specs/animation.md.
            let e = k.easeInOut ? x * x * (3 - 2 * x) : x
            return current + (k.value - current) * e
        }
        return current
    }
}

/// Sendable copy of an audio `effects[]` entry.
struct AEffect: Sendable, Equatable {
    var name: String
    var parameters: [String: AParam]

    func value(_ key: String, default d: Double) -> Double { parameters[key]?.constant ?? d }
}

/// A gain ramp from a transition, in parent ticks: 0 → 1 over `[lo, hi)` (`fadeIn`) or 1 → 0.
struct AFade: Sendable, Equatable {
    var lo: Double
    var hi: Double
    var fadeIn: Bool

    func gain(at t: Double) -> Double {
        let span = hi - lo
        guard span > 0 else { return fadeIn ? (t >= hi ? 1 : 0) : (t < lo ? 1 : 0) }
        let x = min(max((t - lo) / span, 0), 1)
        return fadeIn ? x : 1 - x
    }
}

/// Loudness normalisation inputs of one leaf (AUD-2).
struct ALoudness: Sendable, Equatable {
    /// `sourceTracks[trackNumber].integratedLUFS`; nil when absent or the 100.0 "unmeasured" placeholder.
    var sourceLUFS: Double?
    /// `sourceTracks[trackNumber].peakLevel` (linear); nil when absent or the −1.0 sentinel.
    var sourcePeak: Double?
    /// Project `targetLoudness`, LUFS.
    var target: Double
}

/// Sendable projection of one audible clip. Times are ticks on the parent's timeline.
struct ANode: Sendable {
    /// Scene-unique index (cache key).
    var key: Int
    var clipID: Int64
    var start: Int64
    var duration: Int64
    var mediaStart: Rational
    var scalar: Rational
    /// `attributes.gain`, linear.
    var gain: Double
    /// `parameters.volume`, linear, keyframed on the media axis.
    var volume: AParam?
    var mixToMono: Bool
    var effects: [AEffect]
    var fades: [AFade] = []
    /// Pre-roll before `start` / post-roll after `end` from centred transitions, ticks.
    var extendBefore: Double = 0
    var extendAfter: Double = 0
    var body: Body

    enum Body: Sendable {
        /// `url`, stream index (`trackNumber`), the source channels the clip uses (nil = all).
        case leaf(url: URL, stream: Int, channels: [Int]?, loudness: ALoudness?)
        /// Group inner tracks, or a stitched clip's segments as one track.
        case container([ATrack])
    }

    var end: Int64 { start + duration }
    var isUnitSpeed: Bool { scalar.num == scalar.den }

    /// Parent-tick span the clip sounds in, transition handles included.
    var activeLo: Double { Double(start) - extendBefore }
    var activeHi: Double { Double(end) + extendAfter }

    /// Media (inner) ticks at parent tick `t`: `mediaStart + (t − start) / scalar` (time-mapping.md §4).
    func mediaTicks(at t: Double) -> Double {
        mediaStart.double + (t - Double(start)) * Double(scalar.den) / Double(scalar.num)
    }

    /// True when the clip can never be heard (constant zero gain or volume).
    var isSilent: Bool {
        if gain == 0 { return true }
        if let v = volume, !v.isAnimated, v.constant == 0 { return true }
        return false
    }
}

/// Sendable projection of a track's audio.
struct ATrack: Sendable {
    var muted: Bool
    var solo: Bool
    /// Clips sorted by `start`.
    var clips: [ANode]
}

/// Reads the audio side of a project. Never mutates it.
struct AudioSceneBuilder {
    struct Source { var media: SourceMedia; var url: URL }

    let sources: [Int64: Source]
    let normalise: Bool
    let target: Double
    private(set) var nextKey = 0

    init(project: Project, resolve: (SourceMedia) -> URL) {
        var s: [Int64: Source] = [:]
        for m in project.sourceBin { s[m.id] = Source(media: m, url: resolve(m)) }
        sources = s
        normalise = project.root["shouldApplyLoudnessNormalization"]?.bool ?? false
        target = project.root["targetLoudness"]?.double ?? -18
    }

    /// `attributes`: per-track UI state index-aligned with `tracks` (top level); group tracks carry
    /// the same keys inline [obs, FORMAT.md].
    mutating func tracks(_ tracks: [Track], attributes: [JSONObject] = []) -> [ATrack] {
        let sorted = tracks.enumerated().sorted { $0.element.index < $1.element.index }
        return sorted.map { i, t in
            let a = i < attributes.count ? attributes[i] : nil
            func flag(_ k: String) -> Bool { a?[k]?.bool ?? t.object[k]?.bool ?? false }
            var clips: [ANode] = []
            var byID: [Int64: Int] = [:]
            for c in t.clips {
                guard let n = node(c) else { continue }
                byID[c.id] = clips.count
                clips.append(n)
            }
            applyTransitions(t.transitions, to: &clips, byID: byID)
            clips.sort { $0.start < $1.start }
            return ATrack(muted: flag("audioMuted"), solo: flag("solo"), clips: clips)
        }
    }

    /// Fades and pre/post-roll from `track.transitions` (transitions.md §2): one-sided = fade at the
    /// clip edge; both sides = linear crossfade centred on the cut, both clips rolling into their
    /// media handles when `useAudioPreRoll` (default true) [inf]. `bypass` disables it.
    private func applyTransitions(_ list: [Transition], to clips: inout [ANode], byID: [Int64: Int]) {
        for tr in list {
            guard !tr.bypassed, tr.duration > 0 else { continue }
            let roll = tr.object["useAudioPreRoll"]?.bool ?? true
            let d = Double(tr.duration)
            let l = tr.leftMediaID.flatMap { byID[$0] }
            let r = tr.rightMediaID.flatMap { byID[$0] }
            switch (l, r) {
            case (let l?, let r?):
                let cut = Double(clips[r].start)
                let lo = cut - d / 2, hi = cut + d / 2
                clips[l].fades.append(AFade(lo: roll ? lo : max(lo, Double(clips[l].start)), hi: roll ? hi : cut, fadeIn: false))
                clips[r].fades.append(AFade(lo: roll ? lo : cut, hi: roll ? hi : min(hi, Double(clips[r].end)), fadeIn: true))
                if roll {
                    clips[l].extendAfter = max(clips[l].extendAfter, hi - Double(clips[l].end))
                    clips[r].extendBefore = max(clips[r].extendBefore, Double(clips[r].start) - lo)
                }
            case (let l?, nil):
                let e = Double(clips[l].end)
                clips[l].fades.append(AFade(lo: e - d, hi: e, fadeIn: false))
            case (nil, let r?):
                let s = Double(clips[r].start)
                clips[r].fades.append(AFade(lo: s, hi: s + d, fadeIn: true))
            default:
                continue
            }
        }
    }

    private mutating func key() -> Int { defer { nextKey += 1 }; return nextKey }

    /// The audible node for clip `c`, or nil when it has no audio (video, image, callout, …) or is
    /// muted by a constant zero gain.
    mutating func node(_ c: Clip) -> ANode? {
        switch c.kind {
        case .unified:
            // The audio half repeats the parent's timing [obs] and carries its own gain and effects;
            // the parent's effects[] mirror the children (researcher, effects/README.md), so only the
            // child's are applied. The node keeps the parent's id so transitions find it.
            guard let a = c.audio, var n = node(a) else { return nil }
            n.clipID = c.id
            return n
        case .audio:
            guard let sid = c.sourceID, let src = sources[sid] else { return nil }
            let stream = Int(c.sourceTrackNumber ?? 0)
            let tracks = src.media.tracks
            let st = stream >= 0 && stream < tracks.count ? tracks[stream] : nil
            let channels = c.object["channelNumber"]?.string.map { s in
                s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 >= 0 }
            }
            var loud: ALoudness?
            // Three switches: project × source × clip (audio.md §2) [inf].
            if normalise, src.media.object["loudnessNormalization"]?.bool ?? true,
               c.attributes?["loudnessNormalization"]?.bool ?? true {
                // 100.0 / −1.0 are the sentinels of unmeasured (non-audio) tracks; −Infinity = silence
                // [obs, audio.md §1]. A non-finite LUFS stays as is (silence → no gain).
                let lufs = st?.object["integratedLUFS"]?.double
                let peak = st?.object["peakLevel"]?.double
                loud = ALoudness(sourceLUFS: lufs.flatMap { $0 >= 99.99 ? nil : $0 },
                                 sourcePeak: peak.flatMap { $0 < 0 ? nil : $0 }, target: target)
            }
            return make(c, .leaf(url: src.url, stream: stream,
                                 channels: (channels?.isEmpty ?? true) ? nil : channels, loudness: loud))
        case .stitched:
            let segs = c.segments.compactMap { node($0) }.sorted { $0.start < $1.start }
            guard !segs.isEmpty else { return nil }
            return make(c, .container([ATrack(muted: false, solo: false, clips: segs)]))
        case .group:
            let inner = tracks(c.tracks)
            guard inner.contains(where: { !$0.clips.isEmpty }) else { return nil }
            return make(c, .container(inner))
        default:
            return nil
        }
    }

    private mutating func make(_ c: Clip, _ body: ANode.Body) -> ANode? {
        let o = c.object
        let effects = (o["effects"]?.array?.items ?? []).compactMap(\.object).compactMap { e -> AEffect? in
            let name = e["effectName"]?.string ?? ""
            guard !name.isEmpty, name != "dummy", !(e["bypassed"]?.bool ?? false) else { return nil }
            var params: [String: AParam] = [:]
            for (k, v) in e["parameters"]?.object?.entries ?? [] { params[k] = AParam(v) }
            if (params["Bypass"]?.constant ?? 0) >= 0.5 { return nil }
            return AEffect(name: name, parameters: params)
        }
        let scalar = c.scalar.num <= 0 ? Rational(1) : c.scalar
        let n = ANode(key: key(), clipID: c.id, start: c.start, duration: max(0, c.duration),
                      mediaStart: c.mediaStart, scalar: scalar,
                      gain: c.attributes?["gain"]?.double ?? 1,
                      volume: o["parameters"]?.object?["volume"].flatMap(AParam.init),
                      mixToMono: c.attributes?["mixToMono"]?.bool ?? false,
                      effects: effects, body: body)
        return n.isSilent || n.duration == 0 ? nil : n
    }
}
