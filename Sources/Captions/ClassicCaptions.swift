import Foundation
import TSCProjKit
import TimelineEngine

/// Classic (non-dynamic) captions: `parameters.captions` on an audio clip (`docs/specs/captions.md`
/// §1): `{type: "caption", keyframes: [{endTime, time, value: {text, textAttributes}, duration: 0}]}`.
/// A caption runs from its keyframe to the next one; `text: ""` means no caption.
///
/// Carriers: top-level `AMFile` clips, and the `audio` child of top-level `UnifiedMedia` clips [inf].
/// Keyframe time axis: **clip-local** ticks (timeline time − clip `start`), as the spec reads the
/// one observed instance [?, experiment CA1]; `localTicks`/`timelineTicks` are the only places
/// that encode this choice.
@MainActor
public enum ClassicCaptions {
    /// A clip that can carry captions.
    struct Carrier {
        let clip: TopClip
        /// Path of the `parameters` object that holds `captions`.
        let parametersPath: TreePath
        /// The object owning that `parameters` (the clip, or its `audio` child).
        let owner: JSONObject
        var start: Int64 { clip.clip.start }
        var duration: Int64 { clip.clip.duration }
    }

    /// Caption segment in clip-local ticks.
    struct Segment { var start: Int64; var end: Int64; var value: JSON }

    static func localTicks(_ timeline: Int64, _ c: Carrier) -> Int64 { timeline - c.start }
    static func timelineTicks(_ local: Int64, _ c: Carrier) -> Int64 { c.start + local }

    static func carriers(_ project: Project) -> [Carrier] {
        Tree.topClips(project).compactMap { tc in
            switch tc.object["_type"]?.string {
            case "AMFile": return Carrier(clip: tc, parametersPath: tc.path.appending(.key("parameters")), owner: tc.object)
            case "UnifiedMedia":
                guard let a = tc.object["audio"]?.object else { return nil }
                return Carrier(clip: tc, parametersPath: tc.path.appending(.key("audio"), .key("parameters")), owner: a)
            default: return nil
            }
        }
    }

    /// Existing caption segments of a carrier (empty text skipped), clip-local ticks, sorted.
    static func segments(_ c: Carrier) -> [Segment] {
        let kfs = (c.owner["parameters"]?.object?["captions"]?.object?["keyframes"]?.array?.items ?? [])
            .compactMap(\.object).compactMap { k -> (Int64, JSON)? in
                guard let t = k["time"]?.int else { return nil }
                return (t, k["value"] ?? .null)
            }
            .sorted { $0.0 < $1.0 }
        return kfs.enumerated().compactMap { i, kv in
            let end = i + 1 < kfs.count ? kfs[i + 1].0 : max(c.duration, kv.0)
            guard let text = kv.1.object?["text"]?.string, !text.isEmpty, end > kv.0 else { return nil }
            return Segment(start: kv.0, end: end, value: kv.1)
        }
    }

    /// Every classic caption on the top-level tracks, timeline seconds, sorted by start, clipped
    /// to the carrying clip.
    public static func cues(in project: Project) -> [CaptionCue] {
        let tb = project.timebase
        return carriers(project).flatMap { c in
            segments(c).compactMap { s -> CaptionCue? in
                let a = max(s.start, 0), b = min(s.end, c.duration)
                guard b > a else { return nil }
                return CaptionCue(start: tb.seconds(timelineTicks(a, c)), end: tb.seconds(timelineTicks(b, c)),
                                  text: s.value.object?["text"]?.string ?? "")
            }
        }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func value(_ text: String) -> JSON { J.obj([("text", J.str(text)), ("textAttributes", .null)]) }

    /// Keyframes for sorted, non-overlapping segments: `""` at 0 when the first caption starts
    /// later (the observed list starts at 0 [obs]), `""` in gaps and after the last caption when it
    /// ends before the clip does.
    static func keyframes(_ segs: [Segment], duration: Int64) -> [JSON] {
        var out: [JSON] = []
        func kf(_ t: Int64, _ v: JSON) {
            out.append(J.obj([("endTime", J.int(t)), ("time", J.int(t)), ("value", v), ("duration", J.int(0))]))
        }
        var cursor: Int64 = 0
        for (i, s) in segs.enumerated() {
            if s.start > cursor || (i == 0 && s.start > 0) { kf(cursor, value("")) }
            kf(s.start, s.value)
            cursor = s.end
        }
        if !segs.isEmpty, cursor < duration { kf(cursor, value("")) }
        return out
    }
}

/// Adds captions (timeline seconds) as classic captions on audio clips (see `ClassicCaptions`).
///
/// - Each cue goes to `clipID` when given (it must be a top-level `AMFile` or `UnifiedMedia`),
///   else to the carrier clip it overlaps most; cues overlapping no carrier are skipped and listed
///   in `droppedCues`. Cues are clipped to their clip and times are rounded to output frames.
/// - New cues replace existing captions where they overlap (existing captions are trimmed, keeping
///   their `value` objects); when new cues overlap each other, the later start wins.
/// - Revert is byte-identical.
@MainActor public final class AddCaptions: EditCommand {
    public let name = "Add Captions"
    public let cues: [CaptionCue]
    public let clipID: Int64?
    /// Cues no carrier clip overlapped (set by `apply`).
    public private(set) var droppedCues: [CaptionCue] = []
    private var swap = Swap()

    public init(cues: [CaptionCue], clipID: Int64? = nil) { self.cues = cues; self.clipID = clipID }

    public func apply(to project: Project) throws {
        var carriers = ClassicCaptions.carriers(project)
        if let id = clipID {
            carriers = carriers.filter { $0.clip.clip.id == id }
            guard !carriers.isEmpty else { throw EditError.invalid("clip \(id) is not a top-level audio clip") }
        }
        var perCarrier: [Int: [ClassicCaptions.Segment]] = [:]
        var dropped: [CaptionCue] = []
        for cue in cues {
            let a = Tree.ticks(cue.start, project), b = Tree.ticks(cue.end, project)
            let best = carriers.indices.map { i -> (Int, Int64) in
                let c = carriers[i]
                return (i, min(b, c.start + c.duration) - max(a, c.start))
            }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
            let text = SubtitleFile.payload(cue.text)
            guard let (ci, _) = best, b > a, !text.isEmpty else { dropped.append(cue); continue }
            let c = carriers[ci]
            let s = ClassicCaptions.localTicks(max(a, c.start), c), e = ClassicCaptions.localTicks(min(b, c.start + c.duration), c)
            perCarrier[ci, default: []].append(.init(start: s, end: e, value: ClassicCaptions.value(text)))
        }
        var edits: [(path: TreePath, new: JSON)] = []
        for (ci, added) in perCarrier.sorted(by: { $0.key < $1.key }) {
            let c = carriers[ci]
            let segs = Self.merge(existing: ClassicCaptions.segments(c), added: added)
            let captions = J.obj([("type", J.str("caption")),
                                  ("keyframes", J.arr(ClassicCaptions.keyframes(segs, duration: c.duration)))])
            let params = c.owner["parameters"]?.object?.copy() ?? JSONObject()
            params["captions"] = captions
            edits.append((c.parametersPath, .object(params)))
        }
        guard !edits.isEmpty else { throw EditError.invalid("no cue overlaps an audio clip") }
        try swap.commit(edits, in: project)
        droppedCues = dropped
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); droppedCues = [] }

    /// Existing segments minus the added intervals, plus the added ones (later start wins among
    /// added), sorted. Existing values are deep-copied.
    static func merge(existing: [ClassicCaptions.Segment], added: [ClassicCaptions.Segment]) -> [ClassicCaptions.Segment] {
        var add = added.sorted { $0.start < $1.start }
        for i in add.indices.dropLast() where add[i].end > add[i + 1].start { add[i].end = add[i + 1].start }
        add = add.filter { $0.end > $0.start }
        var out: [ClassicCaptions.Segment] = []
        for e in existing {
            var pieces = [(e.start, e.end)]
            for a in add {
                pieces = pieces.flatMap { p -> [(Int64, Int64)] in
                    guard a.start < p.1, a.end > p.0 else { return [p] }
                    return [(p.0, a.start), (a.end, p.1)].filter { $0.1 > $0.0 }
                }
            }
            out += pieces.map { .init(start: $0.0, end: $0.1, value: e.value.copy()) }
        }
        return (out + add).sorted { $0.start < $1.start }
    }
}

/// Subtitle files ↔ project captions.
@MainActor
public enum CaptionFiles {
    /// An `AddCaptions` for an SRT or WebVTT file's text (format detected by the `WEBVTT` signature).
    public static func importCommand(_ text: String, clipID: Int64? = nil) throws -> AddCaptions {
        AddCaptions(cues: try parse(text), clipID: clipID)
    }

    /// Cues of an SRT or WebVTT text.
    public static func parse(_ text: String) throws -> [CaptionCue] {
        let head = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return head.hasPrefix("WEBVTT") ? try SubtitleFile.parseVTT(text) : try SubtitleFile.parseSRT(text)
    }

    /// The project's captions as cues: classic captions when there are any, else the blocks of
    /// every dynamic caption (`DynamicCaptions.cues`).
    public static func cues(in project: Project) -> [CaptionCue] {
        let classic = ClassicCaptions.cues(in: project)
        return classic.isEmpty ? DynamicCaptions.cues(in: project) : classic
    }

    public static func srt(_ project: Project) -> String { SubtitleFile.srt(cues(in: project)) }
    public static func vtt(_ project: Project) -> String { SubtitleFile.vtt(cues(in: project)) }
}
