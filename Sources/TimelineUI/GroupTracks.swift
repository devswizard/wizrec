import Foundation
import TimelineEngine
import TSCProjKit

/// Where media dropped inside an open group goes (`TimelineModel.onGroupDrop`).
public struct GroupDropTarget: Sendable, Equatable {
    /// Innermost open group (clip id) that receives the media.
    public var group: Int64
    /// Open groups, outermost first (`TimelineModel.openGroups` as resolved); last == `group`.
    public var groupPath: [Int64]
    /// Inner track index of `group` (0 = bottom; always an existing inner track).
    public var track: Int
    /// Start on the group's inner timeline, ticks (snapped like moves, frame-rounded). Not
    /// clamped: before 0 or past the group's window the clip is kept there, hidden, as Camtasia
    /// does (group-edits §8.6).
    public var ticks: Int64

    public init(group: Int64, groupPath: [Int64], track: Int, ticks: Int64) {
        self.group = group; self.groupPath = groupPath; self.track = track; self.ticks = ticks
    }
}

/// Builds the commands that add or remove a track inside a group. A thin seam over
/// TimelineEngine so the UI can be tested with a fake; nil means "not possible".
@MainActor
protocol GroupTrackCommands {
    /// New empty inner track of `group` at inner index `index` (0 = bottom).
    func addTrack(group: Int64, at index: Int) -> (any EditCommand)?
    /// Removes inner track `index` of `group` with its clips.
    func removeTrack(group: Int64, at index: Int) -> (any EditCommand)?
}

/// TimelineEngine's `AddGroupTrack` / `RemoveGroupTrack`.
struct EngineGroupTracks: GroupTrackCommands {
    func addTrack(group: Int64, at index: Int) -> (any EditCommand)? { AddGroupTrack(group: group, at: index) }
    func removeTrack(group: Int64, at index: Int) -> (any EditCommand)? { RemoveGroupTrack(group: group, at: index) }
}

extension TimelineEditor {
    /// True when a track can be added at the shown level (top level, or an open group
    /// whose command builder supports it).
    public var canAddTrack: Bool {
        guard let group = snapshot.groupPath.last else { return true }
        return model.groupTracks.addTrack(group: group, at: snapshot.tracks.count) != nil
    }

    /// True when track `index` of the shown level can be removed. Inside a group the
    /// last inner track stays (a group always has at least one track).
    public func canRemoveTrack(at index: Int) -> Bool {
        guard snapshot.track(index) != nil else { return false }
        guard let group = snapshot.groupPath.last else { return true }
        return snapshot.tracks.count > 1 && model.groupTracks.removeTrack(group: group, at: index) != nil
    }

    /// Adds an empty track at `index` (clamped) of the shown level: the scene at the top
    /// level, the innermost open group's tracks otherwise.
    @discardableResult
    public func addTrack(at index: Int) -> Bool {
        let i = min(max(index, 0), snapshot.tracks.count)
        guard let group = snapshot.groupPath.last else { return perform(AddTrack(at: i)) }
        guard let c = model.groupTracks.addTrack(group: group, at: i) else { return false }
        return perform(c)
    }

    /// Removes track `index` of the shown level with its clips (deselected).
    @discardableResult
    public func removeTrack(at index: Int) -> Bool {
        guard canRemoveTrack(at: index) else { return false }
        let gone = Set(snapshot.tracks[index].clips.map(\.id))
        let command: any EditCommand
        if let group = snapshot.groupPath.last {
            guard let c = model.groupTracks.removeTrack(group: group, at: index) else { return false }
            command = c
        } else {
            command = RemoveTrack(at: index)
        }
        guard perform(command) else { return false }
        model.selection.subtract(gone)
        return true
    }

    /// Group drop target for a drop at shown `track` and root (display) tick `ticks`, mapped to
    /// the group's inner time without clamping (group-edits §8.6); nil at the top level.
    public func groupDropTarget(track: Int, ticks: Int64) -> GroupDropTarget? {
        guard let group = snapshot.groupPath.last, snapshot.track(track) != nil else { return nil }
        let f = max(snapshot.frameTicks, 1)
        let inner = Int64((Double(map.inner(ticks)) / Double(f)).rounded()) * f
        return GroupDropTarget(group: group, groupPath: snapshot.groupPath, track: track, ticks: inner)
    }
}
