import Foundation
import TSCProjKit

// Small constructors for TSCProjKit's lossless JSON tree. Projects are only
// ever built and serialised through TSCProjKit (never Codable/JSONSerialization).
extension JSON {
    static func num(_ v: Int64) -> JSON { .number(JSONNumber(v)) }
    static func num(_ v: Int) -> JSON { .number(JSONNumber(v)) }
    static func dbl(_ v: Double) -> JSON { .number(JSONNumber(v)) }
    static func str(_ v: String) -> JSON { .string(v) }
    static func flag(_ v: Bool) -> JSON { .bool(v) }
    static func arr(_ v: [JSON]) -> JSON { .array(JSONArray(v)) }
    static func obj(_ pairs: KeyValuePairs<String, JSON>) -> JSON { .object(JSONObject(pairs.map { ($0.key, $0.value) })) }
    static var emptyObject: JSON { .object(JSONObject()) }
    static var emptyArray: JSON { .array(JSONArray()) }
}

/// One keyframe segment: the parameter moves from the previous value to `value`
/// across `[time, endTime]` (ticks on the clip's media time axis, the axis of
/// `mediaStart`; equal to "since clip start" when `mediaStart` is 0 and speed 1).
public struct KeyframeSpec: Sendable {
    public var time: Int64
    public var endTime: Int64
    public var value: Double
    /// `"linr"` or `"eioe"`.
    public var interp: String
    public init(time: Int64, endTime: Int64, value: Double, interp: String) {
        self.time = time; self.endTime = endTime; self.value = value; self.interp = interp
    }
}

/// A clip parameter: constant, or animated from `initial` through keyframes.
public enum ParamSpec: Sendable {
    case constant(Double)
    case animated(initial: Double, [KeyframeSpec])
}

/// Builds a format-10.0 Camtasia-compatible project (editRate 705600000).
///
/// Key names, order and shapes follow what Camtasia 2026 writes (learned from
/// the user's own projects): transform parameters as animatable objects with
/// `interp: "eioe"`, `animationTracks.visual` mirroring keyframe segments,
/// per-track UI state in `timeline.trackAttributes`.
public final class ProjectBuilder {
    /// Ticks per second.
    public let editRate: Int64 = 705_600_000
    /// Export / timeline frame rate, fps.
    public let fps: Int64
    /// Canvas size, px.
    public let width: Int, height: Int
    public var title: String
    /// Canvas background RGBA, 0–255.
    public var background: [Int64] = [0, 0, 0, 255]
    /// Top-level tracks, bottom (index 0) to top; each holds clip objects.
    public var tracks: [[JSONObject]] = []

    private var nextID: Int64 = 1
    private var sources: [JSON] = []
    private var timelineID: Int64?

    /// A `sourceBin` entry.
    public struct Source: Sendable {
        public let id: Int64
        /// Native size, px.
        public let width: Int, height: Int
        public let isImage: Bool
        public let name: String
    }

    public init(title: String, width: Int = 1920, height: Int = 1080, fps: Int64 = 30) {
        self.title = title; self.width = width; self.height = height; self.fps = fps
    }

    /// Ticks for `n` frames at the project frame rate.
    public func frames(_ n: Int64) -> Int64 { n * editRate / fps }

    private func takeID() -> Int64 { defer { nextID += 1 }; return nextID }

    /// Clip ids come after the sources and the timeline id, as in Camtasia's files.
    private func clipID() -> Int64 {
        if timelineID == nil { timelineID = takeID() }
        return takeID()
    }

    private static func stamp(_ date: Date, fraction: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fraction ? "yyyyMMdd'T'HHmmss.SSSSSS" : "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }

    /// Adds an H.264 movie (video stream only). `src` is the bundle-relative path (`./media/<ts>/x.mp4`).
    public func addVideoSource(src: String, movie: MediaWriter.MovieInfo, modified: Date = Date()) -> Source {
        precondition(timelineID == nil, "add all sources before clips")
        let id = takeID()
        let name = (src as NSString).lastPathComponent
        let frameUnits = Int64(movie.timescale) / Int64(movie.fps)
        let track = JSON.obj([
            "range": .arr([.num(0), .num(Int64(movie.frameCount) * frameUnits)]),
            "type": .num(0),
            "editRate": .num(Int64(movie.timescale)),
            "trackRect": .arr([.num(0), .num(0), .num(movie.width), .num(movie.height)]),
            "sampleRate": .num(movie.fps),
            "bitDepth": .num(24),
            "numChannels": .num(0),
            "integratedLUFS": .dbl(100),
            "peakLevel": .dbl(-1),
            "tag": .num(0),
            "metaData": .str("\(name);"),
            "parameters": .emptyObject,
        ])
        sources.append(sourceEntry(id: id, src: src, w: movie.width, h: movie.height, track: track, modified: modified))
        return Source(id: id, width: movie.width, height: movie.height, isImage: false, name: name)
    }

    /// Adds a still image (PNG). `src` is the bundle-relative path.
    public func addImageSource(src: String, width w: Int, height h: Int, modified: Date = Date()) -> Source {
        precondition(timelineID == nil, "add all sources before clips")
        let id = takeID()
        let name = (src as NSString).lastPathComponent
        let track = JSON.obj([
            "range": .arr([.num(0), .num(1)]),
            "type": .num(1),
            "editRate": .num(600),
            "trackRect": .arr([.num(0), .num(0), .num(w), .num(h)]),
            "sampleRate": .num(0),
            "bitDepth": .num(0),
            "numChannels": .num(0),
            "integratedLUFS": .dbl(100),
            "peakLevel": .dbl(-1),
            "tag": .num(0),
            "metaData": .str("\(name);"),
            "parameters": .emptyObject,
        ])
        sources.append(sourceEntry(id: id, src: src, w: w, h: h, track: track, modified: modified))
        return Source(id: id, width: w, height: h, isImage: true, name: name)
    }

    private func sourceEntry(id: Int64, src: String, w: Int, h: Int, track: JSON, modified: Date) -> JSON {
        .obj([
            "id": .num(id),
            "src": .str(src),
            "rect": .arr([.num(0), .num(0), .num(w), .num(h)]),
            "lastMod": .str(Self.stamp(modified, fraction: false)),
            "loudnessNormalization": .flag(true),
            "sourceTracks": .arr([track]),
            "metadata": .obj(["timeAdded": .str(Self.stamp(Date(), fraction: true))]),
        ])
    }

    // MARK: Parameters

    /// Order Camtasia uses for the keys we write.
    private static let paramOrder = [
        "translation0", "translation1", "translation2", "rotation2", "scale0", "scale1", "opacity",
        "sourceCrop0", "sourceCrop1", "sourceCrop2", "sourceCrop3",
        "geometryCrop0", "geometryCrop1", "geometryCrop2", "geometryCrop3",
    ]

    /// Builds a clip's `parameters` and its `animationTracks`.
    /// Geometry crops are always written (0 when absent), as Camtasia does.
    private func parameters(_ p: [String: ParamSpec]) -> (JSON, JSON) {
        var p = p
        for i in 0..<4 where p["geometryCrop\(i)"] == nil { p["geometryCrop\(i)"] = .constant(0) }
        let names = Self.paramOrder.filter { p[$0] != nil } + p.keys.filter { !Self.paramOrder.contains($0) }.sorted()
        let out = JSONObject()
        var segments: [KeyframeSpec] = []
        for name in names {
            guard let spec = p[name] else { continue }
            switch spec {
            case .constant(let v):
                out[name] = .obj(["type": .str("double"), "defaultValue": .dbl(v), "interp": .str("eioe")])
            case .animated(let initial, let kfs):
                // The first keyframe animates from `defaultValue` (time-mapping.md §6).
                var items: [JSON] = []
                for k in kfs {
                    items.append(.obj([
                        "endTime": .num(k.endTime), "time": .num(k.time), "value": .dbl(k.value),
                        "interp": .str(k.interp), "duration": .num(k.endTime - k.time),
                    ]))
                    segments.append(k)
                }
                out[name] = .obj([
                    "type": .str("double"), "defaultValue": .dbl(initial),
                    "interp": .str(kfs.first?.interp ?? "eioe"), "keyframes": .arr(items),
                ])
            }
        }
        // animationTracks.visual: one entry per distinct animated segment, by time.
        var seen = Set<String>()
        let visual: [JSON] = segments.sorted { ($0.time, $0.endTime) < ($1.time, $1.endTime) }.compactMap { k in
            let key = "\(k.time)-\(k.endTime)-\(k.interp)"
            guard seen.insert(key).inserted else { return nil }
            return .obj([
                "endTime": .num(k.endTime), "duration": .num(k.endTime - k.time),
                "range": .arr([.num(k.time), .num(k.endTime - k.time)]), "interp": .str(k.interp),
            ])
        }
        return (.object(out), visual.isEmpty ? .emptyObject : .obj(["visual": .arr(visual)]))
    }

    private func clipMetadata(speedChanged: Bool) -> JSON {
        .obj([
            "audiateLinkedSession": .str(""),
            "clipSpeedAttribute": .obj(["type": .str("bool"), "value": .flag(speedChanged)]),
            "colorAttribute": .obj(["type": .str("color"), "value": .arr([.num(0), .num(0), .num(0), .num(0)])]),
            "effectApplied": .str(speedChanged ? "Clip Speed" : "none"),
        ])
    }

    /// `mediaDuration = duration / scalar` (Camtasia: `mediaDuration × scalar = duration`).
    private static func mediaDuration(_ duration: Int64, scalar: Rational) -> Rational {
        Rational(duration) / scalar
    }

    // MARK: Clips

    /// A `VMFile` clip playing `src` from `mediaStart` (ticks).
    /// `scalar` = timeline/media: speed 2× is `Rational(1, 2)`.
    public func video(_ src: Source, start: Int64, duration: Int64, mediaStart: Int64 = 0,
                      scalar: Rational = Rational(1), params: [String: ParamSpec] = [:]) -> JSONObject {
        let id = clipID()
        let (ps, anim) = parameters(params)
        let speed = scalar != Rational(1)
        return JSONObject([
            ("id", .num(id)), ("_type", .str("VMFile")), ("src", .num(src.id)), ("trackNumber", .num(0)),
            ("attributes", .obj(["ident": .str((src.name as NSString).deletingPathExtension)])),
            ("parameters", ps), ("effects", .emptyArray),
            ("start", .num(start)), ("duration", .num(duration)),
            ("mediaStart", .num(mediaStart)), ("mediaDuration", Self.mediaDuration(duration, scalar: scalar).json),
            ("scalar", scalar.json), ("metadata", clipMetadata(speedChanged: speed)), ("animationTracks", anim),
        ])
    }

    /// An `IMFile` clip showing still image `src`.
    public func image(_ src: Source, start: Int64, duration: Int64, params: [String: ParamSpec] = [:]) -> JSONObject {
        let id = clipID()
        let (ps, anim) = parameters(params)
        return JSONObject([
            ("id", .num(id)), ("_type", .str("IMFile")), ("src", .num(src.id)), ("trackNumber", .num(0)),
            ("trimStartSum", .num(0)),
            ("attributes", .obj(["ident": .str((src.name as NSString).deletingPathExtension)])),
            ("parameters", ps), ("effects", .emptyArray),
            ("start", .num(start)), ("duration", .num(duration)),
            ("mediaStart", .num(0)), ("mediaDuration", .num(1)), ("scalar", .num(1)),
            ("metadata", clipMetadata(speedChanged: false)), ("animationTracks", anim),
        ])
    }

    /// A `Callout` clip with `def` (see `CalloutDef`); natural size `def.width × def.height` callout px.
    /// Key order follows Camtasia 2026's caption callouts [obs, DynamicCaption samples].
    public func callout(_ def: JSONObject, start: Int64, duration: Int64, params: [String: ParamSpec] = [:]) -> JSONObject {
        let id = clipID()
        let (ps, anim) = parameters(params)
        return JSONObject([
            ("id", .num(id)), ("_type", .str("Callout")), ("def", .object(def)),
            ("attributes", .obj(["ident": .str(""), "autoRotateText": .flag(true)])),
            ("parameters", ps), ("effects", .emptyArray),
            ("start", .num(start)), ("duration", .num(duration)),
            ("mediaStart", .num(0)), ("mediaDuration", .num(duration)), ("scalar", .num(1)),
            ("metadata", clipMetadata(speedChanged: false)), ("animationTracks", anim),
        ])
    }

    /// A `Group` whose inner tracks (bottom to top) are built by `content` after the group's id is taken.
    /// Inner clip times are on the group's own timeline; `mediaStart` is the inner time shown at `start`.
    public func group(name: String, start: Int64, duration: Int64, mediaStart: Int64 = 0,
                      params: [String: ParamSpec] = [:], content: () -> [[JSONObject]]) -> JSONObject {
        let id = clipID()
        let inner = content()
        let (ps, anim) = parameters(params)
        let innerEnd = inner.flatMap { $0 }.map { Clip($0).end }.max() ?? 0
        let tracksJSON: [JSON] = inner.enumerated().map { i, clips in
            .obj([
                "trackIndex": .num(i), "medias": .arr(clips.map { .object($0) }), "parameters": .emptyObject,
                "ident": .str(""), "audioMuted": .flag(false), "videoHidden": .flag(false),
                "magnetic": .flag(false), "matte": .num(0), "solo": .flag(false),
            ])
        }
        return JSONObject([
            ("id", .num(id)), ("_type", .str("Group")), ("parameters", ps), ("tracks", .arr(tracksJSON)),
            ("attributes", .obj([
                "ident": .str(name), "widthAttr": .dbl(Double(width)), "heightAttr": .dbl(Double(height)),
                "maxDurationAttr": .num(innerEnd), "gain": .dbl(1), "mixToMono": .flag(false),
            ])),
            ("effects", .emptyArray), ("start", .num(start)), ("duration", .num(duration)),
            ("mediaStart", .num(mediaStart)), ("mediaDuration", .num(duration)), ("scalar", .num(1)),
            ("metadata", .obj([
                "clipSpeedAttribute": .obj(["type": .str("bool"), "value": .flag(false)]),
                "colorAttribute": .obj(["type": .str("color"), "value": .arr([.num(0), .num(0), .num(0), .num(0)])]),
                "effectApplied": .str("none"),
                "isOpen": .obj(["type": .str("bool"), "value": .flag(false)]),
            ])),
            ("animationTracks", anim),
        ])
    }

    /// A `StitchedMedia` of `src`: `segments` are `(mediaStart, duration)` cuts (ticks) laid end to end
    /// on the stitched clip's inner timeline; `mediaStart` is the inner time shown at `start`.
    public func stitched(_ src: Source, segments: [(mediaStart: Int64, duration: Int64)], start: Int64,
                         duration: Int64, mediaStart: Int64 = 0, params: [String: ParamSpec] = [:]) -> JSONObject {
        let id = clipID()
        var t: Int64 = 0
        var segs: [JSON] = []
        for s in segments {
            let c = video(src, start: t, duration: s.duration, mediaStart: s.mediaStart)
            c["metadata"] = nil
            segs.append(.object(c))
            t += s.duration
        }
        let (ps, anim) = parameters(params)
        return JSONObject([
            ("id", .num(id)), ("_type", .str("StitchedMedia")), ("minMediaStart", .dbl(0)),
            ("attributes", .obj(["ident": .str((src.name as NSString).deletingPathExtension)])),
            ("parameters", ps), ("medias", .arr(segs)), ("effects", .emptyArray),
            ("start", .num(start)), ("duration", .num(duration)),
            ("mediaStart", .num(mediaStart)), ("mediaDuration", .num(duration)), ("scalar", .num(1)),
            ("metadata", clipMetadata(speedChanged: false)), ("animationTracks", anim),
        ])
    }

    // MARK: Output

    /// Assembles the project tree.
    public func build() -> Project {
        if timelineID == nil { timelineID = takeID() }
        let csmlTracks: [JSON] = tracks.enumerated().map { i, clips in
            .obj(["trackIndex": .num(i), "medias": .arr(clips.map { .object($0) }), "parameters": .emptyObject])
        }
        let trackAttributes: [JSON] = tracks.indices.map { _ in
            .obj([
                "ident": .str(""), "audioMuted": .flag(false), "videoHidden": .flag(false),
                "magnetic": .flag(false), "matte": .num(0), "solo": .flag(false),
                "metadata": .obj(["IsLocked": .str("False"), "trackHeight": .str("56")]),
            ])
        }
        let timeline = JSON.obj([
            "id": .num(timelineID ?? 0),
            "sceneTrack": .obj(["scenes": .arr([.obj(["csml": .obj(["tracks": .arr(csmlTracks)])])])]),
            "trackAttributes": .arr(trackAttributes),
            "parameters": .emptyObject,
            "captionAttributes": .obj([
                "enabled": .flag(true), "fontName": .str("Arial"), "fontSize": .num(32),
                "backgroundColor": .arr([.num(0), .num(0), .num(0), .num(204)]),
                "foregroundColor": .arr([.num(255), .num(255), .num(255), .num(255)]),
                "lang": .str("en"), "alignment": .num(0), "defaultFontSize": .flag(true), "opacity": .dbl(0.5),
                "backgroundEnabled": .flag(true), "backgroundOnlyAroundText": .flag(true),
            ]),
            "gain": .dbl(1),
            "legacyAttenuateAudioMix": .flag(false),
            "backgroundColor": .arr(background.map { .num($0) }),
        ])
        let root = JSONObject([
            ("title", .str(title)), ("description", .str("")), ("author", .str("")),
            ("targetLoudness", .dbl(-18)), ("shouldApplyLoudnessNormalization", .flag(true)),
            ("videoFormatFrameRate", .num(fps)), ("audioFormatSampleRate", .num(44100)),
            ("allowSubFrameEditing", .flag(false)),
            ("width", .dbl(Double(width))), ("height", .dbl(Double(height))),
            ("version", .str("10.0")), ("editRate", .num(editRate)),
            ("authoringClientName", .obj([
                "name": .str("WizRec testgen"), "platform": .str("Mac"), "version": .str(TestGen.version),
            ])),
            ("sourceBin", .arr(sources)),
            ("timeline", timeline),
            ("metadata", .obj([
                "RulerGuidesX": .emptyArray, "RulerGuidesY": .emptyArray,
                "RulerShowing": .obj(["type": .str("bool"), "value": .flag(false)]),
            ])),
        ])
        return Project(root: root)
    }
}
