import Foundation
import TSCProjKit
import TimelineEngine

/// Look and box of a new dynamic caption. Units: callout px (= canvas px at scale 1), seconds.
public struct DynamicCaptionAppearance: Sendable, Equatable {
    public var style = DynamicCaptionStyle()
    public var fontName = "Arial"
    /// `font.size` and the runs' `fontSize`, points (= callout px at scale 1).
    public var fontSize = 72.0
    /// CSS weight written to the `fontWeight` run.
    public var fontWeight = 700
    public var textColor = CaptionColor(1, 1, 1, 1)
    public var textStrokeWidth = 3.84
    public var textStrokeColor = CaptionColor(0, 0, 0, 1)
    /// Box size as fractions of the canvas.
    public var widthFraction = 0.9
    public var heightFraction = 0.2
    /// Gap between the box's bottom edge and the canvas bottom, fraction of the canvas height.
    public var bottomMargin = 0.05
    public init() {}
}

/// Dynamic captions: `Callout`s with `def.modifier == "dynamicCaption"` (`docs/specs/captions.md`
/// §3) that show the transcription of the audio playing at the same timeline time.
@MainActor
public enum DynamicCaptions {
    /// The callout's `def` (keys in the order Camtasia writes them: kind/shape/style, numbers
    /// alphabetically, strings alphabetically, then `font` and `textAttributes` [obs, CP1]).
    /// `text` is the first block's text (CP1 holds a placeholder there; its role is [?]).
    static func def(_ a: DynamicCaptionAppearance, width: Double, height: Double, text: String) -> JSONObject {
        var numbers: [(String, Double)] = a.style.numericEntries.map { ("dynamic-caption-" + $0.0, $0.1) }
        numbers += [("corner-radius", 6.0), ("enable-ligatures", 1.0), ("height", height), ("line-spacing", 0.0),
                    ("text-stroke-alignment", 2.0), ("text-stroke-color-alpha", a.textStrokeColor.a),
                    ("text-stroke-color-blue", a.textStrokeColor.b), ("text-stroke-color-green", a.textStrokeColor.g),
                    ("text-stroke-color-red", a.textStrokeColor.r), ("text-stroke-width", a.textStrokeWidth),
                    ("tracking", 0.0), ("width", width), ("word-wrap", 1.0)]
        var strings: [(String, String)] = a.style.stringEntries.map { ("dynamic-caption-" + $0.0, $0.1) }
        strings += [("horizontal-alignment", "center"), ("modifier", "dynamicCaption"), ("resize-behavior", "resizeText"),
                    ("text", text), ("vertical-alignment", "center")]
        var pairs: [(String, JSON)] = [("kind", J.str("remix")), ("shape", J.str("text")), ("style", J.str("caption"))]
        pairs += numbers.sorted { $0.0 < $1.0 }.map { ($0.0, J.dbl($0.1)) }
        pairs += strings.sorted { $0.0 < $1.0 }.map { ($0.0, J.str($0.1)) }
        let c = a.textColor
        pairs.append(("font", J.obj([("color-blue", J.dbl(c.b)), ("color-green", J.dbl(c.g)), ("color-opacity", J.dbl(c.a)),
                                     ("color-red", J.dbl(c.r)), ("size", J.dbl(a.fontSize)), ("name", J.str(a.fontName)),
                                     ("weight", J.str("Regular"))])))
        let n = Int64(text.utf16.count)
        func run(_ name: String, _ v: JSON, _ type: String) -> JSON {
            J.obj([("name", J.str(name)), ("rangeEnd", J.int(n)), ("rangeStart", J.int(0)), ("value", v), ("valueType", J.str(type))])
        }
        func byte(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        let fg = "(\(byte(c.r)),\(byte(c.g)),\(byte(c.b)),\(byte(c.a)))"
        let runs: JSON = n == 0 ? .null : J.arr([
            run("fontItalic", J.int(0), "int"), run("kerning", J.dbl(0), "double"),
            run("fontWeight", J.int(Int64(a.fontWeight)), "int"), run("underline", J.int(0), "int"),
            run("fontName", J.str(a.fontName), "string"), run("fgColor", J.str(fg), "color"),
            run("fontSize", J.dbl(a.fontSize), "double"), run("strikethrough", J.int(0), "int"),
        ])
        pairs.append(("textAttributes", J.obj([("type", J.str("textAttributeList")), ("keyframes", J.arr([
            J.obj([("endTime", J.int(0)), ("time", J.int(0)), ("value", runs), ("duration", J.int(0))]),
        ]))])))
        return JSONObject(pairs)
    }

    /// A whole dynamic-caption `Callout` clip.
    static func callout(id: Int64, start: Int64, duration: Int64, appearance a: DynamicCaptionAppearance,
                        canvas: (w: Double, h: Double), text: String) -> JSONObject {
        let w = canvas.w * a.widthFraction, h = canvas.h * a.heightFraction
        let y = -(canvas.h / 2) + canvas.h * a.bottomMargin + h / 2
        return JSONObject([
            ("id", J.int(id)), ("_type", J.str("Callout")),
            ("def", .object(def(a, width: w, height: h, text: text))),
            ("attributes", J.obj([("ident", J.str("")), ("autoRotateText", .bool(true))])),
            ("parameters", J.obj([("translation1", J.dbl(y)), ("geometryCrop0", J.dbl(0)), ("geometryCrop1", J.dbl(0)),
                                  ("geometryCrop2", J.dbl(0)), ("geometryCrop3", J.dbl(0))])),
            ("effects", J.arr([])),
            ("start", J.int(start)), ("duration", J.int(duration)), ("mediaStart", J.int(0)),
            ("mediaDuration", J.int(duration)), ("scalar", J.int(1)),
            ("metadata", J.obj([("audiateLinkedSession", J.str("")), ("clipSpeedAttribute", J.typedBool(false)),
                                ("colorAttribute", J.obj([("type", J.str("color")), ("value", J.arr([J.int(0), J.int(0), J.int(0), J.int(0)]))])),
                                ("effectApplied", J.str("none"))])),
            ("animationTracks", J.obj([])),
        ])
    }

    /// The audio clip's source track words and the clip's media → timeline mapping.
    struct AudioWords {
        let clip: Clip
        let words: [TranscriptWord]
        /// Timeline ticks for a source media time in seconds: `start + (m − mediaStart) × scalar`.
        func timeline(_ seconds: Double, _ tb: Timebase) -> Double {
            let m = seconds * Double(tb.editRate)
            return Double(clip.start) + (m - clip.mediaStart.double) * clip.scalar.double
        }
    }

    static func audioWords(_ c: ClassicCaptions.Carrier, _ project: Project) -> AudioWords? {
        let a = Clip(c.owner)
        guard let src = a.sourceID else { return nil }
        let w = Transcript.words(in: project, sourceID: src, track: Int(a.sourceTrackNumber ?? 0))
        return w.isEmpty ? nil : AudioWords(clip: Clip(c.clip.object), words: w)
    }

    /// Block rules for a dynamic-caption `def` (box width and base font size, see `CaptionBlockRules`).
    public static func rules(def: JSONObject) -> CaptionBlockRules {
        CaptionBlockRules(boxWidth: def["width"]?.double ?? 1728, fontSize: Callout(def).fontSize ?? 96,
                          style: DynamicCaptionStyle(def: def))
    }

    /// Every block of every top-level dynamic caption as a cue (timeline seconds, lines joined by
    /// `"\n"`), clipped to the callout and to the audio clip it reads from, sorted.
    public static func cues(in project: Project) -> [CaptionCue] {
        let tb = project.timebase
        let carriers = ClassicCaptions.carriers(project)
        var out: [CaptionCue] = []
        for tc in Tree.topClips(project) {
            guard tc.object["_type"]?.string == "Callout", let def = tc.object["def"]?.object,
                  DynamicCaptionStyle.isDynamicCaption(def) else { continue }
            let call = tc.clip
            for car in carriers where car.start < call.end && car.start + car.duration > call.start {
                guard let aw = audioWords(car, project) else { continue }
                let lo = Double(max(call.start, car.start)), hi = Double(min(call.end, car.start + car.duration))
                let blocks = DynamicCaptionLayout.blocks(aw.words, rules: rules(def: def))
                for b in blocks {
                    let s = max(lo, aw.timeline(b.start, tb)), e = min(hi, aw.timeline(b.end, tb))
                    guard e > s else { continue }
                    let text = DynamicCaptionLayout.text(of: b, words: aw.words)
                    out.append(CaptionCue(start: s / Double(tb.editRate), end: e / Double(tb.editRate), text: text))
                }
            }
        }
        return out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }
}

/// Adds one dynamic-caption callout spanning a top-level audio clip (`AMFile`, or a `UnifiedMedia`'s
/// audio) whose source track has a transcription (`ApplyTranscription`), like Camtasia's samples
/// (callout start/duration = the audio clip's [obs CP1]; `mediaStart` 0 — CP1's 0.2333 s is [?]).
/// No key links callout and audio [obs]; renderers pair them by timeline time.
///
/// `track`: an existing top-level track that is free over the clip's span, or nil for a new track
/// on top (via `AddTrack`). The callout id is `Project.maxID + 1` (`calloutID` after apply).
/// The box is placed at the bottom of the canvas. Revert is byte-identical.
@MainActor public final class AddDynamicCaption: EditCommand {
    public let name = "Add Dynamic Captions"
    public let audioClipID: Int64
    public let track: Int?
    public let appearance: DynamicCaptionAppearance
    public private(set) var calloutID: Int64?
    private var addTrack: AddTrack?
    private var swap = Swap()

    public init(audioClipID: Int64, track: Int? = nil, appearance: DynamicCaptionAppearance = .init()) {
        self.audioClipID = audioClipID; self.track = track; self.appearance = appearance
    }

    public func apply(to project: Project) throws {
        guard let car = ClassicCaptions.carriers(project).first(where: { $0.clip.clip.id == audioClipID }) else {
            throw EditError.invalid("clip \(audioClipID) is not a top-level audio clip")
        }
        guard let aw = DynamicCaptions.audioWords(car, project) else {
            throw EditError.invalid("clip \(audioClipID) has no transcription")
        }
        let start = car.start, end = car.start + car.duration
        var trackIndex: Int
        if let t = track {
            let tracks = Tree.topTracks(project)
            guard tracks.indices.contains(t) else { throw EditError.trackNotFound(t) }
            let busy = (tracks[t].track["medias"]?.array?.items ?? []).compactMap(\.object).map(Clip.init)
                .contains { $0.start < end && $0.end > start }
            guard !busy else { throw EditError.invalid("track \(t) is not free over the clip") }
            trackIndex = t
        } else {
            trackIndex = Tree.topTracks(project).count
            let add = AddTrack(at: trackIndex)
            try add.apply(to: project)
            addTrack = add
        }
        do {
            let id = project.maxID + 1
            let rules = CaptionBlockRules(boxWidth: project.width * appearance.widthFraction,
                                          fontSize: appearance.fontSize, style: appearance.style)
            let firstText = DynamicCaptionLayout.blocks(aw.words, rules: rules).first
                .map { DynamicCaptionLayout.text(of: $0, words: aw.words).replacingOccurrences(of: "\n", with: " ") } ?? ""
            let callout = DynamicCaptions.callout(id: id, start: start, duration: end - start, appearance: appearance,
                                                  canvas: (project.width, project.height), text: firstText)
            let mediasPath = TreePath.sceneTracks.appending(.index(trackIndex), .key("medias"))
            var items = (mediasPath.resolve(in: project.root)?.array?.items ?? []).map { $0.copy() }
            let at = items.firstIndex { ($0.object.map(Clip.init)?.start ?? 0) > start } ?? items.count
            items.insert(.object(callout), at: at)
            try swap.commit([(mediasPath, J.arr(items))], in: project)
            calloutID = id
        } catch {
            if let add = addTrack { try? add.revert(on: project); addTrack = nil }
            throw error
        }
    }

    public func revert(on project: Project) throws {
        try swap.restore(in: project)
        if let add = addTrack { try add.revert(on: project); addTrack = nil }
        calloutID = nil
    }
}

/// Replaces the `dynamic-caption-*` keys of a dynamic-caption callout (other `def` keys untouched;
/// keys missing before are inserted in alphabetical position among the numeric/string keys).
/// Revert is byte-identical.
@MainActor public final class SetDynamicCaptionStyle: EditCommand {
    public let name = "Change Caption Style"
    public let clipID: Int64
    public let style: DynamicCaptionStyle
    private var swap = Swap()

    public init(clipID: Int64, style: DynamicCaptionStyle) { self.clipID = clipID; self.style = style }

    public func apply(to project: Project) throws {
        guard let tc = Tree.topClips(project).first(where: { $0.clip.id == clipID }),
              let def = tc.object["def"]?.object, DynamicCaptionStyle.isDynamicCaption(def) else {
            throw EditError.invalid("clip \(clipID) is not a top-level dynamic caption")
        }
        var new = def.copy()
        for (k, v) in style.numericEntries { new = Self.set(new, "dynamic-caption-" + k, J.dbl(v)) }
        for (k, v) in style.stringEntries { new = Self.set(new, "dynamic-caption-" + k, J.str(v)) }
        try swap.commit([(tc.path.appending(.key("def")), .object(new))], in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }

    /// Sets `key`; a new key goes before the first key of the same JSON kind that sorts after it.
    static func set(_ o: JSONObject, _ key: String, _ v: JSON) -> JSONObject {
        if let old = o[key] {
            // Keep the number lexeme when the value is unchanged.
            if old.double == v.double, v.double != nil { return o }
            o[key] = v; return o
        }
        let sameKind: (JSON) -> Bool = { j in v.string != nil ? j.string != nil : j.number != nil }
        let before = o.entries.first { sameKind($0.value) && $0.key > key }?.key
        return withKey(o, setting: key, to: v, before: before)
    }
}
