import Foundation
import TSCProjKit

/// A marker (Camtasia's "table of contents" entry). `time` is in timeline
/// ticks for timeline markers and on the clip's media-time axis for clip markers.
public struct Marker: Sendable, Equatable {
    public var time: Int64
    public var name: String
    public init(time: Int64, name: String) { self.time = time; self.name = name }
}

/// Reading markers.
///
/// - Timeline markers: keyframes of `timeline.parameters.toc`
///   (`{type: "string", keyframes: [{endTime, time, value, duration: 0}]}`),
///   sorted by time [obs, docs/specs/markers.md].
/// - Clip markers: **[?]** (experiment X8). Our guess, isolated in
///   `clipMarkerOwner`: the same `toc` parameter on the clip object itself
///   (the parent for a `UnifiedMedia`), on its media-time axis.
@MainActor
public enum Markers {
    public static func timeline(_ project: Project) -> [Marker] {
        read(project.timeline?.object["parameters"]?.object)
    }

    /// Markers of clip `id` (top level or inside groups); empty when none or not found.
    public static func clip(_ project: Project, id: Int64) -> [Marker] {
        guard let loc = try? Locator.locate(id, in: project) else { return [] }
        return read(clipMarkerOwner(loc.clip)["parameters"]?.object)
    }

    /// The object whose `parameters.toc` holds a clip's markers. [?] X8.
    static func clipMarkerOwner(_ clip: JSONObject) -> JSONObject { clip }

    static func read(_ params: JSONObject?) -> [Marker] {
        (params?["toc"]?.object?["keyframes"]?.array?.items ?? []).compactMap { k in
            guard let o = k.object, let t = o["time"]?.int else { return nil }
            return Marker(time: t, name: o["value"]?.string ?? "")
        }
    }

    /// One marker keyframe: `{endTime, time, value, duration: 0}` [obs].
    static func keyframe(_ m: Marker) -> JSON {
        J.obj([("endTime", J.int(m.time)), ("time", J.int(m.time)), ("value", .string(m.name)), ("duration", J.int(0))])
    }

    /// Applies `edit` to the marker list of the timeline (`clipID` nil) or a
    /// clip, writing through `swap` so revert is exact. The `toc` parameter
    /// is created when missing (timeline `parameters` goes after
    /// `trackAttributes`, before `captionAttributes` [obs]) and removed when
    /// the last marker goes.
    static func edit(_ project: Project, clipID: Int64?,
                     swapValues: inout ValueSwap, swapTracks: inout TrackSwap,
                     _ edit: (inout [Marker]) throws -> Void) throws {
        if let clipID {
            let loc = try Locator.locate(clipID, in: project)
            var edits = TrackEdits(project)
            let track = try edits.track(at: loc.trackPath)
            guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(clipID) }
            let owner = clipMarkerOwner(clip)
            if owner["parameters"]?.object == nil { owner["parameters"] = J.emptyObject }
            guard let params = owner["parameters"]?.object else { throw EditError.invalid("no parameters") }
            try write(params, edit)
            try edits.commit(&swapTracks)
            return
        }
        guard let timeline = project.timeline?.object else { throw EditError.invalid("project has no timeline") }
        let path = JSONPath(steps: [.key("timeline")])
        let newTimeline: JSONObject
        if let p = timeline["parameters"]?.object {
            let params = p.copy()
            try write(params, edit)
            newTimeline = JSONObject(timeline.entries.map { ($0.key, $0.key == "parameters" ? .object(params) : $0.value) })
        } else {
            let params = JSONObject()
            try write(params, edit)
            var pairs = timeline.entries.map { ($0.key, $0.value) }
            let after = pairs.firstIndex { $0.0 == "trackAttributes" }.map { $0 + 1 }
            let before = pairs.firstIndex { $0.0 == "captionAttributes" }
            pairs.insert(("parameters", .object(params)), at: after ?? before ?? pairs.count)
            newTimeline = JSONObject(pairs)
        }
        // The new timeline object shares every other child with the old one;
        // commands are copy-on-write and undo is LIFO, so that is safe.
        try swapValues.commit([(path, .object(newTimeline))], in: project)
    }

    private static func write(_ params: JSONObject, _ edit: (inout [Marker]) throws -> Void) throws {
        var markers = read(params)
        let before = markers
        try edit(&markers)
        guard markers != before else { throw EditError.invalid("markers unchanged") }
        markers.sort { $0.time < $1.time }
        guard !markers.isEmpty else { params["toc"] = nil; return }
        let toc: JSONObject
        if let t = params["toc"]?.object { toc = t } else {
            toc = JSONObject([("type", .string("string")), ("keyframes", J.emptyArray)])
            params["toc"] = .object(toc)
        }
        // Keep existing keyframe objects (and any extra keys) where the marker is unchanged.
        let old = toc["keyframes"]?.array?.items.compactMap(\.object) ?? []
        var pool = old
        let items: [JSON] = markers.map { m in
            if let i = pool.firstIndex(where: { $0["time"]?.int == m.time && $0["value"]?.string == m.name }) {
                return .object(pool.remove(at: i))
            }
            return keyframe(m)
        }
        toc["keyframes"] = J.arr(items)
    }
}

/// Adds a marker at `time` (timeline ticks, or clip media time with
/// `clipID`), snapped to the frame grid. A marker already at that tick is
/// renamed instead [inf].
@MainActor public final class AddMarker: EditCommand {
    public let name = "Add Marker"
    public let time: Int64
    public let label: String
    public let clipID: Int64?
    private var values = ValueSwap()
    private var tracks = TrackSwap()
    public init(at time: Int64, name: String, clipID: Int64? = nil) {
        self.time = time; label = name; self.clipID = clipID
    }
    public func apply(to project: Project) throws {
        let t = FrameGrid(project).nearest(time)
        guard t >= 0 else { throw EditError.invalid("marker time must be ≥ 0") }
        try Markers.edit(project, clipID: clipID, swapValues: &values, swapTracks: &tracks) { ms in
            if let i = ms.firstIndex(where: { $0.time == t }) { ms[i].name = label } else { ms.append(Marker(time: t, name: label)) }
        }
    }
    public func revert(on project: Project) throws { try MarkerUndo.revert(&values, &tracks, project) }
}

/// Removes the marker at `time`.
@MainActor public final class RemoveMarker: EditCommand {
    public let name = "Remove Marker"
    public let time: Int64
    public let clipID: Int64?
    private var values = ValueSwap()
    private var tracks = TrackSwap()
    public init(at time: Int64, clipID: Int64? = nil) { self.time = time; self.clipID = clipID }
    public func apply(to project: Project) throws {
        try Markers.edit(project, clipID: clipID, swapValues: &values, swapTracks: &tracks) { ms in
            guard let i = ms.firstIndex(where: { $0.time == time }) else { throw EditError.invalid("no marker at \(time)") }
            ms.remove(at: i)
        }
    }
    public func revert(on project: Project) throws { try MarkerUndo.revert(&values, &tracks, project) }
}

/// Moves the marker at `from` to `to` (frame-snapped). Throws if another marker is at `to`.
@MainActor public final class MoveMarker: EditCommand {
    public let name = "Move Marker"
    public let from: Int64, to: Int64
    public let clipID: Int64?
    private var values = ValueSwap()
    private var tracks = TrackSwap()
    public init(from: Int64, to: Int64, clipID: Int64? = nil) { self.from = from; self.to = to; self.clipID = clipID }
    public func apply(to project: Project) throws {
        let t = FrameGrid(project).nearest(to)
        guard t >= 0 else { throw EditError.invalid("marker time must be ≥ 0") }
        try Markers.edit(project, clipID: clipID, swapValues: &values, swapTracks: &tracks) { ms in
            guard let i = ms.firstIndex(where: { $0.time == from }) else { throw EditError.invalid("no marker at \(from)") }
            guard !ms.contains(where: { $0.time == t && $0.time != from }) else { throw EditError.invalid("marker exists at \(t)") }
            ms[i].time = t
        }
    }
    public func revert(on project: Project) throws { try MarkerUndo.revert(&values, &tracks, project) }
}

/// Renames the marker at `time`.
@MainActor public final class RenameMarker: EditCommand {
    public let name = "Rename Marker"
    public let time: Int64
    public let newName: String
    public let clipID: Int64?
    private var values = ValueSwap()
    private var tracks = TrackSwap()
    public init(at time: Int64, to newName: String, clipID: Int64? = nil) {
        self.time = time; self.newName = newName; self.clipID = clipID
    }
    public func apply(to project: Project) throws {
        try Markers.edit(project, clipID: clipID, swapValues: &values, swapTracks: &tracks) { ms in
            guard let i = ms.firstIndex(where: { $0.time == time }) else { throw EditError.invalid("no marker at \(time)") }
            ms[i].name = newName
        }
    }
    public func revert(on project: Project) throws { try MarkerUndo.revert(&values, &tracks, project) }
}

@MainActor
enum MarkerUndo {
    static func revert(_ v: inout ValueSwap, _ t: inout TrackSwap, _ project: Project) throws {
        if !v.isEmpty { try v.restore(in: project) } else { try t.restore(in: project) }
    }
}
