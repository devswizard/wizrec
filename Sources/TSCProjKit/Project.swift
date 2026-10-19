import Foundation

/// A parsed `project.tscproj`.
///
/// The JSON tree in `root` is the source of truth; every typed accessor is a
/// view over it. Saving re-serialises `root`, so keys this library doesn't
/// model are written back untouched.
public final class Project {
    public let root: JSONObject

    public init(root: JSONObject) { self.root = root }

    public convenience init(data: Data) throws {
        guard let o = try JSON.parse(data).object else { throw ProjectError.notAnObject }
        self.init(root: o)
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func serialized() -> Data { JSON.object(root).serialized() }

    // MARK: Header

    /// Project format version string: `"2.0"` (Camtasia 2018) … `"10.0"` (2026).
    public var formatVersion: String { root["version"]?.string ?? "" }

    public var timebase: Timebase { Timebase(editRate: root["editRate"]?.int ?? 30) }

    /// Canvas size in pixels.
    public var width: Double { root["width"]?.double ?? 1920 }
    public var height: Double { root["height"]?.double ?? 1080 }

    /// Export frame rate. Absent in format ≤ 3.0 projects, where it is 30.
    public var frameRate: Rational { Rational(root["videoFormatFrameRate"]) ?? Rational(30) }
    public var audioSampleRate: Int64 { root["audioFormatSampleRate"]?.int ?? 44100 }

    public var title: String { root["title"]?.string ?? "" }

    /// Which Camtasia wrote the file (`name`, `platform` Mac/Windows, `version`).
    public var authoringClient: (name: String, platform: String, version: String) {
        let o = root["authoringClientName"]?.object
        return (o?["name"]?.string ?? "", o?["platform"]?.string ?? "", o?["version"]?.string ?? "")
    }

    // MARK: Media

    public var sourceBin: [SourceMedia] {
        root["sourceBin"]?.array?.items.compactMap(\.object).map(SourceMedia.init) ?? []
    }

    public func source(id: Int64) -> SourceMedia? { sourceBin.first { $0.id == id } }

    // MARK: Timeline

    public var timeline: Timeline? { root["timeline"]?.object.map(Timeline.init) }

    /// Tracks of the first scene (Camtasia projects have exactly one scene).
    public var tracks: [Track] { timeline?.scenes.first?.tracks ?? [] }

    /// End of the last clip on any track, in ticks.
    public var duration: Int64 { tracks.flatMap(\.clips).map(\.end).max() ?? 0 }

    /// Highest `id` in use anywhere — new clips must take ids above it.
    public var maxID: Int64 {
        var m: Int64 = 0
        func walk(_ v: JSON) {
            if let o = v.object {
                if let id = o["id"]?.int { m = max(m, id) }
                o.entries.forEach { walk($0.value) }
            } else if let a = v.array {
                a.items.forEach(walk)
            }
        }
        walk(.object(root))
        return m
    }
}

public enum ProjectError: Error, CustomStringConvertible {
    case notAnObject
    case missingProjectFile(URL)

    public var description: String {
        switch self {
        case .notAnObject: "project root is not a JSON object"
        case .missingProjectFile(let u): "no project.tscproj in \(u.path)"
        }
    }
}

/// One `sourceBin` entry: a media file used by the project.
public struct SourceMedia {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public var id: Int64 { object["id"]?.int ?? -1 }

    /// Path as stored — usually relative to the `.cmproj` folder
    /// (`./media/<timestamp>/file.mp4`), may be absolute for linked media.
    public var src: String { object["src"]?.string ?? "" }

    /// Native frame rect `[x, y, w, h]`.
    public var rect: [Double] { object["rect"]?.array?.items.compactMap(\.double) ?? [] }

    public var tracks: [SourceTrack] {
        object["sourceTracks"]?.array?.items.compactMap(\.object).map(SourceTrack.init) ?? []
    }
}

/// One stream inside a source file.
public struct SourceTrack {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    /// Observed: 0 = video, 1 = image, 2 = audio.
    public var type: Int64 { object["type"]?.int ?? -1 }
    public var isVideo: Bool { type == 0 }
    public var isAudio: Bool { type == 2 }

    /// Stream's own time units per second (NOT the project editRate).
    public var editRate: Int64 { object["editRate"]?.int ?? 1 }

    /// `[start, end]` in this stream's `editRate` units.
    public var range: [Int64] { object["range"]?.array?.items.compactMap(\.int) ?? [] }

    public var durationSeconds: Double {
        let r = range
        guard r.count == 2, editRate > 0 else { return 0 }
        return Double(r[1] - r[0]) / Double(editRate)
    }

    /// Frame rate for video (`"2997/50"`), sample rate for audio (`48000`).
    public var sampleRate: Rational? { Rational(object["sampleRate"]) }
    public var channels: Int64 { object["numChannels"]?.int ?? 0 }
    public var integratedLUFS: Double? { object["integratedLUFS"]?.double }
}

public struct Timeline {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public var scenes: [Scene] {
        object["sceneTrack"]?.object?["scenes"]?.array?.items.compactMap(\.object).map(Scene.init) ?? []
    }

    /// Per-track UI state (`ident` name, mute, hide, lock, magnetic, solo),
    /// index-aligned with the scene's `tracks`.
    public var trackAttributes: [JSONObject] {
        object["trackAttributes"]?.array?.items.compactMap(\.object) ?? []
    }

    public var captionAttributes: JSONObject? { object["captionAttributes"]?.object }

    /// Canvas background RGBA (0…255).
    public var backgroundColor: [Int64] {
        object["backgroundColor"]?.array?.items.compactMap(\.int) ?? [0, 0, 0, 255]
    }
}

public struct Scene {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public var tracks: [Track] {
        object["csml"]?.object?["tracks"]?.array?.items.compactMap(\.object).map(Track.init) ?? []
    }
}

/// A timeline track. Index 0 is the bottom of the visual stack.
public struct Track {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    public var index: Int64 { object["trackIndex"]?.int ?? 0 }

    public var clips: [Clip] {
        object["medias"]?.array?.items.compactMap(\.object).map(Clip.init) ?? []
    }

    public var transitions: [Transition] {
        object["transitions"]?.array?.items.compactMap(\.object).map(Transition.init) ?? []
    }

    /// Clip visible at `t` (tracks don't overlap clips).
    public func clip(at t: Int64) -> Clip? { clips.first { $0.contains(t) } }
}

/// Transition between/at the edge of clips on a track.
/// `leftMedia` / `rightMedia` hold clip ids; one side missing = fade in/out.
public struct Transition {
    public let object: JSONObject

    public init(_ object: JSONObject) { self.object = object }

    /// e.g. `RadialWipe`, `Fade`, `CubeRotate`.
    public var name: String { object["name"]?.string ?? "" }
    public var duration: Int64 { object["duration"]?.int ?? 0 }
    public var leftMediaID: Int64? { object["leftMedia"]?.int }
    public var rightMediaID: Int64? { object["rightMedia"]?.int }
    public var reversed: Bool { object["reverse"]?.bool ?? false }
    public var bypassed: Bool { object["bypass"]?.bool ?? false }
}
