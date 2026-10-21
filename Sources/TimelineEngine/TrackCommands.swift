import Foundation
import TSCProjKit

// Track-header and Edit-menu commands for the context menus (TL15-2,
// ui-workflow §7, §9). Rules not seen in Camtasia saves are [WizRec]:
// - MoveTrack moves the scene track and its `trackAttributes` entry together
//   (flags, name and height travel with the track); `trackIndex` is
//   renumbered to the array position, as AddTrack/RemoveTrack do.
// - RenameTrack writes `trackAttributes[i].ident`; "" means the default
//   numbered name (every observed new track has `ident` "" [obs]).
// - SplitAllTracks splits every top-level clip the playhead is strictly
//   inside, on every unlocked track, as one undo step; a clip only touching
//   the playhead at an edge is left alone.

/// Moves top-level track `from` to position `to` (0 = bottom), with its
/// `trackAttributes` entry. Both are indices before the move.
@MainActor public final class MoveTrack: EditCommand {
    public let name = "Move Track"
    public let from: Int
    public let to: Int
    public init(from: Int, to: Int) { self.from = from; self.to = to }
    var swap = ValueSwap()

    public func apply(to project: Project) throws {
        let tracks = try M2.sceneTracksArray(project)
        guard tracks.items.indices.contains(from) else { throw EditError.trackNotFound(from) }
        guard tracks.items.indices.contains(to) else { throw EditError.trackNotFound(to) }
        guard from != to else { throw EditError.invalid("track \(from) is already there") }
        var items = tracks.items
        items.insert(items.remove(at: from), at: to)
        var edits: [(path: JSONPath, new: JSON)] = [(JSONPath.sceneTracks, .array(M2.renumbered(items)))]
        if let attrs = M2.trackAttributesPath.resolve(in: project.root)?.array,
           attrs.items.indices.contains(from), attrs.items.indices.contains(to) {
            var a = attrs.items
            a.insert(a.remove(at: from), at: to)
            edits.append((M2.trackAttributesPath, .array(JSONArray(a))))
        }
        try swap.commit(edits, in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Sets the name (`trackAttributes[i].ident`) of top-level track `track`;
/// "" restores the default numbered name.
@MainActor public final class RenameTrack: EditCommand {
    public let name = "Rename Track"
    public let track: Int
    public let newName: String
    public init(track: Int, name: String) { self.track = track; self.newName = name }
    var swap = ValueSwap()

    public func apply(to project: Project) throws {
        guard let attrs = M2.trackAttributesPath.resolve(in: project.root)?.array,
              attrs.items.indices.contains(track), let old = attrs.items[track].object
        else { throw EditError.trackNotFound(track) }
        guard old["ident"]?.string != newName else { throw EditError.invalid("track already has that name") }
        let a = old.copy()
        a["ident"] = .string(newName)
        try swap.commit([(M2.trackAttributesPath.appending(.index(track)), .object(a))], in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Splits every top-level clip that `time` (project ticks, snapped to the
/// frame grid) is strictly inside, on every unlocked track: one undo step.
@MainActor public final class SplitAllTracks: EditCommand {
    public let name = "Split"
    public let time: Int64
    /// Ids of the right halves made by the last `apply`, bottom track first.
    public private(set) var rightIDs: [Int64] = []
    private var splits: [SplitClip] = []

    public init(at time: Int64) { self.time = time }

    public func apply(to project: Project) throws {
        let at = FrameGrid(project).nearest(time)
        let ids = TimelineSelection.clips(at: at, in: project, unlockedOnly: true).filter { id in
            guard let loc = try? Locator.locate(id, in: project), let t = try? Timing(loc.clip) else { return false }
            return t.start < at && at < t.end
        }
        guard !ids.isEmpty else { throw EditError.invalid("no clip at the playhead") }
        var done: [SplitClip] = []
        do {
            for id in ids {
                let s = SplitClip(clipID: id, at: at)
                try s.apply(to: project)
                done.append(s)
            }
        } catch {
            for s in done.reversed() { try? s.revert(on: project) }
            throw error
        }
        splits = done
        rightIDs = done.compactMap(\.rightID)
    }

    public func revert(on project: Project) throws {
        guard !splits.isEmpty else { throw EditError.invalid("nothing to revert") }
        for s in splits.reversed() { try s.revert(on: project) }
        splits = []
        rightIDs = []
    }
}

/// Clip-selection queries for the Edit ▸ Select items (top-level clips only;
/// ids in track order, bottom first, then by start). Pure: nothing changes.
@MainActor public enum TimelineSelection {
    /// Every top-level clip.
    public static func all(in project: Project) -> [Int64] {
        project.tracks.flatMap { $0.clips.map(\.id) }
    }

    /// Top-level clips playing at `time` (project ticks): `start ≤ time < end`.
    /// Locked and hidden tracks are included unless `unlockedOnly` [WizRec].
    public static func clips(at time: Int64, in project: Project, unlockedOnly: Bool = false) -> [Int64] {
        let attrs = project.timeline?.trackAttributes ?? []
        var out: [Int64] = []
        for (i, track) in project.tracks.enumerated() {
            if unlockedOnly, i < attrs.count, attrs[i]["metadata"]?.object?["IsLocked"]?.string == "True" { continue }
            out += track.clips.filter { $0.start <= time && time < $0.start + $0.duration }.map(\.id)
        }
        return out
    }

    /// Clips before `clipID` on its own top-level track (`start` earlier).
    public static func preceding(_ clipID: Int64, in project: Project) -> [Int64] {
        sameTrack(clipID, project) { $0 < $1 }
    }

    /// Clips after `clipID` on its own top-level track (`start` later).
    public static func succeeding(_ clipID: Int64, in project: Project) -> [Int64] {
        sameTrack(clipID, project) { $0 > $1 }
    }

    private static func sameTrack(_ clipID: Int64, _ project: Project, _ keep: (Int64, Int64) -> Bool) -> [Int64] {
        for track in project.tracks {
            guard let me = track.clips.first(where: { $0.id == clipID }) else { continue }
            return track.clips.filter { $0.id != clipID && keep($0.start, me.start) }.map(\.id)
        }
        return []
    }
}
