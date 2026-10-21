import AppKit
import Foundation
import TSCProjKit
import TimelineEngine

/// Classic (non-dynamic) captions: `parameters.captions` on an audio clip (`docs/specs/captions.md`
/// §1): `{type: "caption", keyframes: [{endTime, time, value: {text, textAttributes}, duration: 0}]}`.
/// A caption runs from its keyframe to the next one; `text: ""` means no caption.
///
/// Carriers: top-level `AMFile` clips, and the `audio` child of top-level `UnifiedMedia` clips [inf].
/// Keyframe time axis: the clip's **media time** in ticks (`mediaStart + (t − start) / scalar`), like
/// every other keyframed clip parameter (time-mapping.md §6) [obs CA1: keyframes stay put when the
/// clip moves]. Split, ripple delete and move keep every caption keyframe on each piece, none pruned
/// or shifted, so a piece may carry captions outside its media window [obs CA1]; readers clip to the
/// window. `localTicks`/`timelineTicks` are the only places that encode the axis.
@MainActor
public enum ClassicCaptions {
    /// A clip that can carry captions.
    @MainActor struct Carrier {
        let clip: TopClip
        /// Path of the `parameters` object that holds `captions`.
        let parametersPath: TreePath
        /// The object owning that `parameters` (the clip, or its `audio` child).
        let owner: JSONObject
        var start: Int64 { clip.clip.start }
        var duration: Int64 { clip.clip.duration }
        /// The clip's span on the caption axis (media ticks).
        var mediaLo: Int64 { ClassicCaptions.localTicks(start, self) }
        var mediaHi: Int64 { ClassicCaptions.localTicks(start + duration, self) }
    }

    /// Caption segment in caption-axis (media) ticks.
    struct Segment { var start: Int64; var end: Int64; var value: JSON }

    static func localTicks(_ timeline: Int64, _ c: Carrier) -> Int64 {
        Int64(c.clip.clip.mediaTime(atTimeline: timeline).double.rounded())
    }
    static func timelineTicks(_ local: Int64, _ c: Carrier) -> Int64 {
        let k = c.clip.clip
        return c.start + Int64(((Double(local) - k.mediaStart.double) * k.scalar.double).rounded())
    }

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
            let end = i + 1 < kfs.count ? kfs[i + 1].0 : max(c.mediaHi, kv.0)
            guard let raw = kv.1.object?["text"]?.string, !plainText(raw).isEmpty, end > kv.0 else { return nil }
            return Segment(start: kv.0, end: end, value: kv.1)
        }
    }

    /// The plain text of a caption's `value.text`. Camtasia's caption editor saves typed text
    /// as a Cocoa RTF document (`{\rtf1…}`) [obs, captions.md §1 CA1]; that is converted with
    /// the system RTF reader and its fonts, sizes and colours are ignored (captions are styled
    /// by `captionAttributes`). Trailing line breaks are dropped. Any other string is returned
    /// as is, and RTF the reader rejects falls back to the raw string.
    public static func plainText(_ text: String) -> String {
        guard text.hasPrefix("{\\rtf"),
              let a = try? NSAttributedString(data: Data(text.utf8),
                                              options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil)
        else { return text }
        var s = a.string
        while let last = s.last, last.isNewline { s.removeLast() }
        return s
    }

    /// Every classic caption on the top-level tracks, timeline seconds, sorted by start, clipped
    /// to the carrying clip.
    public static func cues(in project: Project) -> [CaptionCue] {
        let tb = project.timebase
        return carriers(project).flatMap { c in
            segments(c).compactMap { s -> CaptionCue? in
                let a = max(s.start, c.mediaLo), b = min(s.end, c.mediaHi)
                guard b > a else { return nil }
                return CaptionCue(start: tb.seconds(timelineTicks(a, c)), end: tb.seconds(timelineTicks(b, c)),
                                  text: plainText(s.value.object?["text"]?.string ?? ""))
            }
        }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func value(_ text: String) -> JSON { J.obj([("text", J.str(text)), ("textAttributes", .null)]) }

    static func keyframe(_ t: Int64, _ v: JSON) -> JSON {
        J.obj([("endTime", J.int(t)), ("time", J.int(t)), ("value", v), ("duration", J.int(0))])
    }

    /// Keyframes for sorted, non-overlapping segments: `""` at the media window's start (`start`,
    /// = `mediaStart`; Camtasia's lists start there [obs CA1]) when the first caption starts later,
    /// `""` in gaps and after the last caption when it ends before the clip does.
    static func keyframes(_ segs: [Segment], start: Int64, end: Int64) -> [JSON] {
        var out: [JSON] = []
        func kf(_ t: Int64, _ v: JSON) { out.append(keyframe(t, v)) }
        let origin = min(start, segs.first?.start ?? start)
        var cursor = origin
        for (i, s) in segs.enumerated() {
            if s.start > cursor || (i == 0 && s.start > origin) { kf(cursor, value("")) }
            kf(s.start, s.value)
            cursor = s.end
        }
        if !segs.isEmpty, cursor < end { kf(cursor, value("")) }
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
                                  ("keyframes", J.arr(ClassicCaptions.keyframes(segs, start: c.mediaLo, end: c.mediaHi)))])
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

/// Modify ▸ Closed Captions ▸ Add Captions on one audio clip (a top-level `AMFile` or
/// `UnifiedMedia`): one empty caption (`text` "", `textAttributes` null) every `segmentSeconds`
/// (4 s) of **media time**, starting at the clip's `mediaStart` and running to the end of its media
/// window; the last segment may be very short [obs CA1: 0/4/8/12 s on a 13.2 s clip, 1/5/9/13 s
/// after a 1 s left trim]. `timeline.captionAttributes` is not touched [obs]. A clip that already
/// has a `captions` parameter is rejected [WizRec; Camtasia's behaviour there is unobserved].
/// Revert is byte-identical.
@MainActor public final class AddEmptyCaptions: EditCommand {
    public let name = "Add Captions"
    public let clipID: Int64
    /// Segment length, seconds of media time.
    public static let segmentSeconds: Int64 = 4
    private var swap = Swap()

    public init(clipID: Int64) { self.clipID = clipID }

    public func apply(to project: Project) throws {
        guard let c = ClassicCaptions.carriers(project).first(where: { $0.clip.clip.id == clipID }) else {
            throw EditError.invalid("clip \(clipID) is not a top-level audio clip")
        }
        guard c.owner["parameters"]?.object?["captions"] == nil else {
            throw EditError.invalid("clip \(clipID) already has captions")
        }
        let lo = c.clip.clip.mediaStart.double.rounded(), hi = Double(c.mediaHi)
        let step = project.timebase.editRate * Self.segmentSeconds
        guard Double(lo) < hi, step > 0 else { throw EditError.invalid("clip \(clipID) is empty") }
        var kfs: [JSON] = []
        var t = Int64(lo)
        while Double(t) < hi {
            kfs.append(ClassicCaptions.keyframe(t, ClassicCaptions.value("")))
            t += step
        }
        let params = c.owner["parameters"]?.object?.copy() ?? JSONObject()
        params["captions"] = J.obj([("type", J.str("caption")), ("keyframes", J.arr(kfs))])
        try swap.commit([(c.parametersPath, .object(params))], in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Removes classic captions inside a timeline range (seconds; nil = everything), trimming captions
/// that cross its edges, on `clipID` only when given. A clip left without captions loses its
/// `captions` parameter. Throws when no caption is touched. Revert is byte-identical.
@MainActor public final class RemoveCaptions: EditCommand {
    public let name = "Delete Captions"
    public let range: ClosedRange<Double>?
    public let clipID: Int64?
    private var swap = Swap()

    public init(range: ClosedRange<Double>? = nil, clipID: Int64? = nil) { self.range = range; self.clipID = clipID }

    public func apply(to project: Project) throws {
        var edits: [(path: TreePath, new: JSON)] = []
        for c in ClassicCaptions.carriers(project) where clipID == nil || c.clip.clip.id == clipID {
            let segs = ClassicCaptions.segments(c)
            guard !segs.isEmpty else { continue }
            let cut = range.map {
                ClassicCaptions.Segment(start: ClassicCaptions.localTicks(Tree.ticks($0.lowerBound, project), c),
                                        end: ClassicCaptions.localTicks(Tree.ticks($0.upperBound, project), c), value: .null)
            } ?? .init(start: Int64.min / 2, end: Int64.max / 2, value: .null)
            guard segs.contains(where: { $0.start < cut.end && $0.end > cut.start }) else { continue }
            let kept = AddCaptions.merge(existing: segs, added: [cut]).filter { !$0.value.isNull }
            let params = c.owner["parameters"]?.object?.copy() ?? JSONObject()
            if kept.isEmpty {
                params["captions"] = nil
            } else {
                params["captions"] = J.obj([("type", J.str("caption")),
                                            ("keyframes", J.arr(ClassicCaptions.keyframes(kept, start: c.mediaLo, end: c.mediaHi)))])
            }
            edits.append((c.parametersPath, .object(params)))
        }
        guard !edits.isEmpty else { throw EditError.invalid("no captions in range") }
        try swap.commit(edits, in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Classic caption style: `timeline.captionAttributes` (`docs/specs/captions.md` §1). Nil fields are
/// left as they are. Colours are RGBA 0–255; `fontSize` px at canvas resolution [inf].
public struct CaptionStyle: Sendable, Equatable {
    public var enabled: Bool?
    public var fontName: String?
    public var fontSize: Double?
    /// `defaultFontSize`: the size is automatic [inf].
    public var defaultFontSize: Bool?
    public var foregroundColor: [Int]?
    public var backgroundColor: [Int]?
    public var backgroundEnabled: Bool?
    public var backgroundOnlyAroundText: Bool?
    /// 0 = centre [inf]; other values [?].
    public var alignment: Int?
    /// ISO 639-1, e.g. `"en"`, `"bn"`.
    public var lang: String?

    public init(enabled: Bool? = nil, fontName: String? = nil, fontSize: Double? = nil, defaultFontSize: Bool? = nil,
                foregroundColor: [Int]? = nil, backgroundColor: [Int]? = nil, backgroundEnabled: Bool? = nil,
                backgroundOnlyAroundText: Bool? = nil, alignment: Int? = nil, lang: String? = nil) {
        self.enabled = enabled; self.fontName = fontName; self.fontSize = fontSize; self.defaultFontSize = defaultFontSize
        self.foregroundColor = foregroundColor; self.backgroundColor = backgroundColor
        self.backgroundEnabled = backgroundEnabled; self.backgroundOnlyAroundText = backgroundOnlyAroundText
        self.alignment = alignment; self.lang = lang
    }

    /// The project's style; missing keys stay nil.
    @MainActor public init(project: Project) {
        let o = project.root["timeline"]?.object?["captionAttributes"]?.object
        func ints(_ k: String) -> [Int]? { o?[k]?.array?.items.compactMap { $0.int.map(Int.init) } }
        self.init(enabled: o?["enabled"]?.bool, fontName: o?["fontName"]?.string, fontSize: o?["fontSize"]?.double,
                  defaultFontSize: o?["defaultFontSize"]?.bool, foregroundColor: ints("foregroundColor"),
                  backgroundColor: ints("backgroundColor"), backgroundEnabled: o?["backgroundEnabled"]?.bool,
                  backgroundOnlyAroundText: o?["backgroundOnlyAroundText"]?.bool,
                  alignment: o?["alignment"]?.int.map(Int.init), lang: o?["lang"]?.string)
    }

    /// Non-nil fields as `(key, value)` in Camtasia's key order [obs].
    var entries: [(String, JSON)] {
        func num(_ v: Double) -> JSON { v == v.rounded() && abs(v) < 1e15 ? J.int(Int64(v)) : J.dbl(v) }
        func rgba(_ v: [Int]) -> JSON { J.arr(v.map { J.int(Int64(min(max($0, 0), 255))) }) }
        var e: [(String, JSON?)] = [
            ("enabled", enabled.map(JSON.bool)), ("fontName", fontName.map(J.str)), ("fontSize", fontSize.map(num)),
            ("backgroundColor", backgroundColor.map(rgba)), ("foregroundColor", foregroundColor.map(rgba)),
            ("lang", lang.map(J.str)), ("alignment", alignment.map { J.int(Int64($0)) }),
            ("defaultFontSize", defaultFontSize.map(JSON.bool)),
        ]
        e += [("backgroundEnabled", backgroundEnabled.map(JSON.bool)),
              ("backgroundOnlyAroundText", backgroundOnlyAroundText.map(JSON.bool))]
        return e.compactMap { k, v in v.map { (k, $0) } }
    }
}

/// Sets `timeline.captionAttributes` fields (creating the object, after `parameters` [obs order],
/// when missing). Unchanged values keep their lexemes; new keys are appended. Revert is byte-identical.
@MainActor public final class SetCaptionStyle: EditCommand {
    public let name = "Change Caption Style"
    public let style: CaptionStyle
    private var swap = Swap()

    public init(_ style: CaptionStyle) { self.style = style }

    public func apply(to project: Project) throws {
        guard let timeline = project.root["timeline"]?.object else { throw EditError.invalid("no timeline") }
        let attrs = timeline["captionAttributes"]?.object?.copy() ?? JSONObject()
        for (k, v) in style.entries where !(attrs[k] == v || (attrs[k]?.double != nil && attrs[k]?.double == v.double)) {
            attrs[k] = v
        }
        let path = TreePath(steps: [.key("timeline"), .key("captionAttributes")])
        if let old = timeline["captionAttributes"], old == .object(attrs) { throw EditError.invalid("style unchanged") }
        if timeline["captionAttributes"] == nil {
            let next = timeline.keys.firstIndex(of: "parameters").flatMap { timeline.keys.indices.contains($0 + 1) ? timeline.keys[$0 + 1] : nil }
            let new = withKey(timeline, setting: "captionAttributes", to: .object(attrs), before: next)
            try swap.commit([(TreePath(steps: [.key("timeline")]), .object(new))], in: project)
        } else {
            try swap.commit([(path, .object(attrs))], in: project)
        }
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
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
