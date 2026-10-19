import Foundation

/// Clip `_type` values observed in project format versions 2.0–10.0.
public enum ClipKind: Equatable {
    /// Video stream of a source file.
    case video          // VMFile
    /// Video stream of a Camtasia screen recording (`.trec`); carries cursor data.
    case screenVideo    // ScreenVMFile
    /// Audio stream of a source file.
    case audio          // AMFile
    /// Still image.
    case image          // IMFile
    /// Linked video + audio pair (`video`, `audio` children) moved as one.
    case unified        // UnifiedMedia
    /// Several cut segments of the same source joined into one clip (`medias`).
    case stitched       // StitchedMedia
    /// Nested timeline with its own `tracks`.
    case group          // Group
    /// Annotation: shape, text, arrow, blur… (`def`).
    case callout        // Callout
    case other(String)

    public init(_ type: String) {
        switch type {
        case "VMFile": self = .video
        case "ScreenVMFile": self = .screenVideo
        case "AMFile": self = .audio
        case "IMFile": self = .image
        case "UnifiedMedia": self = .unified
        case "StitchedMedia": self = .stitched
        case "Group": self = .group
        case "Callout": self = .callout
        default: self = .other(type)
        }
    }

    public var typeName: String {
        switch self {
        case .video: "VMFile"
        case .screenVideo: "ScreenVMFile"
        case .audio: "AMFile"
        case .image: "IMFile"
        case .unified: "UnifiedMedia"
        case .stitched: "StitchedMedia"
        case .group: "Group"
        case .callout: "Callout"
        case .other(let s): s
        }
    }
}

/// View over one clip object (`medias[]` entry, or a `video`/`audio` child).
/// Reads and writes go straight to the underlying JSON.
public struct Clip {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public var id: Int64 { object["id"]?.int ?? -1 }
    public var kind: ClipKind { ClipKind(object["_type"]?.string ?? "") }

    /// `sourceBin` id this clip plays, if it plays a file.
    public var sourceID: Int64? { object["src"]?.int }

    /// Track inside the source file (0 = video, 1 = audio for typical media).
    public var sourceTrackNumber: Int64? { object["trackNumber"]?.int }

    public var name: String? { object["attributes"]?.object?["ident"]?.string }

    // MARK: Timing — all in project ticks (see `Timebase`).

    /// Position on the parent track.
    public var start: Int64 {
        get { object["start"]?.int ?? 0 }
        nonmutating set { object["start"] = .number(JSONNumber(newValue)) }
    }

    /// Length on the timeline.
    public var duration: Int64 {
        get { object["duration"]?.int ?? 0 }
        nonmutating set { object["duration"] = .number(JSONNumber(newValue)) }
    }

    public var end: Int64 { start + duration }

    /// In-point inside the source media, in project ticks.
    public var mediaStart: Rational {
        get { Rational(object["mediaStart"]) ?? Rational(0) }
        nonmutating set { object["mediaStart"] = newValue.json }
    }

    /// Source length consumed. Differs from `duration` when speed ≠ 1.
    public var mediaDuration: Rational {
        get { Rational(object["mediaDuration"]) ?? Rational(duration) }
        nonmutating set { object["mediaDuration"] = newValue.json }
    }

    /// Media-to-timeline factor: `mediaDuration * scalar == duration`, so
    /// `scalar = 1 / speed` (a 2× clip has scalar `1/2`). `1` normally; a
    /// fraction like `"304/457"` (≈1.5× speed) after a clip-speed change.
    public var scalar: Rational {
        get { Rational(object["scalar"]) ?? Rational(1) }
        nonmutating set { object["scalar"] = newValue.json }
    }

    /// Source time (ticks) for a timeline time inside this clip.
    public func mediaTime(atTimeline t: Int64) -> Rational {
        let local = Rational(t - start)
        let m = local / scalar
        return Rational(m.num * mediaStart.den + mediaStart.num * m.den, m.den * mediaStart.den)
    }

    public func contains(_ t: Int64) -> Bool { t >= start && t < end }

    // MARK: Content

    /// Read-only view of `parameters`. Never mutates the clip: when the key is
    /// missing this is an empty, detached view. Use `editableParameters` to write.
    public var parameters: Parameters {
        Parameters(object["parameters"]?.object ?? JSONObject())
    }

    /// `parameters` for writing; inserts an empty `parameters` object if missing.
    public var editableParameters: Parameters {
        if let o = object["parameters"]?.object { return Parameters(o) }
        let o = JSONObject()
        object["parameters"] = .object(o)
        return Parameters(o)
    }

    public var effects: [Effect] {
        object["effects"]?.array?.items.compactMap(\.object).map(Effect.init) ?? []
    }

    public var attributes: JSONObject? { object["attributes"]?.object }
    public var metadata: JSONObject? { object["metadata"]?.object }

    /// `animationTracks.visual`: segments that drive the parameter keyframes.
    public var visualAnimations: [JSONObject] {
        object["animationTracks"]?.object?["visual"]?.array?.items.compactMap(\.object) ?? []
    }

    /// For `.unified`: the linked video half.
    public var video: Clip? { object["video"]?.object.map(Clip.init) }
    /// For `.unified`: the linked audio half.
    public var audio: Clip? { object["audio"]?.object.map(Clip.init) }

    /// For `.stitched`: segments in order. Their `start` is relative to this clip.
    public var segments: [Clip] {
        object["medias"]?.array?.items.compactMap(\.object).map(Clip.init) ?? []
    }

    /// For `.group`: nested tracks. Clip times inside are relative to the group.
    public var tracks: [Track] {
        object["tracks"]?.array?.items.compactMap(\.object).map(Track.init) ?? []
    }

    /// For `.callout`: shape/text definition.
    public var callout: Callout? { object["def"]?.object.map(Callout.init) }

    /// Direct children of any container kind, in play order.
    public var children: [Clip] {
        switch kind {
        case .unified: [video, audio].compactMap { $0 }
        case .stitched: segments
        case .group: tracks.flatMap(\.clips)
        default: []
        }
    }

    /// Visits this clip and every nested clip, depth-first.
    public func walk(_ visit: (Clip, Int) -> Void, depth: Int = 0) {
        visit(self, depth)
        for c in children { c.walk(visit, depth: depth + 1) }
    }

    /// Every source id referenced by this clip or its descendants.
    public var referencedSourceIDs: Set<Int64> {
        var ids = Set<Int64>()
        walk { c, _ in if let s = c.sourceID { ids.insert(s) } }
        return ids
    }
}

/// One entry of a clip's `effects` array.
///
/// `effectName` is the identifier (e.g. `RoundCorners`, `DropShadow`, `Mask`,
/// `CursorPhysics`, `VSTEffect-DFN3NoiseRemoval`). Entries named `dummy` are
/// placeholders that only carry `start`/`duration`.
public struct Effect {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public var name: String { object["effectName"]?.string ?? "" }
    public var category: String? { object["category"]?.string }
    public var bypassed: Bool { object["bypassed"]?.bool ?? false }
    public var parameters: Parameters? { object["parameters"]?.object.map(Parameters.init) }
    public var isPlaceholder: Bool { name == "dummy" }
}

/// View over a callout's `def`.
public struct Callout {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    /// `remix` (modern shapes), `text`, … .
    public var kind: String? { object["kind"]?.string }
    /// e.g. `speech-bubble2`, `shape-rectangle`, `text`.
    public var shape: String? { object["shape"]?.string }
    public var style: String? { object["style"]?.string }
    public var text: String? { object["text"]?.string }
    public var width: Double { object["width"]?.double ?? 0 }
    public var height: Double { object["height"]?.double ?? 0 }

    /// RGBA 0…1 from the `<prefix>-red/green/blue/opacity` key family.
    public func color(_ prefix: String) -> (r: Double, g: Double, b: Double, a: Double) {
        (object["\(prefix)-red"]?.double ?? 0, object["\(prefix)-green"]?.double ?? 0,
         object["\(prefix)-blue"]?.double ?? 0, object["\(prefix)-opacity"]?.double ?? 1)
    }

    public var fontName: String? { object["font"]?.object?["name"]?.string }
    public var fontSize: Double? { object["font"]?.object?["size"]?.double }
}
