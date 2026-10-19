import Foundation
import TimelineEngine
import TSCProjKit

/// Several commands performed as one undo step (one gesture = one undo entry).
/// `apply` runs them in order; if one throws, the ones already applied are reverted in
/// reverse order and the error is rethrown, so the project is left unchanged.
@MainActor
public final class CompositeCommand: EditCommand {
    public let name: String
    public let commands: [any EditCommand]

    public init(name: String, _ commands: [any EditCommand]) {
        self.name = name; self.commands = commands
    }

    public func apply(to project: Project) throws {
        var done: [any EditCommand] = []
        do {
            for c in commands { try c.apply(to: project); done.append(c) }
        } catch {
            for c in done.reversed() { try? c.revert(on: project) }
            throw error
        }
    }

    public func revert(on project: Project) throws {
        for c in commands.reversed() { try c.revert(on: project) }
    }
}

/// A planned clip move: every clip in `ids` shifts by `delta` ticks and `trackOffset` tracks.
public struct MovePlan: Sendable, Equatable {
    public var ids: [Int64]
    public var delta: Int64
    public var trackOffset: Int
    /// False when the move would overlap, leave the track range or touch a locked track.
    public var isValid: Bool
    /// Snap guide position, ticks.
    public var guide: Int64?
}

/// A planned edge trim of one clip to `target` ticks.
public struct TrimPlan: Sendable, Equatable {
    public var id: Int64
    public var track: Int
    public var edge: TrimEdge
    public var target: Int64
    public var guide: Int64?
}

/// Turns gestures into TimelineEngine commands. Pure planning (`planMove`, `planTrim`)
/// works on a `TimelineSnapshot`; `perform…` methods push one command on `model.undo`.
/// The editor never calls `undo()`/`redo()` (the app owns those).
@MainActor
public struct TimelineEditor {
    public let model: TimelineModel
    public var snapshot: TimelineSnapshot
    public var snapper: any TimelineSnapping

    public init(model: TimelineModel, snapshot: TimelineSnapshot, snapper: any TimelineSnapping = EdgeSnapper()) {
        self.model = model; self.snapshot = snapshot; self.snapper = snapper
    }

    // MARK: Planning

    /// Moves `ids` by a raw `delta` (ticks) and `trackOffset`, then snaps (within `tolerance`
    /// ticks, when snapping is on) and rounds the result to the frame grid.
    public func planMove(ids: [Int64], rawDelta: Int64, trackOffset: Int, tolerance: Int64) -> MovePlan {
        let moving = ids.compactMap { snapshot.clip($0) }
        guard let anchor = moving.min(by: { $0.clip.start < $1.clip.start }) else {
            return MovePlan(ids: ids, delta: 0, trackOffset: 0, isValid: false, guide: nil)
        }
        let minStart = moving.map(\.clip.start).min() ?? 0
        var delta = max(rawDelta, -minStart)
        var guide: Int64?
        if model.snappingEnabled {
            let edges = moving.flatMap { [$0.clip.start + delta, $0.clip.end + delta] }
            if let s = snapper.snap(edges: edges, tolerance: tolerance, snapshot: snapshot,
                                    playhead: model.playhead, excluding: Set(ids)) {
                delta += s.delta; guide = s.guide
            }
        }
        let q = snapshot.quantize(anchor.clip.start + delta) - anchor.clip.start
        if guide != nil, q != delta { guide = nil }
        delta = max(q, -minStart)
        // Track offset limited so every clip stays on an existing track.
        let tracks = moving.map(\.track)
        let lo = -(tracks.min() ?? 0), hi = snapshot.tracks.count - 1 - (tracks.max() ?? 0)
        let offset = min(max(trackOffset, lo), max(lo, hi))
        let valid = isValidMove(moving: moving, delta: delta, trackOffset: offset)
        return MovePlan(ids: ids, delta: delta, trackOffset: offset, isValid: valid, guide: guide)
    }

    func isValidMove(moving: [(track: Int, clip: TimelineClipItem)], delta: Int64, trackOffset: Int) -> Bool {
        guard !moving.isEmpty, delta != 0 || trackOffset != 0 else { return false }
        let ids = Set(moving.map(\.clip.id))
        for (t, c) in moving {
            let dest = t + trackOffset
            guard let src = snapshot.track(t), let dst = snapshot.track(dest), !src.locked, !dst.locked,
                  c.start + delta >= 0 else { return false }
            let s = c.start + delta, e = c.end + delta
            for o in dst.clips where !ids.contains(o.id) && o.start < e && s < o.end { return false }
        }
        return true
    }

    /// Moves one edge of clip `id` by `rawDelta` ticks, snapped and frame-rounded, kept at
    /// least one frame long and clear of the neighbouring clips. Media limits are left to
    /// `TrimClip`, which clamps on commit.
    public func planTrim(id: Int64, edge: TrimEdge, rawDelta: Int64, tolerance: Int64) -> TrimPlan? {
        guard let (track, clip) = snapshot.clip(id), let t = snapshot.track(track), !t.locked else { return nil }
        let original = edge == .start ? clip.start : clip.end
        var target = original + rawDelta
        var guide: Int64?
        if model.snappingEnabled,
           let s = snapper.snap(edges: [target], tolerance: tolerance, snapshot: snapshot,
                                playhead: model.playhead, excluding: [id]) {
            target += s.delta; guide = s.guide
        }
        let q = snapshot.quantize(target)
        if q != target { guide = nil }
        target = q
        let frame = snapshot.frameTicks
        let prevEnd = t.clips.filter { $0.id != id && $0.end <= clip.start }.map(\.end).max() ?? 0
        let nextStart = t.clips.filter { $0.id != id && $0.start >= clip.end }.map(\.start).min()
        switch edge {
        case .start: target = min(max(target, prevEnd), clip.end - frame)
        case .end:
            target = max(target, clip.start + frame)
            if let n = nextStart { target = min(target, n) }
        }
        return TrimPlan(id: id, track: track, edge: edge, target: target, guide: guide)
    }

    // MARK: Commands

    /// Commands for a move plan, ordered so clips never collide with each other mid-way.
    public func moveCommand(_ plan: MovePlan) -> (any EditCommand)? {
        guard plan.isValid else { return nil }
        let moving = plan.ids.compactMap { snapshot.clip($0) }
        let ordered = moving.sorted { plan.delta > 0 ? $0.clip.start > $1.clip.start : $0.clip.start < $1.clip.start }
        let cmds: [any EditCommand] = ordered.map {
            MoveClip(clipID: $0.clip.id, toTrack: $0.track + plan.trackOffset, start: $0.clip.start + plan.delta)
        }
        return cmds.count == 1 ? cmds[0] : CompositeCommand(name: "Move", cmds)
    }

    /// Clips that "split at playhead" acts on: selected clips under `t` (strictly inside),
    /// or, with no selection, every clip under `t`. Locked tracks are skipped.
    public func splitTargets(at t: Int64) -> [Int64] {
        let candidates = snapshot.tracks.filter { !$0.locked }.flatMap(\.clips).filter { $0.start < t && t < $0.end }
        let selected = candidates.filter { model.selection.contains($0.id) }
        return (model.selection.isEmpty ? candidates : selected).map(\.id)
    }

    /// Selected clips on unlocked tracks.
    public var deletableSelection: [Int64] {
        snapshot.tracks.filter { !$0.locked }.flatMap(\.clips).map(\.id).filter { model.selection.contains($0) }
    }

    /// Pushes `command` on the undo stack. Returns false (project unchanged) when it throws.
    @discardableResult
    public func perform(_ command: any EditCommand) -> Bool {
        do { try model.undo.perform(command); return true } catch {
            model.lastError = "\(command.name): \(error)"
            return false
        }
    }

    @discardableResult
    public func performMove(_ plan: MovePlan) -> Bool {
        guard let c = moveCommand(plan) else { return false }
        return perform(c)
    }

    @discardableResult
    public func performTrim(_ plan: TrimPlan) -> Bool {
        guard let (_, clip) = snapshot.clip(plan.id) else { return false }
        let original = plan.edge == .start ? clip.start : clip.end
        guard plan.target != original else { return false }
        return perform(TrimClip(clipID: plan.id, edge: plan.edge, to: plan.target))
    }

    /// Splits at the playhead (see `splitTargets`).
    @discardableResult
    public func splitAtPlayhead() -> Bool {
        let ids = splitTargets(at: model.playhead)
        guard !ids.isEmpty else { return false }
        let cmds: [any EditCommand] = ids.map { SplitClip(clipID: $0, at: model.playhead) }
        return perform(cmds.count == 1 ? cmds[0] : CompositeCommand(name: "Split", cmds))
    }

    /// Deletes the selection (ripple closes the gaps). Clears the selection on success.
    @discardableResult
    public func deleteSelection(ripple: Bool) -> Bool {
        let ids = deletableSelection
        guard !ids.isEmpty else { return false }
        guard perform(DeleteClips(clipIDs: ids, ripple: ripple)) else { return false }
        model.selection.subtract(ids)
        return true
    }

    /// Toggles a header flag of track `index`.
    @discardableResult
    public func toggle(_ control: TrackHeaderControl, track index: Int) -> Bool {
        guard let t = snapshot.track(index) else { return false }
        let (flag, current): (TrackFlag, Bool) = switch control {
        case .audioMuted: (.audioMuted, t.audioMuted)
        case .videoHidden: (.videoHidden, t.videoHidden)
        case .locked: (.locked, t.locked)
        case .magnetic: (.magnetic, t.magnetic)
        }
        return perform(SetTrackFlag(track: index, flag, !current))
    }

    @discardableResult
    public func addTrack(at index: Int) -> Bool {
        perform(AddTrack(at: min(max(index, 0), snapshot.tracks.count)))
    }

    @discardableResult
    public func removeTrack(at index: Int) -> Bool {
        guard snapshot.track(index) != nil else { return false }
        let gone = Set(snapshot.tracks[index].clips.map(\.id))
        guard perform(RemoveTrack(at: index)) else { return false }
        model.selection.subtract(gone)
        return true
    }
}
