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

/// A planned edge trim of one clip to `target` ticks (`ripple`: later clips follow, ⌥-drag).
public struct TrimPlan: Sendable, Equatable {
    public var id: Int64
    public var track: Int
    public var edge: TrimEdge
    public var target: Int64
    public var guide: Int64?
    public var ripple: Bool = false
}

/// A planned ripple move (⌥-drag): clip `id` leaves `fromTrack` (gap closes) and is inserted
/// on `toTrack` at `start`, in that track's layout without the clip (ticks).
public struct RippleMovePlan: Sendable, Equatable {
    public var id: Int64
    public var fromTrack: Int
    public var toTrack: Int
    public var start: Int64
    public var isValid: Bool
    public var guide: Int64?
}

/// A clip's place during a preview: track index, start and duration in ticks.
public struct ClipPosition: Sendable, Equatable {
    public var track: Int
    public var start: Int64
    public var duration: Int64
    public init(track: Int, start: Int64, duration: Int64) { self.track = track; self.start = start; self.duration = duration }

    /// A clip's span on a known track.
    public struct Placed: Sendable, Equatable { public var id: Int64; public var start: Int64; public var end: Int64 }
}

/// Turns gestures into TimelineEngine commands. Pure planning (`planMove`, `planTrim`)
/// works on a `TimelineSnapshot`; `perform…` methods push one command on `model.undo`.
/// The editor never calls `undo()`/`redo()` (the app owns those).
@MainActor
public struct TimelineEditor {
    public let model: TimelineModel
    public var snapshot: TimelineSnapshot
    /// Custom snap rule; nil uses TimelineEngine's `Snapping` (clip edges, playhead, markers, 0).
    public var snapper: (any TimelineSnapping)?

    public init(model: TimelineModel, snapshot: TimelineSnapshot, snapper: (any TimelineSnapping)? = nil) {
        self.model = model; self.snapshot = snapshot; self.snapper = snapper
    }

    /// Inner ↔ root time map of the shown timeline (identity at the top level).
    var map: TimelineTimeMap { snapshot.timeMap }

    // MARK: Groups

    /// Opens group `id` (a clip of the shown timeline) for editing.
    @discardableResult
    public func openGroup(_ id: Int64) -> Bool {
        guard snapshot.clip(id)?.clip.style == .group else { return false }
        model.openGroups = snapshot.groupPath + [id]
        model.selection = []
        return true
    }

    /// Closes open groups down to `level` (0 = top level). Selects the group just closed.
    @discardableResult
    public func closeGroups(toLevel level: Int) -> Bool {
        let path = snapshot.groupPath
        guard level >= 0, level < path.count else { return false }
        model.openGroups = Array(path.prefix(level))
        model.selection = [path[level]]
        return true
    }

    /// Snap of `edges` (ticks) within `tolerance`, ignoring clips in `excluding`; nil when
    /// snapping is off or nothing is in range. Frame rounding is done by the caller.
    public func snap(edges: [Int64], tolerance: Int64, excluding: Set<Int64>) -> TimelineSnap? {
        guard model.snappingEnabled, tolerance > 0 else { return nil }
        if let snapper {
            return snapper.snap(edges: edges, tolerance: tolerance, snapshot: snapshot, playhead: model.playhead,
                                excluding: excluding)
        }
        // Inside a group the engine helper (top-level clips) does not apply: snap to what is shown.
        if !snapshot.groupPath.isEmpty {
            return EdgeSnapper().snap(edges: edges, tolerance: tolerance, snapshot: snapshot, playhead: model.playhead,
                                      excluding: excluding)
        }
        let s = Snapping(project: model.project, playhead: model.playhead, excluding: excluding, frameSnap: false)
        return s.snap(edges: edges, tolerance: tolerance).map { TimelineSnap(delta: $0.delta, guide: $0.guide.tick) }
    }

    // MARK: Planning

    /// Moves `ids` by a raw `delta` (ticks) and `trackOffset`, then snaps (within `tolerance`
    /// ticks, when snapping is on) and rounds the result to the frame grid.
    public func planMove(ids: [Int64], rawDelta: Int64, trackOffset: Int, tolerance: Int64) -> MovePlan {
        let moving = ids.compactMap { snapshot.clip($0) }
        guard let anchor = moving.min(by: { $0.clip.start < $1.clip.start }) else {
            return MovePlan(ids: ids, delta: 0, trackOffset: 0, isValid: false, guide: nil)
        }
        // Clips stay at or after the timeline origin (inner time 0 inside a group).
        let minStart = (moving.map(\.clip.start).min() ?? 0) - snapshot.timeOrigin
        var delta = max(rawDelta, -minStart)
        var guide: Int64?
        let edges = moving.flatMap { [$0.clip.start + delta, $0.clip.end + delta] }
        if let s = snap(edges: edges, tolerance: tolerance, excluding: Set(ids)) {
            delta += s.delta; guide = s.guide
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
                  c.start + delta >= snapshot.timeOrigin else { return false }
            // Magnetic tracks make room instead of refusing an overlap (MoveClip packs them).
            if dst.magnetic { continue }
            let s = c.start + delta, e = c.end + delta
            for o in dst.clips where !ids.contains(o.id) && o.start < e && s < o.end { return false }
        }
        return true
    }

    /// Moves one edge of clip `id` by `rawDelta` ticks, snapped and frame-rounded, kept at
    /// least one frame long and clear of the neighbouring clips. Media limits are left to
    /// `TrimClip`, which clamps on commit.
    public func planTrim(id: Int64, edge: TrimEdge, rawDelta: Int64, tolerance: Int64,
                         ripple: Bool = false) -> TrimPlan? {
        guard let (track, clip) = snapshot.clip(id), let t = snapshot.track(track), !t.locked else { return nil }
        let original = edge == .start ? clip.start : clip.end
        var target = original + rawDelta
        var guide: Int64?
        if let s = snap(edges: [target], tolerance: tolerance, excluding: [id]) {
            target += s.delta; guide = s.guide
        }
        let q = snapshot.quantize(target)
        if q != target { guide = nil }
        target = q
        let frame = snapshot.frameTicks
        // Neighbours limit growth unless the trim ripples (⌥ or a magnetic track).
        let free = ripple || t.magnetic
        let prevEnd = t.clips.filter { $0.id != id && $0.end <= clip.start }.map(\.end).max() ?? snapshot.timeOrigin
        let nextStart = t.clips.filter { $0.id != id && $0.start >= clip.end }.map(\.start).min()
        // Limits only stop growth: a clip already past one can still shrink (as TrimClip).
        switch edge {
        case .start:
            var limit: Int64 = free ? (ripple ? Int64.min / 4 : snapshot.timeOrigin) : prevEnd
            if let m = clip.minStart { limit = max(limit, m) }
            if target < clip.start { target = max(target, min(limit, clip.start)) }
            target = min(target, clip.end - frame)
        case .end:
            var limit = Int64.max
            if !free, let n = nextStart { limit = n }
            if let m = clip.maxEnd { limit = min(limit, m) }
            if target > clip.end { target = min(target, max(limit, clip.end)) }
            target = max(target, clip.start + frame)
        }
        if guide != nil, guide != target { guide = nil }
        return TrimPlan(id: id, track: track, edge: edge, target: target, guide: guide, ripple: ripple)
    }

    /// Where clips sit while a ripple trim is previewed (only the clips that change).
    public func preview(_ plan: TrimPlan) -> [Int64: ClipPosition] {
        guard let (track, clip) = snapshot.clip(plan.id), let t = snapshot.track(track) else { return [:] }
        var out: [Int64: ClipPosition] = [:]
        let ripple = plan.ripple || t.magnetic
        switch plan.edge {
        case .end:
            let delta = plan.target - clip.end
            out[clip.id] = ClipPosition(track: track, start: clip.start, duration: clip.duration + delta)
            if ripple {
                for o in t.clips where o.id != clip.id && o.start >= clip.end {
                    out[o.id] = ClipPosition(track: track, start: o.start + delta, duration: o.duration)
                }
            }
        case .start:
            let delta = plan.target - clip.start
            if ripple {
                // The clip keeps its start; only its in-point moves, later clips follow.
                out[clip.id] = ClipPosition(track: track, start: clip.start, duration: clip.duration - delta)
                for o in t.clips where o.id != clip.id && o.start >= clip.end {
                    out[o.id] = ClipPosition(track: track, start: o.start - delta, duration: o.duration)
                }
            } else {
                out[clip.id] = ClipPosition(track: track, start: plan.target, duration: clip.end - plan.target)
            }
        }
        return out
    }

    /// Ripple move of one clip: it leaves a closed gap and is inserted at a clip boundary of
    /// the destination track, pushing later clips right. `rawDelta` and `trackOffset` as for
    /// `planMove`; the drop point snaps to the nearest boundary of a clip it would land inside.
    public func planRippleMove(id: Int64, rawDelta: Int64, trackOffset: Int, tolerance: Int64) -> RippleMovePlan? {
        guard let (from, clip) = snapshot.clip(id) else { return nil }
        let to = min(max(from + trackOffset, 0), max(0, snapshot.tracks.count - 1))
        guard let src = snapshot.track(from), let dst = snapshot.track(to) else { return nil }
        // Destination layout without the clip (gap closed when it is the same track).
        let others = destinationLayout(clip: clip, from: from, to: to)
        let origin = snapshot.timeOrigin
        var s = max(origin, clip.start + rawDelta)
        var guide: Int64?
        if let c = others.first(where: { $0.start < s && s < $0.end }) {
            s = s - c.start < c.end - s ? c.start : c.end
            guide = s
        } else if model.snappingEnabled, tolerance > 0 {
            let edges: [Int64] = [origin, model.playhead] + others.flatMap { o -> [Int64] in [o.start, o.end] }
            if let best = edges.min(by: { abs($0 - s) < abs($1 - s) }), abs(best - s) <= tolerance { s = best; guide = s }
        }
        if guide == nil { s = max(origin, snapshot.quantize(s)) }
        let valid = !src.locked && !dst.locked && (s != clip.start || to != from)  // same place: no-op
        return RippleMovePlan(id: id, fromTrack: from, toTrack: to, start: s, isValid: valid, guide: guide)
    }

    /// Clips of `to` as they sit once `clip` has left track `from` (positions only).
    func destinationLayout(clip: TimelineClipItem, from: Int, to: Int) -> [ClipPosition.Placed] {
        guard let dst = snapshot.track(to) else { return [] }
        return dst.clips.filter { $0.id != clip.id }.map { o in
            let shift = (from == to && o.start >= clip.end) ? -clip.duration : 0
            return ClipPosition.Placed(id: o.id, start: o.start + shift, end: o.end + shift)
        }
    }

    /// Where clips sit while a ripple move is previewed.
    public func preview(_ plan: RippleMovePlan) -> [Int64: ClipPosition] {
        guard let (_, clip) = snapshot.clip(plan.id), let src = snapshot.track(plan.fromTrack) else { return [:] }
        var out: [Int64: ClipPosition] = [:]
        if plan.fromTrack != plan.toTrack {
            for o in src.clips where o.id != clip.id && o.start >= clip.end {
                out[o.id] = ClipPosition(track: plan.fromTrack, start: o.start - clip.duration, duration: o.duration)
            }
        }
        for o in destinationLayout(clip: clip, from: plan.fromTrack, to: plan.toTrack) {
            let start = o.start >= plan.start ? o.start + clip.duration : o.start
            out[o.id] = ClipPosition(track: plan.toTrack, start: start, duration: o.end - o.start)
        }
        out[clip.id] = ClipPosition(track: plan.toTrack, start: plan.start, duration: clip.duration)
        return out
    }

    // MARK: Commands

    /// Commands for a move plan, ordered so clips never collide with each other mid-way.
    public func moveCommand(_ plan: MovePlan) -> (any EditCommand)? {
        guard plan.isValid else { return nil }
        let moving = plan.ids.compactMap { snapshot.clip($0) }
        let ordered = moving.sorted { plan.delta > 0 ? $0.clip.start > $1.clip.start : $0.clip.start < $1.clip.start }
        let cmds: [any EditCommand] = ordered.map {
            MoveClip(clipID: $0.clip.id, toTrack: $0.track + plan.trackOffset, start: map.inner($0.clip.start + plan.delta))
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
        if plan.ripple { return perform(RippleTrim(clipID: plan.id, edge: plan.edge, to: map.inner(plan.target))) }
        return perform(TrimClip(clipID: plan.id, edge: plan.edge, to: map.inner(plan.target)))
    }

    @discardableResult
    public func performRippleMove(_ plan: RippleMovePlan) -> Bool {
        guard plan.isValid else { return false }
        return perform(RippleMove(clipID: plan.id, toTrack: plan.toTrack, start: map.inner(plan.start)))
    }

    /// Splits at the playhead (see `splitTargets`).
    @discardableResult
    public func splitAtPlayhead() -> Bool {
        let ids = splitTargets(at: model.playhead)
        guard !ids.isEmpty else { return false }
        let at = map.inner(model.playhead)
        let cmds: [any EditCommand] = ids.map { SplitClip(clipID: $0, at: at) }
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
        if let group = snapshot.groupPath.last { return perform(SetGroupTrackFlag(group: group, track: index, flag, !current)) }
        return perform(SetTrackFlag(track: index, flag, !current))
    }

    /// Adds a timeline marker at `t` (frame-rounded by the command); an existing marker there is renamed.
    @discardableResult
    public func addMarker(at t: Int64, name: String = "") -> Bool {
        // The same marker already there would be an empty undo entry.
        let q = snapshot.quantize(max(0, t))
        guard !snapshot.markers.contains(where: { $0.time == q && $0.name == name }) else { return false }
        return perform(AddMarker(at: max(0, t), name: name))
    }

    /// The marker nearest `t` within `tolerance` ticks.
    public func marker(near t: Int64, tolerance: Int64) -> Marker? {
        snapshot.markers.filter { abs($0.time - t) <= tolerance }.min { abs($0.time - t) < abs($1.time - t) }
    }

    /// Moves the marker at `from` to `to` (ticks; the command frame-snaps).
    @discardableResult
    public func moveMarker(from: Int64, to: Int64) -> Bool {
        guard snapshot.quantize(max(0, to)) != from, snapshot.markers.contains(where: { $0.time == from }) else { return false }
        return perform(MoveMarker(from: from, to: max(0, to)))
    }

    /// Renames the marker at `time`.
    @discardableResult
    public func renameMarker(at time: Int64, to name: String) -> Bool {
        guard let m = snapshot.markers.first(where: { $0.time == time }), m.name != name else { return false }
        return perform(RenameMarker(at: time, to: name))
    }

    /// Selected clips whose speed can change (not images, callouts or shaders).
    public var retimableSelection: [Int64] {
        snapshot.tracks.filter { !$0.locked }.flatMap(\.clips)
            .filter { model.selection.contains($0.id) && ![.image, .callout, .shader].contains($0.style) }
            .map(\.id)
    }

    /// Sets the speed of the retimable selected clips (one undo step). `speed` > 0, e.g. 2 = 2×.
    /// With `ripple`, later clips follow the length change; without it a clip that would grow
    /// into its neighbour makes the command fail.
    @discardableResult
    public func setSpeed(_ speed: Double, ripple: Bool = false) -> Bool {
        // Clips already at `speed` would land on the undo stack as empty entries.
        let ids = retimableSelection.filter { id in snapshot.clip(id).map { abs($0.clip.speed - speed) > 1e-6 } ?? false }
        guard speed > 0, speed.isFinite, !ids.isEmpty else { return false }
        let r = Rational(Int64((speed * 1000).rounded()), 1000)
        let cmds: [any EditCommand] = ids.map { SetClipSpeed(clipID: $0, speed: r, ripple: ripple) }
        return perform(cmds.count == 1 ? cmds[0] : CompositeCommand(name: "Clip Speed", cmds))
    }

    /// Holds the last frame of each retimable selected clip for `seconds` (frame-rounded).
    @discardableResult
    public func extendFrame(seconds: Double) -> Bool {
        let ids = retimableSelection.filter { id in snapshot.clip(id).map { !$0.clip.videoSpans.isEmpty } ?? false }
        let ticks = snapshot.quantize(Int64((seconds * Double(snapshot.editRate)).rounded()))
        guard ticks > 0, !ids.isEmpty else { return false }
        let inner = map.isIdentity ? ticks : max(1, Int64((Double(ticks) / map.scale).rounded()))
        let cmds: [any EditCommand] = ids.map { ExtendFrame(clipID: $0, duration: inner) }
        return perform(cmds.count == 1 ? cmds[0] : CompositeCommand(name: "Extend Frame", cmds))
    }

    // MARK: Library (effects, transitions)

    /// Adds library effect `name` (defaults from `TimelineLibrary`; unknown names get no
    /// parameters) to clip `clipID`. Locked tracks refuse.
    @discardableResult
    public func addEffect(named name: String, to clipID: Int64) -> Bool {
        guard let (track, _) = snapshot.clip(clipID), snapshot.track(track)?.locked == false else { return false }
        let preset = TimelineLibrary.effect(named: name)
        return perform(AddEffect(clipID: clipID, name: name, category: preset?.category ?? "categoryVisualEffects",
                                 parameters: (preset?.parameters ?? []).map { ($0.key, $0.value) }))
    }

    /// Removes the effect at combined `index` (`TimelineEffectRef.index`) from clip `clipID`.
    @discardableResult
    public func removeEffect(at index: Int, from clipID: Int64) -> Bool {
        guard let (track, c) = snapshot.clip(clipID), snapshot.track(track)?.locked == false,
              c.effects.contains(where: { $0.index == index }) else { return false }
        return perform(RemoveEffect(clipID: clipID, index: index))
    }

    /// Selected clips on unlocked tracks that can take an effect or transition.
    var decoratableSelection: [TimelineClipItem] {
        snapshot.tracks.filter { !$0.locked }.flatMap(\.clips).filter { model.selection.contains($0.id) }
    }

    /// Adds library effect `name` to every selected clip on an unlocked track (one undo step).
    @discardableResult
    public func applyEffect(named name: String) -> Bool {
        let ids = decoratableSelection.map(\.id)
        guard !ids.isEmpty else { return false }
        let preset = TimelineLibrary.effect(named: name)
        let cmds: [any EditCommand] = ids.map {
            AddEffect(clipID: $0, name: name, category: preset?.category ?? "categoryVisualEffects",
                      parameters: (preset?.parameters ?? []).map { ($0.key, $0.value) })
        }
        return perform(cmds.count == 1 ? cmds[0] : CompositeCommand(name: "Add Effect", cmds))
    }

    /// Transition sides `applyTransition` would add: the cut under the playhead (two touching
    /// clips on an unlocked track, one of them selected or nothing selected, within
    /// `tolerance` ticks); otherwise both edges of each selected clip, two-sided where the
    /// edge touches a neighbour, one-sided (fade in/out) where it does not. No duplicates.
    public func transitionTargets(tolerance: Int64) -> [(left: Int64?, right: Int64?)] {
        let sel = model.selection
        for t in snapshot.tracks where !t.locked {
            for (a, b) in zip(t.clips, t.clips.dropFirst()) where a.end == b.start
                && abs(model.playhead - a.end) <= tolerance
                && (sel.isEmpty || sel.contains(a.id) || sel.contains(b.id)) {
                return [(a.id, b.id)]
            }
        }
        var out: [(left: Int64?, right: Int64?)] = []
        func add(_ l: Int64?, _ r: Int64?) {
            if !out.contains(where: { $0.left == l && $0.right == r }) { out.append((l, r)) }
        }
        for t in snapshot.tracks where !t.locked {
            for c in t.clips where sel.contains(c.id) {
                add(t.clips.first { $0.end == c.start }?.id, c.id)
                add(c.id, t.clips.first { $0.start == c.end }?.id)
            }
        }
        return out
    }

    /// Adds library transition `name` where `transitionTargets` says (one undo step).
    @discardableResult
    public func applyTransition(named name: String, tolerance: Int64 = 0) -> Bool {
        let targets = transitionTargets(tolerance: tolerance)
        guard !targets.isEmpty else { return false }
        let cmds: [any EditCommand] = targets.map { t in
            let d = transitionDuration(left: t.left, right: t.right, name: name)
            return AddTransition(name: name, leftClipID: t.left, rightClipID: t.right,
                                 duration: map.isIdentity ? d : max(1, Int64((Double(d) / map.scale).rounded())))
        }
        return perform(cmds.count == 1 ? cmds[0] : CompositeCommand(name: "Add Transition", cmds))
    }

    /// Media limit of the edge a trim plan drags (`minStart` / `maxEnd`, ticks), nil when the
    /// clip's media is unbounded there; `reached` when the plan's target sits on it.
    public func mediaLimit(for plan: TrimPlan) -> (tick: Int64, reached: Bool)? {
        guard let c = snapshot.clip(plan.id)?.clip else { return nil }
        switch plan.edge {
        case .start:
            guard let m = c.minStart else { return nil }
            // A ripple start trim keeps the clip's start and moves its in-point instead.
            return (m, plan.target <= m)
        case .end:
            guard let m = c.maxEnd else { return nil }
            return (m, plan.target >= m)
        }
    }

    /// Which clip edges a transition dropped at tick `t` on `track` covers: a cut between two
    /// touching clips within `tolerance` → both; otherwise the nearer edge of the clip under
    /// `t` (start → fade in, `right` only; end → fade out, `left` only).
    public func transitionTarget(track: Int, at t: Int64, tolerance: Int64) -> (left: Int64?, right: Int64?)? {
        guard let tr = snapshot.track(track), !tr.locked else { return nil }
        let clips = tr.clips
        for (a, b) in zip(clips, clips.dropFirst()) where a.end == b.start && abs(t - a.end) <= tolerance {
            return (a.id, b.id)
        }
        guard let c = clips.first(where: { $0.start <= t && t < $0.end }) else { return nil }
        return t - c.start < c.end - t ? (nil, c.id) : (c.id, nil)
    }

    /// Track ticks a transition on these sides spans (for highlighting), or nil.
    public func transitionSpan(left: Int64?, right: Int64?, name: String? = nil) -> (track: Int, start: Int64, end: Int64)? {
        let d = transitionDuration(left: left, right: right, name: name)
        switch (left.flatMap { snapshot.clip($0) }, right.flatMap { snapshot.clip($0) }) {
        case let (l?, _?): return (l.track, l.clip.end - d / 2, l.clip.end - d / 2 + d)
        case let (l?, nil): return (l.track, l.clip.end - d, l.clip.end)
        case let (nil, r?): return (r.track, r.clip.start, r.clip.start + d)
        default: return nil
        }
    }

    /// Default length of library transition `name` (`TransitionPreset.defaultSeconds`, else
    /// `TimelineLibrary.defaultTransitionSeconds`) for a one-sided transition (a clip's start or
    /// end) and **half of it on a cut between two clips** (Camtasia: 1 s and 0.5 s,
    /// transitions.md TR2 [obs]; halving other presets' lengths [inf]), at most half of each
    /// covered clip, frame-rounded, at least one frame. Ticks.
    public func transitionDuration(left: Int64?, right: Int64?, name: String? = nil) -> Int64 {
        var secs = name.flatMap { TimelineLibrary.transition(named: $0)?.defaultSeconds } ?? TimelineLibrary.defaultTransitionSeconds
        if left != nil, right != nil { secs /= 2 }
        var d = Int64((secs * Double(snapshot.editRate)).rounded())
        for id in [left, right].compactMap({ $0 }) {
            if let c = snapshot.clip(id)?.clip { d = min(d, c.duration / 2) }
        }
        let f = snapshot.frameTicks
        return max(f, (d / f) * f)
    }

    @discardableResult
    public func addTransition(named name: String, left: Int64?, right: Int64?) -> Bool {
        guard left != nil || right != nil else { return false }
        let d = transitionDuration(left: left, right: right, name: name)
        return perform(AddTransition(name: name, leftClipID: left, rightClipID: right,
                                     duration: map.isIdentity ? d : max(1, Int64((Double(d) / map.scale).rounded()))))
    }

    @discardableResult
    public func removeTransition(left: Int64?, right: Int64?) -> Bool {
        perform(RemoveTransition(leftClipID: left, rightClipID: right))
    }

    @discardableResult
    public func removeMarker(near t: Int64, tolerance: Int64) -> Bool {
        guard let m = marker(near: t, tolerance: tolerance) else { return false }
        return perform(RemoveMarker(at: m.time))
    }
}
