import Foundation
import TSCProjKit

/// Inserts a new `Callout` clip the way Camtasia places a callout from the Annotations gallery
/// (`docs/specs/callouts.md` §1 and §3.1, CO3 [obs]):
/// - `start` = the playhead (ticks, snapped to the frame grid), `duration` 5 s by default;
///   `mediaStart` 0, `mediaDuration` = duration, `scalar` 1;
/// - `def` is the caller's callout definition (JSON object text, project form of §2);
/// - `displayWidth`: on-canvas width in px; `scale0/1` = displayWidth / `def.width` (CO3: region
///   callouts are scaled to 640 px, a third of a 1920-px canvas [inf rule]); nil or a `def`
///   without a positive `width` writes no scale (keystroke callouts);
/// - `attributes` `{ident: "", autoRotateText: true}`, `geometryCrop0…3` 0, no effects, the
///   usual new-clip `metadata` and empty `animationTracks` (key order as Camtasia writes
///   callouts [obs C1]).
///
/// `track`: an existing top-level track, which must be free over the callout's span (magnetic
/// tracks make room as for `InsertClip`); nil adds a new track on top. The clip id is
/// `Project.maxID + 1` (`clipID` after apply). Revert is byte-identical.
@MainActor public final class InsertCallout: EditCommand {
    public let name = "Add Callout"
    /// Default length, seconds [obs CO3].
    public static let defaultSeconds: Int64 = 5
    public let def: String
    public let start: Int64
    public let track: Int?
    /// Ticks; nil = `defaultSeconds`.
    public let duration: Int64?
    public let displayWidth: Double?
    public private(set) var clipID: Int64?
    /// The track the callout went to (after apply).
    public private(set) var trackIndex: Int?
    private var addTrack: AddTrack?
    var swap = TrackSwap()

    public init(def: String, start: Int64, track: Int? = nil, duration: Int64? = nil, displayWidth: Double? = nil) {
        self.def = def; self.start = start; self.track = track; self.duration = duration; self.displayWidth = displayWidth
    }

    public func apply(to project: Project) throws {
        guard let d = try JSON.parse(def).object else { throw EditError.invalid("callout def is not an object") }
        let grid = FrameGrid(project)
        let at = grid.nearest(start)
        guard at >= 0 else { throw EditError.invalid("start must be ≥ 0") }
        let length = grid.floor(duration ?? project.timebase.editRate * Self.defaultSeconds)
        guard length > 0 else { throw EditError.invalid("callout is shorter than one frame") }

        let index: Int
        if let t = track {
            index = t
        } else {
            index = Locator.sceneTracks(project).count
            let add = AddTrack(at: index)
            try add.apply(to: project)
            addTrack = add
        }
        do {
            let tracks = Locator.sceneTracks(project)
            guard tracks.indices.contains(index) else { throw EditError.trackNotFound(index) }
            let id = project.maxID + 1
            let clip = Self.clip(id: id, def: d, start: at, duration: length, displayWidth: displayWidth)
            let magnetic = Magnetic.isMagnetic(project, track: index)
            let edits = magnetic ? tracks[index].track.copy()
                : try M2.trackForInsert(tracks[index].track, start: at, duration: length, track: index)
            if magnetic { Magnetic.insert(clip, into: edits, start: at) } else { try M2.insertSorted(clip, into: edits) }
            try swap.commit([(tracks[index].path, edits)], in: project)
            clipID = id
            trackIndex = index
        } catch {
            if let add = addTrack { try? add.revert(on: project); addTrack = nil }
            throw error
        }
    }

    public func revert(on project: Project) throws {
        try swap.restore(in: project)
        if let add = addTrack { try add.revert(on: project); addTrack = nil }
        clipID = nil
        trackIndex = nil
    }

    /// The new clip object.
    static func clip(id: Int64, def d: JSONObject, start: Int64, duration: Int64, displayWidth: Double?) -> JSONObject {
        var params: [(String, JSON)] = []
        if let w = displayWidth, w > 0, let natural = d["width"]?.double, natural > 0, w != natural {
            // Rounded to 1e-6 so float noise never reaches the file.
            let s = (w / natural * 1_000_000).rounded() / 1_000_000
            params += [("scale0", J.dbl(s)), ("scale1", J.dbl(s))]
        }
        for i in 0..<4 { params.append(("geometryCrop\(i)", J.dbl(0))) }
        return JSONObject([
            ("id", J.int(id)), ("_type", .string("Callout")), ("def", .object(d)),
            ("attributes", J.obj([("ident", .string("")), ("autoRotateText", .bool(true))])),
            ("parameters", J.obj(params)), ("effects", J.emptyArray),
            ("start", J.int(start)), ("duration", J.int(duration)), ("mediaStart", J.int(0)),
            ("mediaDuration", J.int(duration)), ("scalar", J.int(1)),
            ("metadata", MediaJSON.metadata(defaultScale: nil)), ("animationTracks", J.emptyObject),
        ])
    }
}
