import Foundation
import TSCProjKit

/// Transitions live in their track's `transitions` array:
/// `{name, duration, trivial, reverse, bypass, useAudioPreRoll,
/// useVisualPreRoll, leftMedia?, rightMedia?}` [obs, MediaMattePreview].
/// `leftMedia` is the clip whose **end** the transition covers and
/// `rightMedia` the clip whose **start** it covers; one side only = a fade
/// out / fade in.
///
/// Rule [inf]: a clip edge carries at most one transition, so adding one
/// replaces any transition already on either edge it covers. `duration` is
/// in ticks, snapped to frames, and must be > 0 and fit inside the clips it
/// covers.
@MainActor
enum TransitionEdit {
    static func locateTrack(_ project: Project, left: Int64?, right: Int64?) throws -> (JSONPath, [ClipLocation]) {
        let locs = try [left, right].compactMap { $0 }.map { try Locator.locate($0, in: project) }
        guard let first = locs.first else { throw EditError.invalid("a transition needs a clip") }
        guard locs.allSatisfy({ $0.trackPath == first.trackPath }) else {
            throw EditError.invalid("transition clips must be on the same track")
        }
        if locs.count == 2 {
            let l = locs[0].clip, r = locs[1].clip
            guard (l["start"]?.int ?? 0) + (l["duration"]?.int ?? 0) == r["start"]?.int else {
                throw EditError.invalid("clips \(left ?? -1) and \(right ?? -1) do not touch")
            }
        }
        return (first.trackPath, locs)
    }

    static func matches(_ o: JSONObject, left: Int64?, right: Int64?) -> Bool {
        o["leftMedia"]?.int == left && o["rightMedia"]?.int == right
    }

    /// Ensures `track.transitions` exists, placed right after `medias` [obs].
    static func transitions(_ track: JSONObject) -> JSONArray {
        if let a = track["transitions"]?.array { return a }
        let a = JSONArray()
        let keys = track.keys
        let tail = keys.firstIndex(of: "medias").map { Array(keys[($0 + 1)...]) } ?? []
        let saved = tail.map { ($0, track[$0]) }
        for k in tail { track[k] = nil }
        track["transitions"] = .array(a)
        for (k, v) in saved { track[k] = v }
        return a
    }
}

/// Adds a transition named `name` (e.g. `Fade`, `CubeRotate`) on the end of
/// `leftClipID` and/or the start of `rightClipID`.
@MainActor public final class AddTransition: EditCommand {
    public let name = "Add Transition"
    public let transitionName: String
    public let leftClipID: Int64?, rightClipID: Int64?
    public let duration: Int64
    private var swap = TrackSwap()

    public init(name: String, leftClipID: Int64?, rightClipID: Int64?, duration: Int64) {
        transitionName = name; self.leftClipID = leftClipID; self.rightClipID = rightClipID; self.duration = duration
    }

    public func apply(to project: Project) throws {
        guard !transitionName.isEmpty else { throw EditError.invalid("transition needs a name") }
        let d = FrameGrid(project).nearest(duration)
        guard d > 0 else { throw EditError.invalid("transition duration must be > 0") }
        let (path, locs) = try TransitionEdit.locateTrack(project, left: leftClipID, right: rightClipID)
        for l in locs where d > (l.clip["duration"]?.int ?? 0) {
            throw EditError.invalid("transition is longer than clip \(l.clip.clipID ?? -1)")
        }
        var edits = TrackEdits(project)
        let track = try edits.track(at: path)
        let list = TransitionEdit.transitions(track)
        list.items.removeAll { t in
            guard let o = t.object else { return false }
            return (leftClipID != nil && o["leftMedia"]?.int == leftClipID)
                || (rightClipID != nil && o["rightMedia"]?.int == rightClipID)
        }
        var pairs: [(String, JSON)] = [
            ("name", .string(transitionName)), ("duration", J.int(d)), ("trivial", .bool(false)),
            ("reverse", .bool(false)), ("bypass", .bool(false)), ("useAudioPreRoll", .bool(true)),
            ("useVisualPreRoll", .bool(true)),
        ]
        if let leftClipID { pairs.append(("leftMedia", J.int(leftClipID))) }
        if let rightClipID { pairs.append(("rightMedia", J.int(rightClipID))) }
        list.items.append(J.obj(pairs))
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Removes the transition with exactly these sides.
@MainActor public final class RemoveTransition: EditCommand {
    public let name = "Remove Transition"
    public let leftClipID: Int64?, rightClipID: Int64?
    private var swap = TrackSwap()
    public init(leftClipID: Int64?, rightClipID: Int64?) { self.leftClipID = leftClipID; self.rightClipID = rightClipID }
    public func apply(to project: Project) throws {
        let (path, _) = try TransitionEdit.locateTrack(project, left: leftClipID, right: rightClipID)
        var edits = TrackEdits(project)
        let track = try edits.track(at: path)
        guard let list = track["transitions"]?.array,
              let i = list.items.firstIndex(where: { $0.object.map { TransitionEdit.matches($0, left: leftClipID, right: rightClipID) } ?? false })
        else { throw EditError.invalid("no such transition") }
        list.items.remove(at: i)
        try edits.commit(&swap)
    }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

/// Changes a transition's duration (ticks, frame-snapped).
@MainActor public final class SetTransitionDuration: EditCommand {
    public let name = "Change Transition"
    public let leftClipID: Int64?, rightClipID: Int64?
    public let duration: Int64
    private var swap = TrackSwap()
    public init(leftClipID: Int64?, rightClipID: Int64?, duration: Int64) {
        self.leftClipID = leftClipID; self.rightClipID = rightClipID; self.duration = duration
    }
    public func apply(to project: Project) throws {
        let d = FrameGrid(project).nearest(duration)
        guard d > 0 else { throw EditError.invalid("transition duration must be > 0") }
        let (path, locs) = try TransitionEdit.locateTrack(project, left: leftClipID, right: rightClipID)
        for l in locs where d > (l.clip["duration"]?.int ?? 0) {
            throw EditError.invalid("transition is longer than clip \(l.clip.clipID ?? -1)")
        }
        var edits = TrackEdits(project)
        let track = try edits.track(at: path)
        guard let t = track["transitions"]?.array?.items.compactMap(\.object)
            .first(where: { TransitionEdit.matches($0, left: leftClipID, right: rightClipID) })
        else { throw EditError.invalid("no such transition") }
        guard t["duration"]?.int != d else { throw EditError.invalid("duration unchanged") }
        TimeWriter.set(d, "duration", in: t)
        try edits.commit(&swap)
    }
    public func revert(on project: Project) throws { try swap.restore(in: project) }
}
