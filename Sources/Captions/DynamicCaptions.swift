import Foundation
import TSCProjKit
import TimelineEngine

/// A dynamic-caption gallery preset: everything `AddDynamicCaption` writes into a new callout
/// (`docs/specs/captions.md` §3, "CA2 results"). Box size and position are callout px for a
/// 1080-px-high canvas (other canvas heights scale them proportionally [WizRec]); font sizes are
/// points (= callout px at scale 1); colours 0–1.
public struct DynamicCaptionPreset: Sendable, Equatable {
    /// `dynamic-caption-preset-ID`, e.g. `"blockPreset8"`.
    public var presetID: String
    /// `dynamic-caption-display-name`: the gallery name.
    public var displayName: String
    /// The `dynamic-caption-*` style keys.
    public var style: DynamicCaptionStyle
    /// The visible font: the `textAttributes` runs decide font, size and colour [inf, strong].
    public var fontName: String
    public var fontSize: Double
    /// CSS weight of the `fontWeight` run.
    public var fontWeight: Int
    /// `kerning` run, em.
    public var kerning: Double
    public var textColor: CaptionColor
    /// `def.font`, a leftover default Camtasia leaves at Bebas Neue 128 Regular in every preset [obs].
    public var defFontName = "Bebas Neue"
    public var defFontSize = 128.0
    public var defFontWeight = "Regular"
    /// Glyph outline width, px, and colour.
    public var textStrokeWidth: Double
    public var textStrokeColor: CaptionColor
    /// `hasDropShadow` (0/1); nil = the key is absent (as in "Bangers Single Line") [obs].
    public var hasDropShadow: Double?
    /// Box `width` × `height`, px at a 1080-px canvas; the height carries the line count [inf].
    public var boxWidth: Double
    public var boxHeight: Double
    /// `translation1` (vertical position, +y up), px at a 1080-px canvas [obs per preset; rule [?]].
    public var translationY: Double
    /// `resize-behavior`; Camtasia 2026 writes `"resizeCallout"` [obs CA2] (CP1: `"resizeText"`).
    public var resizeBehavior = "resizeCallout"

    public init(presetID: String, displayName: String, style: DynamicCaptionStyle, fontName: String, fontSize: Double,
                fontWeight: Int, kerning: Double, textColor: CaptionColor, textStrokeWidth: Double,
                textStrokeColor: CaptionColor, hasDropShadow: Double?, boxWidth: Double, boxHeight: Double,
                translationY: Double) {
        self.presetID = presetID; self.displayName = displayName; self.style = style
        self.fontName = fontName; self.fontSize = fontSize; self.fontWeight = fontWeight; self.kerning = kerning
        self.textColor = textColor; self.textStrokeWidth = textStrokeWidth; self.textStrokeColor = textStrokeColor
        self.hasDropShadow = hasDropShadow; self.boxWidth = boxWidth; self.boxHeight = boxHeight
        self.translationY = translationY
    }

    /// "Arial 2 Line Dark Background" (`blockPreset8`) [obs CA2]: Arial 96/400, words appear as
    /// spoken (future opacity 0), 60 % black block background, no word box, no outline.
    public static var arial2LineDarkBackground: DynamicCaptionPreset {
        var s = DynamicCaptionStyle()
        s.backgroundFillColor = CaptionColor(0, 0, 0, 0.6)
        s.backgroundCornerRadius = 24
        s.currentWordEnabled = false
        s.futureWordOpacity = 0
        s.wordRectangleColor = CaptionColor(1, 1, 1, 0)
        s.currentWordStrokeColor.a = 0
        s.wordRectangleCornerRadius = 6
        return DynamicCaptionPreset(presetID: "blockPreset8", displayName: "Arial 2 Line Dark Background", style: s,
                                    fontName: "Arial", fontSize: 96, fontWeight: 400, kerning: -0.02,
                                    textColor: CaptionColor(1, 1, 1, 1), textStrokeWidth: 0,
                                    textStrokeColor: CaptionColor(0, 0, 0, 0.4), hasDropShadow: 0,
                                    boxWidth: 1280, boxHeight: 288, translationY: -396)
    }

    /// "Bangers Single Line" (`blockPreset1`) [obs CA2]: Bangers 96/400, blue box behind the current
    /// word, 8 px black outline, one line.
    public static var bangersSingleLine: DynamicCaptionPreset {
        var s = DynamicCaptionStyle()
        s.backgroundFillColor = CaptionColor(0, 0, 0, 0)
        s.backgroundCornerRadius = 25.6
        s.currentWordEnabled = false
        s.futureWordOpacity = 1
        s.wordRectangleColor = CaptionColor(0, 0.333, 0.98, 1)
        s.currentWordStrokeColor.a = 1
        s.wordRectangleCornerRadius = 6
        return DynamicCaptionPreset(presetID: "blockPreset1", displayName: "Bangers Single Line", style: s,
                                    fontName: "Bangers", fontSize: 96, fontWeight: 400, kerning: 0,
                                    textColor: CaptionColor(1, 1, 1, 1), textStrokeWidth: 8,
                                    textStrokeColor: CaptionColor(0, 0, 0, 1), hasDropShadow: nil,
                                    boxWidth: 1280, boxHeight: 150, translationY: -457)
    }

    /// The presets WizRec offers, in gallery order.
    public static var all: [DynamicCaptionPreset] { [arial2LineDarkBackground, bangersSingleLine] }
}

/// Dynamic captions: `Callout`s with `def.modifier == "dynamicCaption"` (`docs/specs/captions.md`
/// §3) that show the transcription of the audio playing at the same timeline time.
@MainActor
public enum DynamicCaptions {
    /// Placeholder `def.text` (CP1's value [obs]; what Camtasia 2026 writes there is unrecorded).
    static let placeholder = "ABC"

    /// The callout's `def` (keys in the order Camtasia writes them: kind/shape/style, numbers
    /// alphabetically, strings alphabetically, then `font` and `textAttributes` [obs, CP1/CA2]).
    static func def(_ p: DynamicCaptionPreset, width: Double, height: Double) -> JSONObject {
        var numbers: [(String, Double)] = p.style.numericEntries.map { ("dynamic-caption-" + $0.0, $0.1) }
        numbers += [("corner-radius", 6.0), ("enable-ligatures", 1.0), ("height", height), ("line-spacing", 0.0),
                    ("text-stroke-alignment", 2.0), ("text-stroke-color-alpha", p.textStrokeColor.a),
                    ("text-stroke-color-blue", p.textStrokeColor.b), ("text-stroke-color-green", p.textStrokeColor.g),
                    ("text-stroke-color-red", p.textStrokeColor.r), ("text-stroke-width", p.textStrokeWidth),
                    ("tracking", 0.0), ("width", width), ("word-wrap", 1.0)]
        if let d = p.hasDropShadow { numbers.append(("hasDropShadow", d)) }
        var strings: [(String, String)] = p.style.stringEntries.map { ("dynamic-caption-" + $0.0, $0.1) }
        strings += [("dynamic-caption-display-name", p.displayName), ("dynamic-caption-preset-ID", p.presetID),
                    ("horizontal-alignment", "center"), ("modifier", "dynamicCaption"),
                    ("resize-behavior", p.resizeBehavior), ("text", placeholder), ("vertical-alignment", "center")]
        var pairs: [(String, JSON)] = [("kind", J.str("remix")), ("shape", J.str("text")), ("style", J.str("caption"))]
        pairs += numbers.sorted { $0.0 < $1.0 }.map { ($0.0, J.dbl($0.1)) }
        pairs += strings.sorted { $0.0 < $1.0 }.map { ($0.0, J.str($0.1)) }
        let c = p.textColor
        pairs.append(("font", J.obj([("color-blue", J.dbl(c.b)), ("color-green", J.dbl(c.g)), ("color-opacity", J.dbl(c.a)),
                                     ("color-red", J.dbl(c.r)), ("size", J.dbl(p.defFontSize)), ("name", J.str(p.defFontName)),
                                     ("weight", J.str(p.defFontWeight))])))
        let n = Int64(placeholder.utf16.count)
        func run(_ name: String, _ v: JSON, _ type: String) -> JSON {
            J.obj([("name", J.str(name)), ("rangeEnd", J.int(n)), ("rangeStart", J.int(0)), ("value", v), ("valueType", J.str(type))])
        }
        func byte(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        let fg = "(\(byte(c.r)),\(byte(c.g)),\(byte(c.b)),\(byte(c.a)))"
        let runs = J.arr([
            run("fontItalic", J.int(0), "int"), run("kerning", J.dbl(p.kerning), "double"),
            run("fontWeight", J.int(Int64(p.fontWeight)), "int"), run("underline", J.int(0), "int"),
            run("fontName", J.str(p.fontName), "string"), run("fgColor", J.str(fg), "color"),
            run("fontSize", J.dbl(p.fontSize), "double"), run("strikethrough", J.int(0), "int"),
        ])
        pairs.append(("textAttributes", J.obj([("type", J.str("textAttributeList")), ("keyframes", J.arr([
            J.obj([("endTime", J.int(0)), ("time", J.int(0)), ("value", runs), ("duration", J.int(0))]),
        ]))])))
        return JSONObject(pairs)
    }

    /// A whole dynamic-caption `Callout` clip: `start`/`duration` ticks, `mediaStart` 0,
    /// `parameters` only `translation1` and the four `geometryCrop*` [obs CA2].
    static func callout(id: Int64, start: Int64, duration: Int64, preset p: DynamicCaptionPreset,
                        canvasHeight: Double) -> JSONObject {
        // Rounded to 1/1000 px so float noise never reaches the file.
        func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        let k = canvasHeight > 0 ? canvasHeight / 1080 : 1
        return JSONObject([
            ("id", J.int(id)), ("_type", J.str("Callout")),
            ("def", .object(def(p, width: r(p.boxWidth * k), height: r(p.boxHeight * k)))),
            ("attributes", J.obj([("ident", J.str("")), ("autoRotateText", .bool(true))])),
            ("parameters", J.obj([("translation1", J.dbl(r(p.translationY * k))), ("geometryCrop0", J.dbl(0)),
                                  ("geometryCrop1", J.dbl(0)), ("geometryCrop2", J.dbl(0)), ("geometryCrop3", J.dbl(0))])),
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
        CaptionBlockRules(def: def)
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

/// Modify ▸ Add Dynamic Caption Style (`docs/specs/captions.md` §3, CA2 [obs]): a new
/// dynamic-caption callout **60 s long starting at the playhead**, whatever the audio's length,
/// with `mediaStart` 0, on a **new track above all others**. Applying a style again adds another
/// callout on another new track; it never restyles an existing one. No key links the callout to an
/// audio clip [obs]; renderers pair them by timeline time. Camtasia also transcribes the audio's
/// source at this point: callers run `ApplyTranscription` first when the source has none.
///
/// `track`: an existing top-level track free over the callout's span instead of a new one. The
/// callout id is `Project.maxID + 1` (`calloutID` after apply). Revert is byte-identical.
@MainActor public final class AddDynamicCaption: EditCommand {
    public let name = "Add Dynamic Captions"
    /// Callout length, seconds [obs CA2].
    public static let durationSeconds: Int64 = 60
    /// Playhead, timeline seconds (nil when built from `audioClipID`).
    public let playhead: Double?
    /// Convenience: start at this top-level audio clip's start; it must be transcribed.
    public let audioClipID: Int64?
    public let track: Int?
    public let preset: DynamicCaptionPreset
    public private(set) var calloutID: Int64?
    private var addTrack: AddTrack?
    private var swap = Swap()

    /// A callout at `playhead` (timeline seconds, rounded to the nearest output frame).
    public init(at playhead: Double, preset: DynamicCaptionPreset = .arial2LineDarkBackground, track: Int? = nil) {
        self.playhead = playhead; self.audioClipID = nil; self.track = track; self.preset = preset
    }

    /// A callout starting where top-level audio clip `audioClipID` starts; throws when that clip's
    /// source track has no transcription.
    public init(audioClipID: Int64, track: Int? = nil, preset: DynamicCaptionPreset = .arial2LineDarkBackground) {
        self.playhead = nil; self.audioClipID = audioClipID; self.track = track; self.preset = preset
    }

    public func apply(to project: Project) throws {
        let start: Int64
        if let id = audioClipID {
            guard let car = ClassicCaptions.carriers(project).first(where: { $0.clip.clip.id == id }) else {
                throw EditError.invalid("clip \(id) is not a top-level audio clip")
            }
            guard DynamicCaptions.audioWords(car, project) != nil else {
                throw EditError.invalid("clip \(id) has no transcription")
            }
            start = car.start
        } else {
            start = Tree.ticks(playhead ?? 0, project)
        }
        let duration = project.timebase.editRate * Self.durationSeconds
        let end = start + duration
        var trackIndex: Int
        if let t = track {
            let tracks = Tree.topTracks(project)
            guard tracks.indices.contains(t) else { throw EditError.trackNotFound(t) }
            let busy = (tracks[t].track["medias"]?.array?.items ?? []).compactMap(\.object).map(Clip.init)
                .contains { $0.start < end && $0.end > start }
            guard !busy else { throw EditError.invalid("track \(t) is not free over the caption") }
            trackIndex = t
        } else {
            trackIndex = Tree.topTracks(project).count
            let add = AddTrack(at: trackIndex)
            try add.apply(to: project)
            addTrack = add
        }
        do {
            let id = project.maxID + 1
            let callout = DynamicCaptions.callout(id: id, start: start, duration: duration, preset: preset,
                                                  canvasHeight: project.height)
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

    /// Sets `key`. A new key goes right after the largest key of the same JSON kind (number or
    /// string) that sorts before it, else before the smallest one that sorts after it, else at the
    /// end. That keeps Camtasia's alphabetical runs intact (`kind`/`shape`/`style` lead the `def`
    /// out of order, so "the first key that sorts after" would put a new string key before `kind`).
    static func set(_ o: JSONObject, _ key: String, _ v: JSON) -> JSONObject {
        if let old = o[key] {
            // Keep the number lexeme when the value is unchanged.
            if old == v || (old.double == v.double && v.double != nil) { return o }
            o[key] = v; return o
        }
        let sameKind: (JSON) -> Bool = { j in v.string != nil ? j.string != nil : j.number != nil }
        let peers = o.entries.filter { sameKind($0.value) }.map(\.key)
        if let pred = peers.filter({ $0 < key }).max(), let i = o.keys.firstIndex(of: pred) {
            return withKey(o, setting: key, to: v, before: o.keys.indices.contains(i + 1) ? o.keys[i + 1] : nil)
        }
        return withKey(o, setting: key, to: v, before: peers.filter { $0 > key }.min())
    }
}
