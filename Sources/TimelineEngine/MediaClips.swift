import Foundation
import TSCProjKit

/// Builds `sourceBin` entries and new clips in the shape Camtasia 2026
/// (format 10.0) writes them. Key names and order are copied from the user's
/// own projects (demo, vlog) and Camtasia's sample projects [obs]; values
/// that those files cannot tell us are marked [inf].
enum MediaJSON {
    // MARK: sourceBin

    /// `sourceTracks` from a descriptor. `integratedLUFS` 100.0 / `peakLevel`
    /// −1.0 are the "not measured" values Camtasia writes for video and image
    /// tracks [obs]; we write them for audio too until AudioEngine measures
    /// loudness [inf].
    static func sourceTracks(_ d: SourceDescriptor) -> JSON {
        let name = (d.src as NSString).lastPathComponent
        return J.arr(d.tracks.map { t in
            J.obj([
                ("range", J.arr([J.int(0), J.int(t.rangeEnd)])),
                ("type", J.int(t.type)),
                ("editRate", J.int(t.editRate)),
                ("trackRect", J.arr([J.int(0), J.int(0), J.int(t.width), J.int(t.height)])),
                ("sampleRate", t.sampleRate.json),
                ("bitDepth", J.int(t.bitDepth)),
                ("numChannels", J.int(t.channelCount)),
                ("integratedLUFS", J.dbl(100)),
                ("peakLevel", J.dbl(-1)),
                ("tag", J.int(0)),
                ("metaData", .string("\(name);")),
                ("parameters", J.emptyObject),
            ])
        })
    }

    /// Source `rect`: the first track's frame, `[0, 0, 0, 0]` for audio-only [obs].
    static func rect(_ d: SourceDescriptor) -> JSON {
        let t = d.tracks.first { $0.type != 2 }
        return J.arr([J.int(0), J.int(0), J.int(t?.width ?? 0), J.int(t?.height ?? 0)])
    }

    static func sourceEntry(id: Int64, _ d: SourceDescriptor, added: Date) -> JSONObject {
        JSONObject([
            ("id", J.int(id)),
            ("src", .string(d.src)),
            ("rect", rect(d)),
            ("lastMod", .string(Stamp.string(d.lastModified, micro: false))),
            ("loudnessNormalization", .bool(true)),
            ("sourceTracks", sourceTracks(d)),
            ("metadata", J.obj([("timeAdded", .string(Stamp.string(added, micro: true)))])),
        ])
    }

    // MARK: Clips

    /// Fit-to-canvas scale capped at 1: `min(1, W/w, H/h)` (transform.md §3).
    static func defaultScale(width w: Double, height h: Double, canvasW: Double, canvasH: Double) -> Double {
        guard w > 0, h > 0 else { return 1 }
        return min(1, canvasW / w, canvasH / h)
    }

    /// `metadata.default-scale` text: ≤ 6 significant digits (`"0.714286"`, `"1"`) [obs].
    static func defaultScaleText(_ s: Double) -> String { String(format: "%.6g", s) }

    /// Clip metadata. Visual clips (`lockAspect`) get `lockAspectRatio`
    /// true in the typed form Camtasia 2026 writes [obs, edit-semantics.md
    /// ED0; group-edits.md §7]; its position after `effectApplied` is [inf].
    static func metadata(defaultScale: Double?, lockAspect: Bool = false) -> JSON {
        var pairs: [(String, JSON)] = [
            ("audiateLinkedSession", .string("")),
            ("clipSpeedAttribute", J.typedBool(false)),
            ("colorAttribute", J.obj([("type", .string("color")), ("value", J.arr([J.int(0), J.int(0), J.int(0), J.int(0)]))])),
        ]
        if let s = defaultScale { pairs.append(("default-scale", .string(defaultScaleText(s)))) }
        pairs.append(("effectApplied", .string("none")))
        if lockAspect { pairs.append(("lockAspectRatio", J.typedBool(true))) }
        return J.obj(pairs)
    }

    /// Visual parameters of a new clip: `scale0/1` only when ≠ 1 (absent
    /// means 1 [inf]), then crops (images also get `sourceCrop0…3`) [obs].
    static func visualParameters(scale: Double, image: Bool) -> JSON {
        var pairs: [(String, JSON)] = []
        if scale != 1 { pairs += [("scale0", J.param(scale)), ("scale1", J.param(scale))] }
        if image { for i in 0..<4 { pairs.append(("sourceCrop\(i)", J.param(0))) } }
        for i in 0..<4 { pairs.append(("geometryCrop\(i)", J.param(0))) }
        return J.obj(pairs)
    }

    struct Timing {
        var start: Int64, duration: Int64, mediaDuration: Int64
    }

    static func timingPairs(_ t: Timing) -> [(String, JSON)] {
        [("start", J.int(t.start)), ("duration", J.int(t.duration)), ("mediaStart", J.int(0)),
         ("mediaDuration", J.int(t.mediaDuration)), ("scalar", J.int(1))]
    }

    /// `"0,1"` for stereo, `"0"` for mono [obs].
    static func channelNumber(_ n: Int) -> String {
        (0..<max(n, 1)).map(String.init).joined(separator: ",")
    }

    static func audioAttributes(ident: String) -> JSON {
        J.obj([("ident", .string(ident)), ("gain", J.dbl(1)), ("mixToMono", .bool(false)),
               ("loudnessNormalization", .bool(true)), ("sourceFileOffset", J.int(0))])
    }

    static func videoClip(id: Int64, type: String, src: Int64, stream: Int, ident: String, scale: Double,
                          timing: Timing, metadata: JSON?) -> JSONObject {
        var pairs: [(String, JSON)] = [
            ("id", J.int(id)), ("_type", .string(type)), ("src", J.int(src)), ("trackNumber", J.int(stream)),
            ("attributes", J.obj([("ident", .string(ident))])),
            ("parameters", visualParameters(scale: scale, image: false)), ("effects", J.emptyArray),
        ]
        pairs += timingPairs(timing)
        if let metadata { pairs.append(("metadata", metadata)) }
        pairs.append(("animationTracks", J.emptyObject))
        return JSONObject(pairs)
    }

    static func audioClip(id: Int64, src: Int64, stream: Int, ident: String, channels: Int,
                          timing: Timing, metadata: JSON?) -> JSONObject {
        var pairs: [(String, JSON)] = [
            ("id", J.int(id)), ("_type", .string("AMFile")), ("src", J.int(src)), ("trackNumber", J.int(stream)),
            ("attributes", audioAttributes(ident: ident)), ("channelNumber", .string(channelNumber(channels))),
            ("parameters", J.emptyObject), ("effects", J.emptyArray),
        ]
        pairs += timingPairs(timing)
        if let metadata { pairs.append(("metadata", metadata)) }
        pairs.append(("animationTracks", J.emptyObject))
        return JSONObject(pairs)
    }

    static func imageClip(id: Int64, src: Int64, ident: String, scale: Double, start: Int64,
                          duration: Int64) -> JSONObject {
        var pairs: [(String, JSON)] = [
            ("id", J.int(id)), ("_type", .string("IMFile")), ("src", J.int(src)), ("trackNumber", J.int(0)),
            ("trimStartSum", J.int(0)), ("attributes", J.obj([("ident", .string(ident))])),
            ("parameters", visualParameters(scale: scale, image: true)), ("effects", J.emptyArray),
        ]
        // Images: mediaStart 0, mediaDuration 1 tick whatever the duration [obs].
        pairs += [("start", J.int(start)), ("duration", J.int(duration)), ("mediaStart", J.int(0)),
                  ("mediaDuration", J.int(1)), ("scalar", J.int(1))]
        pairs += [("metadata", metadata(defaultScale: scale, lockAspect: true)), ("animationTracks", J.emptyObject)]
        return JSONObject(pairs)
    }

    /// `UnifiedMedia` parent: no `attributes`/`parameters`/`animationTracks` of
    /// its own; children repeat its timing [obs, vlog].
    static func unifiedClip(id: Int64, video: JSONObject, audio: JSONObject, scale: Double,
                            timing: Timing) -> JSONObject {
        var pairs: [(String, JSON)] = [
            ("id", J.int(id)), ("_type", .string("UnifiedMedia")), ("video", .object(video)),
            ("audio", .object(audio)), ("effects", J.emptyArray),
        ]
        pairs += timingPairs(timing)
        pairs.append(("metadata", metadata(defaultScale: scale, lockAspect: true)))
        return JSONObject(pairs)
    }
}
