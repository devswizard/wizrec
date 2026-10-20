import Foundation
import TSCProjKit

// MARK: - Rewriting the top-level track list

/// Copy-on-demand edit of the whole top-level track list, for commands that
/// may add tracks. Commits the new `tracks` array (renumbered) and
/// `trackAttributes` through one `ValueSwap`.
@MainActor
struct TracksRewrite {
    let project: Project
    private(set) var items: [JSON]
    private var copied: [Bool]
    private var attrs: [JSON]?

    init(_ project: Project) throws {
        self.project = project
        items = try M2.sceneTracksArray(project).items
        copied = items.map { _ in false }
        attrs = M2.trackAttributesPath.resolve(in: project.root)?.array?.items
    }

    var count: Int { items.count }

    mutating func track(_ i: Int) throws -> JSONObject {
        guard items.indices.contains(i), let o = items[i].object else { throw EditError.trackNotFound(i) }
        if copied[i] { return o }
        let c = o.copy()
        items[i] = .object(c)
        copied[i] = true
        return c
    }

    /// Inserts an empty track (and its attributes) at `i`.
    mutating func insertTrack(at i: Int) {
        items.insert(.object(ProjectTemplate.track(index: i)), at: i)
        copied.insert(true, at: i)
        if var a = attrs {
            a.insert(.object(ProjectTemplate.trackAttributes()), at: min(i, a.count))
            attrs = a
        }
    }

    func isMagnetic(_ i: Int) -> Bool {
        guard let a = attrs, a.indices.contains(i) else { return false }
        return a[i].object?["magnetic"]?.bool ?? false
    }

    func commit(_ swap: inout ValueSwap) throws {
        var edits: [(path: JSONPath, new: JSON)] = [(JSONPath.sceneTracks, .array(M2.renumbered(items)))]
        if let attrs, attrs.count != (M2.trackAttributesPath.resolve(in: project.root)?.array?.count ?? -1) {
            edits.append((M2.trackAttributesPath, J.arr(attrs)))
        }
        try swap.commit(edits, in: project)
    }
}

/// Clip `id` on a top-level track (throws otherwise).
@MainActor
private func topLevel(_ id: Int64, _ project: Project) throws -> (loc: ClipLocation, track: Int) {
    let loc = try Locator.locate(id, in: project)
    guard let t = loc.topLevelTrack else { throw EditError.invalid("clip \(id) is not on a top-level track") }
    return (loc, t)
}

private let transformKeys: Set<String> = [
    "translation0", "translation1", "translation2", "rotation0", "rotation1", "rotation2",
    "scale0", "scale1", "scale2", "opacity",
]

/// Trims a copied clip to the window `[lo, hi)` of its track time; nil when it lies outside.
@MainActor
private func trimmed(_ clip: JSONObject, to lo: Int64, _ hi: Int64) throws -> JSONObject? {
    let s = clip["start"]?.int ?? 0, e = s + (clip["duration"]?.int ?? 0)
    guard e > lo, s < hi else { return nil }
    let c = clip.copy()
    if s < lo { for p in TrimClip.timedParts(c) { try TrimClip.setStart(p, to: lo) } }
    if e > hi { for p in TrimClip.timedParts(c) { try TrimClip.setEnd(p, to: hi) } }
    return c
}

/// True when a parameters dict holds only Camtasia defaults (no animation).
private func isIdentity(_ params: JSONObject?) -> Bool {
    for (k, v) in params?.entries ?? [] {
        if v.object?["keyframes"]?.array?.items.isEmpty == false { return false }
        guard let d = v.number?.double ?? v.object?["defaultValue"]?.double else { continue }
        if abs(d - ParamWriter.defaultValue(k)) > 1e-9 { return false }
    }
    return true
}

// MARK: - Group / ungroup

/// Groups top-level clips (on one or more tracks) into a `Group` placed on
/// the lowest of their tracks, spanning their earliest start to latest end.
/// Observed Camtasia behaviour (group-edits.md §1):
///
/// - Size: `widthAttr` × `heightAttr` is the union of the members'
///   on-canvas rectangles (natural size × scale around their position)
///   [obs]; rotation and crop are ignored [?]. Without a visual member the
///   group is canvas-sized [inf].
/// - Re-centring: the group's `translation0/1` is the centre of that box and
///   every member's position (constant and keyframe values) shifts the
///   opposite way, so nothing moves on screen [obs]. Zero offsets are not
///   written [inf]. Other member parameters are untouched [obs].
/// - Inner tracks: one per source track, bottom to top, with clip times
///   relative to the group start; flags inline on the track [obs]. Emptied
///   top-level tracks stay [obs].
/// - Group JSON: parameters = bare numbers: the offset, `geometryCrop0…3`
///   0.0, `volume` 1.0 [obs, §1a]; members' new position keys are bare and
///   go first (`GroupGeometry.insert`) [obs];
///   `attributes` {ident "Group n", widthAttr, heightAttr, maxDurationAttr 0,
///   gain 1.0, mixToMono false} [obs]; decimal `mediaStart` 0.0 /
///   `mediaDuration` [obs]; `isOpen` false metadata [obs]. n = groups in
///   the project + 1 [inf].
/// - Transitions whose clips are all grouped move inside; ones that link a
///   grouped and an ungrouped clip are removed.
/// - Other clips on the lowest track must not overlap the group's span.
@MainActor
public final class GroupClips: EditCommand {
    public let name = "Group"
    public let clipIDs: [Int64]
    public private(set) var groupID: Int64?
    private var swap = TrackSwap()

    public init(clipIDs: [Int64]) { self.clipIDs = clipIDs }

    public func apply(to project: Project) throws {
        var seen = Set<Int64>()
        let ids = clipIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw EditError.invalid("nothing to group") }
        let found = try ids.map { try topLevel($0, project) }
        let used = Array(Set(found.map(\.track))).sorted()
        guard let lowest = used.first else { throw EditError.invalid("nothing to group") }
        let gStart = found.map { $0.loc.clip["start"]?.int ?? 0 }.min() ?? 0
        let gEnd = found.map { ($0.loc.clip["start"]?.int ?? 0) + ($0.loc.clip["duration"]?.int ?? 0) }.max() ?? 0

        var edits = TrackEdits(project)
        var inner: [JSON] = []
        for (n, ti) in used.enumerated() {
            let track = try edits.topTrack(ti)
            guard let medias = track["medias"]?.array else { continue }
            let inTrack = ids.filter { id in found.contains { $0.loc.clip.clipID == id && $0.track == ti } }
            let moved = medias.items.compactMap(\.object).filter { inTrack.contains($0.clipID ?? -1) }
            medias.items.removeAll { inTrack.contains($0.object?.clipID ?? -1) }
            let it = ProjectTemplate.groupTrack(index: n)
            for c in moved { Magnetic.shift(c, by: -gStart) }
            it["medias"] = J.arr(moved.sorted { ($0["start"]?.int ?? 0) < ($1["start"]?.int ?? 0) }.map { .object($0) })
            if let tr = track["transitions"]?.array {
                var inside: [JSON] = []
                tr.items.removeAll { t in
                    guard let o = t.object else { return false }
                    let refs = [o["leftMedia"]?.int, o["rightMedia"]?.int].compactMap { $0 }
                    let mine = refs.filter(seen.contains)
                    guard !mine.isEmpty else { return false }
                    if mine.count == refs.count { inside.append(t) }
                    return true
                }
                if !inside.isEmpty { TransitionEdit.transitions(it).items.append(contentsOf: inside) }
            }
            inner.append(.object(it))
        }
        // Bounding box of the members on the canvas, and re-centring.
        let movedClips = inner.compactMap(\.object).flatMap(trackClips)
        let rects = movedClips.compactMap { GroupGeometry.rect($0, project) }
        var size = (w: project.width, h: project.height), centre = (x: 0.0, y: 0.0)
        if let minX = rects.map(\.minX).min(), let maxX = rects.map(\.maxX).max(),
           let minY = rects.map(\.minY).min(), let maxY = rects.map(\.maxY).max() {
            size = (maxX - minX, maxY - minY)
            centre = ((minX + maxX) / 2, (minY + maxY) / 2)
        }
        for c in movedClips {
            guard let o = GroupGeometry.owner(c), GroupGeometry.naturalSize(c, project) != nil else { continue }
            if centre.x != 0 { GroupGeometry.map(GroupGeometry.params(o), "translation0") { $0 - centre.x } }
            if centre.y != 0 { GroupGeometry.map(GroupGeometry.params(o), "translation1") { $0 - centre.y } }
        }
        // Bare numbers: offset, geometry crops, volume [obs, group-edits.md §1a].
        var gParams: [(String, JSON)] = []
        if centre.x != 0 { gParams.append(("translation0", J.dbl(centre.x))) }
        if centre.y != 0 { gParams.append(("translation1", J.dbl(centre.y))) }
        gParams += (0..<4).map { ("geometryCrop\($0)", J.dbl(0)) }
        gParams.append(("volume", J.dbl(1)))

        let base = try edits.topTrack(lowest)
        for o in trackClips(base) {
            let s = o["start"]?.int ?? 0, e = s + (o["duration"]?.int ?? 0)
            if s < gEnd && gStart < e { throw EditError.invalid("group would overlap clip \(o.clipID ?? -1)") }
        }
        var groups = 0
        for t in project.tracks { for c in t.clips { c.walk { x, _ in if x.kind == .group { groups += 1 } } } }
        let id = project.maxID + 1
        let duration = gEnd - gStart
        let group = JSONObject([
            ("id", J.int(id)), ("_type", .string("Group")),
            ("parameters", J.obj(gParams)),
            ("tracks", J.arr(inner)),
            ("attributes", J.obj([
                ("ident", .string("Group \(groups + 1)")), ("widthAttr", J.dbl(size.w)),
                ("heightAttr", J.dbl(size.h)), ("maxDurationAttr", J.int(0)),
                ("gain", J.dbl(1)), ("mixToMono", .bool(false)), ("assetProperties", J.emptyArray),
            ])),
            ("effects", J.emptyArray), ("start", J.int(gStart)), ("duration", J.int(duration)),
            ("mediaStart", J.dbl(0)), ("mediaDuration", J.dbl(Double(duration))), ("scalar", J.int(1)),
            ("metadata", J.obj([
                ("audiateLinkedSession", .string("")), ("clipSpeedAttribute", J.typedBool(false)),
                ("colorAttribute", J.obj([("type", .string("color")), ("value", J.arr([J.int(0), J.int(0), J.int(0), J.int(0)]))])),
                ("effectApplied", .string("none")), ("isOpen", J.typedBool(false)),
            ])),
            ("animationTracks", J.emptyObject),
        ])
        if Magnetic.isMagnetic(project, track: lowest) {
            Magnetic.insert(group, into: base, start: gStart)
        } else {
            try M2.insertSorted(group, into: base)
        }
        try edits.packMagnetic()
        try edits.commit(&swap)
        groupID = id
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); groupID = nil }
}

/// Ungroups a top-level group: inner track `i` goes to top-level track
/// `group track + i` (tracks are added at the top when missing). Inner clips
/// are cut to the group's visible window and placed at
/// `group.start + (inner.start − group.mediaStart)`; clips outside the window
/// are dropped; stills absorb the cut in `trimStartSum` [obs, group-edits.md §6].
///
/// The group's constant position and scale are folded into each released
/// visual clip [obs]: `translation = group.translation + group.scale ×
/// child.translation` per axis, `scale = group.scale × child.scale`
/// (keyframe values too); a constant position that comes out as 0 is
/// removed [obs]. Throws when the group has a non-unit speed, rotation [?],
/// opacity, crop, a non-unit volume, animated geometry or effects (not
/// composable yet [inf]), or when a placed clip would overlap.
@MainActor
public final class UngroupClip: EditCommand {
    public let name = "Ungroup"
    public let clipID: Int64
    /// Top-level ids of the released clips after `apply`.
    public private(set) var releasedIDs: [Int64] = []
    private var swap = ValueSwap()

    public init(clipID: Int64) { self.clipID = clipID }

    public func apply(to project: Project) throws {
        let (loc, gTrack) = try topLevel(clipID, project)
        let g = loc.clip
        guard g.clipType == "Group" else { throw EditError.invalid("clip \(clipID) is not a group") }
        let t = try Timing(g)
        guard t.scalar == Rational(1) else { throw EditError.invalid("ungrouping a sped-up group is not supported") }
        let gp = g["parameters"]?.object
        let composable: Set<String> = ["translation0", "translation1", "scale0", "scale1"]
        let rest = gp.map { JSONObject($0.entries.filter { !composable.contains($0.key) }.map { ($0.key, $0.value) }) }
        guard isIdentity(rest), (g["effects"]?.array?.count ?? 0) == 0,
              !composable.contains(where: { GroupGeometry.isAnimated(gp, $0) }) else {
            throw EditError.invalid("group \(clipID) has a transform or effects; ungrouping would lose them")
        }
        let gx = GroupGeometry.constant(gp, "translation0", 0), gy = GroupGeometry.constant(gp, "translation1", 0)
        let sx = GroupGeometry.constant(gp, "scale0", 1), sy = GroupGeometry.constant(gp, "scale1", 1)
        func compose(_ piece: JSONObject) {
            guard piece.clipType != "AMFile", let o = GroupGeometry.owner(piece) else { return }
            var mapped: [String] = []
            func apply(_ k: String, _ f: @escaping (Double) -> Double) {
                GroupGeometry.map(GroupGeometry.params(o), k, f); mapped.append(k)
            }
            if gx != 0 || sx != 1 { apply("translation0") { gx + sx * $0 } }
            if gy != 0 || sy != 1 { apply("translation1") { gy + sy * $0 } }
            if sx != 1 { apply("scale0") { sx * $0 } }
            if sy != 1 { apply("scale1") { sy * $0 } }
            guard let p = o["parameters"]?.object else { return }
            for k in mapped where k.hasPrefix("translation") && !GroupGeometry.isAnimated(p, k)
                && p[k] != nil && GroupGeometry.constant(p, k, 1) == 0 {
                p[k] = nil
            }
        }
        let lo = Exact.floor(t.mediaStart), hi = lo + t.duration
        let offset = t.start - lo

        var rw = try TracksRewrite(project)
        let base = try rw.track(gTrack)
        base["medias"]?.array?.items.remove(at: loc.index)
        base["transitions"]?.array?.items.removeAll {
            $0.object?["leftMedia"]?.int == clipID || $0.object?["rightMedia"]?.int == clipID
        }
        var released: [Int64] = []
        for (i, inner) in (g["tracks"]?.array?.items.compactMap(\.object) ?? []).enumerated() {
            let ti = gTrack + i
            while ti >= rw.count { rw.insertTrack(at: rw.count) }
            let dest = try rw.track(ti)
            var keptIDs = Set<Int64>()
            for c in trackClips(inner) {
                guard let piece = try trimmed(c, to: lo, hi) else { continue }
                Magnetic.shift(piece, by: offset)
                compose(piece)
                let s = piece["start"]?.int ?? 0
                _ = try M2.trackForInsert(dest, start: s, duration: piece["duration"]?.int ?? 0, track: ti)
                try M2.insertSorted(piece, into: dest)
                if let id = piece.clipID { keptIDs.insert(id); released.append(id) }
            }
            for tr in inner["transitions"]?.array?.items ?? [] {
                guard let o = tr.object else { continue }
                let refs = [o["leftMedia"]?.int, o["rightMedia"]?.int].compactMap { $0 }
                if !refs.isEmpty, refs.allSatisfy(keptIDs.contains) {
                    TransitionEdit.transitions(dest).items.append(.object(o.copy()))
                }
            }
            if rw.isMagnetic(ti) { Magnetic.pack(dest) }
        }
        if rw.isMagnetic(gTrack) { Magnetic.pack(base) }
        try rw.commit(&swap)
        releasedIDs = released
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); releasedIDs = [] }
}

// MARK: - Stitch / unstitch

/// Joins touching clips of one source on one top-level track into a
/// `StitchedMedia` (time-mapping.md §4): segments laid end to end from 0,
/// each keeping its own `mediaStart`/`mediaDuration`.
///
/// Shape [obs, vlog]: `{id, _type, minMediaStart: 0.0, attributes, parameters,
/// medias, effects, start, duration, mediaStart, mediaDuration, scalar,
/// metadata, animationTracks}`. Geometry lives on the stitched parent as bare
/// numbers (transform keys of the first segment move up; other segments lose
/// theirs), crops stay on the segments, the parent gets crops 0.0 and
/// `volume` 1.0 [obs]. `metadata` comes from the first clip. Clips must be
/// `UnifiedMedia`/`VMFile`/`ScreenVMFile`/`AMFile` of the same type and
/// source, speed 1, touching in time order. Transitions between them are
/// removed; outer ones are relinked to the stitched clip.
@MainActor
public final class StitchClips: EditCommand {
    public let name = "Stitch"
    public let clipIDs: [Int64]
    public private(set) var stitchedID: Int64?
    private var swap = TrackSwap()

    public init(clipIDs: [Int64]) { self.clipIDs = clipIDs }

    public func apply(to project: Project) throws {
        var seen = Set<Int64>()
        let ids = clipIDs.filter { seen.insert($0).inserted }
        guard ids.count >= 2 else { throw EditError.invalid("stitching needs at least two clips") }
        let found = try ids.map { try topLevel($0, project) }
        guard let ti = found.first?.track, found.allSatisfy({ $0.track == ti }) else {
            throw EditError.invalid("stitched clips must be on one track")
        }
        let clips = found.map(\.loc.clip).sorted { ($0["start"]?.int ?? 0) < ($1["start"]?.int ?? 0) }
        let type = clips[0].clipType
        guard ["UnifiedMedia", "VMFile", "ScreenVMFile", "AMFile"].contains(type), clips.allSatisfy({ $0.clipType == type })
        else { throw EditError.invalid("only clips of one media type can be stitched") }
        let src = Clip(clips[0]).referencedSourceIDs
        guard src.count == 1, clips.allSatisfy({ Clip($0).referencedSourceIDs == src }) else {
            throw EditError.invalid("stitched clips must come from one source")
        }
        for (a, b) in zip(clips, clips.dropFirst())
        where (a["start"]?.int ?? 0) + (a["duration"]?.int ?? 0) != b["start"]?.int {
            throw EditError.invalid("clips \(a.clipID ?? -1) and \(b.clipID ?? -1) do not touch")
        }
        for c in clips { for p in TrimClip.timedParts(c) where try Timing(p).scalar != Rational(1) {
            throw EditError.invalid("clip \(c.clipID ?? -1) has a speed change")
        } }

        var edits = TrackEdits(project)
        let track = try edits.topTrack(ti)
        guard let medias = track["medias"]?.array else { throw EditError.trackNotFound(ti) }
        let first = clips[0].clipID ?? -1, last = clips[clips.count - 1].clipID ?? -1
        let pos = medias.items.firstIndex { $0.object?.clipID == first } ?? 0
        let start = clips[0]["start"]?.int ?? 0
        var segs: [JSON] = []
        var moved: [(String, JSON)] = []
        var total: Int64 = 0
        for (n, c) in clips.enumerated() {
            let seg = c.copy()
            Magnetic.shift(seg, by: total - (seg["start"]?.int ?? 0))
            let visual = seg.clipType == "UnifiedMedia" ? seg["video"]?.object : seg
            if let params = visual?["parameters"]?.object {
                for k in params.keys where transformKeys.contains(k) {
                    if n == 0, let v = params[k] {
                        let o = v.object
                        let bare = o.flatMap { $0["keyframes"]?.array?.items.isEmpty ?? true ? $0["defaultValue"] : nil }
                        moved.append((k, bare ?? v))
                    }
                    params[k] = nil
                }
            }
            total += seg["duration"]?.int ?? 0
            segs.append(.object(seg))
        }
        let audioAttrs = (type == "UnifiedMedia" ? clips[0]["audio"]?.object : clips[0])?["attributes"]?.object
        let id = project.maxID + 1
        let stitched = JSONObject([
            ("id", J.int(id)), ("_type", .string("StitchedMedia")), ("minMediaStart", J.dbl(0)),
            ("attributes", J.obj([
                ("ident", .string(Clip(clips[0]).name ?? Clip(clips[0]).video?.name ?? "")),
                ("gain", audioAttrs?["gain"] ?? J.dbl(1)), ("mixToMono", .bool(false)),
                ("loudnessNormalization", .bool(true)), ("sourceFileOffset", J.int(0)),
            ])),
            ("parameters", J.obj(moved + (0..<4).map { ("geometryCrop\($0)", J.dbl(0)) } + [("volume", J.dbl(1))])),
            ("medias", J.arr(segs)), ("effects", J.emptyArray),
            ("start", J.int(start)), ("duration", J.int(total)), ("mediaStart", J.int(0)),
            ("mediaDuration", J.int(total)), ("scalar", J.int(1)),
            ("metadata", clips[0]["metadata"]?.copy() ?? MediaJSON.metadata(defaultScale: nil)),
            ("animationTracks", J.emptyObject),
        ])
        medias.items.removeAll { seen.contains($0.object?.clipID ?? -1) }
        medias.items.insert(.object(stitched), at: min(pos, medias.count))
        if let tr = track["transitions"]?.array {
            tr.items.removeAll { t in
                guard let o = t.object else { return false }
                let l = o["leftMedia"]?.int, r = o["rightMedia"]?.int
                if let l, seen.contains(l), l != last { return true }
                if let r, seen.contains(r), r != first { return true }
                if l == last { o["leftMedia"] = J.int(id) }
                if r == first { o["rightMedia"] = J.int(id) }
                return false
            }
        }
        try edits.commit(&swap)
        stitchedID = id
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); stitchedID = nil }
}

/// Splits a top-level `StitchedMedia` back into separate clips: each
/// segment's part inside the stitched clip's window becomes a clip at
/// `stitched.start + (segment.start − mediaStart)`. The stitched clip's
/// transform keys and effects are copied onto each piece's visual part, and
/// its `metadata` onto pieces without one [inf]. Segment ids are kept. Speed
/// ≠ 1 throws [inf, not supported yet].
@MainActor
public final class UnstitchClip: EditCommand {
    public let name = "Unstitch"
    public let clipID: Int64
    public private(set) var pieceIDs: [Int64] = []
    private var swap = TrackSwap()

    public init(clipID: Int64) { self.clipID = clipID }

    public func apply(to project: Project) throws {
        let (loc, ti) = try topLevel(clipID, project)
        let s = loc.clip
        guard s.clipType == "StitchedMedia" else { throw EditError.invalid("clip \(clipID) is not stitched") }
        let t = try Timing(s)
        guard t.scalar == Rational(1) else { throw EditError.invalid("unstitching a sped-up clip is not supported") }
        let lo = Exact.floor(t.mediaStart), hi = lo + t.duration
        var edits = TrackEdits(project)
        let track = try edits.topTrack(ti)
        guard let medias = track["medias"]?.array else { throw EditError.trackNotFound(ti) }
        let parentParams = s["parameters"]?.object
        var pieces: [JSONObject] = []
        for seg in s["medias"]?.array?.items.compactMap(\.object) ?? [] {
            guard let p = try trimmed(seg, to: lo, hi) else { continue }
            Magnetic.shift(p, by: t.start - lo)
            if let visual = p.clipType == "UnifiedMedia" ? p["video"]?.object : p {
                if visual["parameters"]?.object == nil { visual["parameters"] = J.emptyObject }
                for (k, v) in parentParams?.entries ?? [] where transformKeys.contains(k) && visual["parameters"]?.object?[k] == nil {
                    visual["parameters"]?.object?[k] = v.copy()
                }
                for e in s["effects"]?.array?.items ?? [] {
                    if visual["effects"]?.array == nil { visual["effects"] = J.emptyArray }
                    visual["effects"]?.array?.items.append(e.copy())
                }
            }
            if p["metadata"] == nil, let md = s["metadata"] {
                let anim = p["animationTracks"]
                p["animationTracks"] = nil
                p["metadata"] = md.copy()
                if let anim { p["animationTracks"] = anim }
            }
            pieces.append(p)
        }
        guard !pieces.isEmpty else { throw EditError.invalid("stitched clip shows no segment") }
        medias.items.remove(at: loc.index)
        medias.items.insert(contentsOf: pieces.map { .object($0) }, at: loc.index)
        let firstID = pieces[0].clipID, lastID = pieces[pieces.count - 1].clipID
        for tr in track["transitions"]?.array?.items.compactMap(\.object) ?? [] {
            if tr["leftMedia"]?.int == clipID, let lastID { tr["leftMedia"] = J.int(lastID) }
            if tr["rightMedia"]?.int == clipID, let firstID { tr["rightMedia"] = J.int(firstID) }
        }
        try edits.commit(&swap)
        pieceIDs = pieces.compactMap(\.clipID)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); pieceIDs = [] }
}

// MARK: - Detach audio

/// Splits a top-level `UnifiedMedia` into its video clip (in place, same
/// track) and its audio clip on the track above — reused when free over the
/// clip's span, otherwise a new track is inserted there [inf]. Both keep
/// their ids and get the parent's `metadata` (the audio without
/// `default-scale`); the parent's effects (audio effects [obs]) go to the
/// audio clip; an empty audio `ident` takes the video's. Transitions on the
/// parent now reference the video clip.
@MainActor
public final class DetachAudio: EditCommand {
    public let name = "Separate Video and Audio"
    public let clipID: Int64
    public private(set) var videoID: Int64?
    public private(set) var audioID: Int64?
    private var swap = ValueSwap()

    public init(clipID: Int64) { self.clipID = clipID }

    public func apply(to project: Project) throws {
        let (loc, ti) = try topLevel(clipID, project)
        let u = loc.clip
        guard u.clipType == "UnifiedMedia", let v0 = u["video"]?.object, let a0 = u["audio"]?.object else {
            throw EditError.invalid("clip \(clipID) is not a linked video + audio clip")
        }
        let video = v0.copy(), audio = a0.copy()
        func addMetadata(_ c: JSONObject, _ md: JSONObject?) {
            guard c["metadata"] == nil, let md else { return }
            let anim = c["animationTracks"]
            c["animationTracks"] = nil
            c["metadata"] = .object(md)
            if let anim { c["animationTracks"] = anim }
        }
        addMetadata(video, u["metadata"]?.object?.copy())
        let amd = u["metadata"]?.object?.copy()
        amd?["default-scale"] = nil
        addMetadata(audio, amd)
        for e in u["effects"]?.array?.items ?? [] {
            if audio["effects"]?.array == nil { audio["effects"] = J.emptyArray }
            audio["effects"]?.array?.items.append(e.copy())
        }
        if audio["attributes"]?.object?["ident"]?.string == "",
           let name = video["attributes"]?.object?["ident"]?.string {
            audio["attributes"]?.object?["ident"] = .string(name)
        }

        var rw = try TracksRewrite(project)
        let base = try rw.track(ti)
        base["medias"]?.array?[loc.index] = .object(video)
        for tr in base["transitions"]?.array?.items.compactMap(\.object) ?? [] {
            for k in ["leftMedia", "rightMedia"] where tr[k]?.int == clipID { tr[k] = J.int(video.clipID ?? -1) }
        }
        let s = audio["start"]?.int ?? 0, e = s + (audio["duration"]?.int ?? 0)
        var above = ti + 1
        var free = false
        if above < rw.count {
            free = trackClips(try rw.track(above)).allSatisfy { o in
                let os = o["start"]?.int ?? 0, oe = os + (o["duration"]?.int ?? 0)
                return !(os < e && s < oe)
            }
        }
        if !free { rw.insertTrack(at: ti + 1); above = ti + 1 }
        let dest = try rw.track(above)
        if rw.isMagnetic(above) { Magnetic.insert(audio, into: dest, start: s) } else { try M2.insertSorted(audio, into: dest) }
        try rw.commit(&swap)
        videoID = video.clipID
        audioID = audio.clipID
    }

    public func revert(on project: Project) throws { try swap.restore(in: project); videoID = nil; audioID = nil }
}
