import Foundation
import TSCProjKit

/// Implementations of the M2 commands declared in `ContractM2.swift`.
///
/// Every command edits copies and swaps them in (`TrackSwap` / `ValueSwap`),
/// so a failed `apply` changes nothing and `revert` restores the exact prior
/// bytes. Rules beyond the specs (marked [inf] or "our choice"):
///
/// - **AddSource**: id = `maxID + 1`; entry keys `id, src, rect, lastMod,
///   loudnessNormalization, sourceTracks, metadata.timeAdded` [obs].
/// - **InsertClip**: video + audio → `UnifiedMedia` (first video and first
///   audio stream; `.trec` video becomes `ScreenVMFile`), video only →
///   `VMFile`, audio only → `AMFile`, image → `IMFile`. Duration = the
///   shortest used stream rounded down to a frame (time-mapping.md §2);
///   images get 5 s (`mediaStart` 0, `mediaDuration` 1, `trimStartSum` 0)
///   and a video+audio `UnifiedMedia` the shorter stream floored to a frame
///   [obs, edit-semantics.md ED0]; open-ended video (shader backgrounds,
///   `range` end ≥ 2^61) gets 60 s [obs, shader-backgrounds.md SH2]. `scale0/1` = `metadata.default-scale` = min(1, fit)
///   (transform.md §3). Visual clips get `metadata.lockAspectRatio` true
///   [obs, ED0]; audio-only clips do not [?]. `start` snaps to the nearest
///   frame [obs]; overlap throws.
/// - **DeleteClips**: clips on any track (top level or in groups);
///   transitions that reference a deleted clip are removed. With `ripple`,
///   each later clip on the same track moves left by the total duration of
///   the deleted clips that end at or before its start (other tracks are not
///   moved) [inf].
/// - **Magnetic tracks** (`Magnetic`): InsertClip never fails for overlap on
///   them; InsertClip and DeleteClips pack them afterwards.
/// - **AddTrack / RemoveTrack**: `trackIndex` is renumbered to the array
///   position; the `trackAttributes` entry is inserted/removed at the same
///   index. Removing the only track throws [inf].
/// - **SetTrackFlag**: `locked` is `trackAttributes[i].metadata.IsLocked`
///   (`"True"`/`"False"` strings) [obs]; the others are booleans. Turning
///   `magnetic` on packs the track in the same command.
/// - **SetParameter**: on a `UnifiedMedia`, `volume` goes to the `audio`
///   child and everything else to `video` (geometry lives there [obs]).
///   Keyframe times snap to the frame grid. See `ParamWriter` for the
///   keyframe rule; `animationTracks.visual` is kept in sync.
/// - **RelinkSource**: rewrites `src`, `lastMod`, `rect` and `sourceTracks`;
///   every other key (`metadata.timeAdded`, `effectDef`, …) stays.
@MainActor
enum M2 {
    static let sourceBinPath = JSONPath(steps: [.key("sourceBin")])
    static let trackAttributesPath = JSONPath(steps: [.key("timeline"), .key("trackAttributes")])

    // MARK: AddSource

    static func addSource(_ c: AddSource, _ project: Project) throws -> Int64 {
        let d = c.descriptor
        guard !d.src.isEmpty, !d.tracks.isEmpty else { throw EditError.invalid("source has no path or streams") }
        let id = project.maxID + 1
        let entry = MediaJSON.sourceEntry(id: id, d, added: c.addedAt)
        let items = project.root["sourceBin"]?.array?.items ?? []
        try c.swap.commit([(sourceBinPath, .array(JSONArray(items + [.object(entry)])))], in: project)
        return id
    }

    // MARK: InsertClip

    /// Default duration for stills, seconds [obs, ED0].
    static let stillSeconds: Int64 = 5
    /// Default duration for open-ended video (shader backgrounds), seconds
    /// [obs, shader-backgrounds.md SH2].
    static let endlessSeconds: Int64 = 60

    static func insertClip(_ c: InsertClip, _ project: Project) throws -> Int64 {
        let tracks = Locator.sceneTracks(project)
        guard tracks.indices.contains(c.track) else { throw EditError.trackNotFound(c.track) }
        let start = FrameGrid(project).nearest(c.start)
        guard start >= 0 else { throw EditError.invalid("start must be ≥ 0") }
        let clip = try newClip(sourceID: c.sourceID, start: start, project)
        let duration = clip["duration"]?.int ?? 0
        let magnetic = Magnetic.isMagnetic(project, track: c.track)
        let edits = magnetic ? tracks[c.track].track.copy()
            : try trackForInsert(tracks[c.track].track, start: start, duration: duration, track: c.track)
        if magnetic { Magnetic.insert(clip, into: edits, start: start) } else { try insertSorted(clip, into: edits) }
        try c.swap.commit([(tracks[c.track].path, edits)], in: project)
        return clip.clipID ?? -1
    }

    /// A new clip for `sourceID` at `start` (ticks, already on the frame
    /// grid), with ids from `project.maxID + 1`. Its type, duration and
    /// scale follow the InsertClip rules above.
    static func newClip(sourceID: Int64, start: Int64, _ project: Project) throws -> JSONObject {
        guard let source = project.source(id: sourceID) else {
            throw EditError.invalid("source \(sourceID) not found")
        }
        let grid = FrameGrid(project)

        let streams = source.tracks
        let video = streams.firstIndex { $0.type == 0 }
        let image = streams.firstIndex { $0.type == 1 }
        let audio = streams.firstIndex { $0.type == 2 }
        let editRate = project.timebase.editRate

        func length(_ n: Int) -> Rational? {
            let st = streams[n], r = st.range
            guard r.count == 2, st.editRate > 0, r[1] >= r[0], r[1] < Int64.max / 4 else { return nil }
            let (ticks, o) = (r[1] - r[0]).multipliedReportingOverflow(by: editRate)
            return o ? nil : Rational(ticks, st.editRate)
        }
        let used = [video, audio].compactMap { $0 }
        let lengths = image != nil && video == nil ? [] : used.compactMap(length)
        let still = grid.floor(stillSeconds * editRate)
        let endless = video.map { streams[$0].range.count == 2 && streams[$0].range[1] >= Int64.max / 4 } ?? false
        let duration: Int64
        if lengths.count == used.count, let shortest = lengths.min(by: Exact.less) {
            duration = grid.floor(Exact.floor(shortest))
        } else if endless {
            duration = grid.floor(endlessSeconds * editRate)
        } else {
            duration = still
        }
        guard duration > 0 else { throw EditError.invalid("source \(sourceID) is shorter than one frame") }

        let ident = ((source.src as NSString).lastPathComponent as NSString).deletingPathExtension
        func size(_ n: Int?) -> (Double, Double) {
            if let n, let r = streams[n].object["trackRect"]?.array?.items.compactMap(\.double), r.count == 4 {
                return (r[2], r[3])
            }
            let r = source.rect
            return r.count == 4 ? (r[2], r[3]) : (0, 0)
        }
        func scale(_ n: Int?) -> Double {
            let (w, h) = size(n)
            return MediaJSON.defaultScale(width: w, height: h, canvasW: project.width, canvasH: project.height)
        }
        var next = project.maxID
        func take() -> Int64 { next += 1; return next }
        let timing = MediaJSON.Timing(start: start, duration: duration, mediaDuration: duration)
        let videoType = source.src.lowercased().hasSuffix(".trec") ? "ScreenVMFile" : "VMFile"

        let clip: JSONObject
        if let v = video, let a = audio {
            let id = take()
            let s = scale(v)
            let vc = MediaJSON.videoClip(id: take(), type: videoType, src: sourceID, stream: v, ident: ident,
                                         scale: s, timing: timing, metadata: nil)
            let ac = MediaJSON.audioClip(id: take(), src: sourceID, stream: a, ident: "",
                                         channels: Int(streams[a].channels), timing: timing, metadata: nil)
            clip = MediaJSON.unifiedClip(id: id, video: vc, audio: ac, scale: s, timing: timing)
        } else if let v = video {
            let s = scale(v)
            clip = MediaJSON.videoClip(id: take(), type: videoType, src: sourceID, stream: v, ident: ident,
                                       scale: s, timing: timing, metadata: MediaJSON.metadata(defaultScale: s, lockAspect: true))
        } else if let a = audio {
            clip = MediaJSON.audioClip(id: take(), src: sourceID, stream: a, ident: ident,
                                       channels: Int(streams[a].channels), timing: timing,
                                       metadata: MediaJSON.metadata(defaultScale: nil))
        } else if let i = image {
            clip = MediaJSON.imageClip(id: take(), src: sourceID, ident: ident, scale: scale(i),
                                       start: start, duration: duration)
        } else {
            throw EditError.invalid("source \(sourceID) has no video, image or audio stream")
        }
        return clip
    }

    /// A copy of `track` after checking `[start, start + duration)` is free.
    static func trackForInsert(_ track: JSONObject, start: Int64, duration: Int64, track index: Int) throws -> JSONObject {
        let end = start + duration
        for o in trackClips(track) {
            let s = o["start"]?.int ?? 0, e = s + (o["duration"]?.int ?? 0)
            if s < end && start < e {
                throw EditError.invalid("clip would overlap clip \(o.clipID ?? -1) on track \(index)")
            }
        }
        return track.copy()
    }

    /// Inserts `clip` into `track.medias` in start order.
    static func insertSorted(_ clip: JSONObject, into track: JSONObject) throws {
        if track["medias"]?.array == nil { track["medias"] = J.emptyArray }
        guard let medias = track["medias"]?.array else { throw EditError.invalid("track has no medias") }
        let start = clip["start"]?.int ?? 0
        let at = medias.items.firstIndex { ($0.object?["start"]?.int ?? 0) > start } ?? medias.count
        medias.items.insert(.object(clip), at: at)
    }

    // MARK: DeleteClips

    static func deleteClips(_ c: DeleteClips, _ project: Project) throws {
        guard !c.clipIDs.isEmpty else { throw EditError.invalid("nothing to delete") }
        var seen = Set<Int64>()
        let all = try c.clipIDs.filter { seen.insert($0).inserted }.map { try Locator.locate($0, in: project) }
        // Clips inside a deleted group go with it.
        let locs = all.filter { l in !all.contains { o in o.clip !== l.clip && l.trackPath.hasPrefix(o.clipPath) } }
        var edits = TrackEdits(project)
        let byTrack = Dictionary(grouping: locs) { $0.trackPath.steps.count }
        for depth in byTrack.keys.sorted(by: >) {
            var paths: [JSONPath] = []
            for l in byTrack[depth] ?? [] where !paths.contains(l.trackPath) { paths.append(l.trackPath) }
            for path in paths {
                let here = locs.filter { $0.trackPath == path }
                let track = try edits.track(at: path)
                try removeClips(at: Set(here.map(\.index)), from: track, ripple: c.ripple)
            }
        }
        try edits.packMagnetic()
        try edits.commit(&c.swap)
    }

    /// Removes `medias[indices]`, the transitions that reference them, and
    /// with `ripple` closes the gaps on this track. Timeline markers
    /// (`timeline.parameters.toc`) never move [obs, markers.md X8].
    static func removeClips(at indices: Set<Int>, from track: JSONObject, ripple: Bool) throws {
        guard let medias = track["medias"]?.array else { throw EditError.invalid("track has no medias") }
        let removed = indices.sorted().compactMap { medias.items.indices.contains($0) ? medias.items[$0].object : nil }
        let ids = Set(removed.compactMap(\.clipID))
        let gaps = removed.map { ($0["start"]?.int ?? 0, $0["duration"]?.int ?? 0) }
        for i in indices.sorted(by: >) where medias.items.indices.contains(i) { medias.items.remove(at: i) }
        if let tr = track["transitions"]?.array {
            tr.items.removeAll { t in
                guard let o = t.object else { return false }
                return [o["leftMedia"]?.int, o["rightMedia"]?.int].contains { $0.map(ids.contains) ?? false }
            }
        }
        guard ripple else { return }
        for m in medias.items {
            guard let o = m.object else { continue }
            let s = o["start"]?.int ?? 0
            let shift = gaps.filter { $0.0 + $0.1 <= s }.reduce(Int64(0)) { $0 + $1.1 }
            guard shift > 0 else { continue }
            for part in TrimClip.timedParts(o) {
                TimeWriter.set((part["start"]?.int ?? s) - shift, "start", in: part)
            }
        }
    }

    // MARK: Tracks

    static func sceneTracksArray(_ project: Project) throws -> JSONArray {
        guard let a = JSONPath.sceneTracks.resolve(in: project.root)?.array else {
            throw EditError.invalid("project has no scene tracks")
        }
        return a
    }

    /// `items` with each track's `trackIndex` equal to its position (tracks
    /// whose index changes are copied, the rest are shared).
    static func renumbered(_ items: [JSON]) -> JSONArray {
        JSONArray(items.enumerated().map { i, v in
            guard let o = v.object, o["trackIndex"]?.int != Int64(i) else { return v }
            let c = o.copy()
            c["trackIndex"] = J.int(i)
            return .object(c)
        })
    }

    static func addTrack(_ c: AddTrack, _ project: Project) throws {
        let tracks = try sceneTracksArray(project)
        guard (0...tracks.count).contains(c.index) else { throw EditError.trackNotFound(c.index) }
        var items = tracks.items
        items.insert(.object(ProjectTemplate.track(index: c.index)), at: c.index)
        var edits: [(path: JSONPath, new: JSON)] = [(JSONPath.sceneTracks, .array(renumbered(items)))]
        if let attrs = trackAttributesPath.resolve(in: project.root)?.array {
            var a = attrs.items
            a.insert(.object(ProjectTemplate.trackAttributes()), at: min(c.index, a.count))
            edits.append((trackAttributesPath, .array(JSONArray(a))))
        }
        try c.swap.commit(edits, in: project)
    }

    static func removeTrack(_ c: RemoveTrack, _ project: Project) throws {
        let tracks = try sceneTracksArray(project)
        guard tracks.items.indices.contains(c.index) else { throw EditError.trackNotFound(c.index) }
        guard tracks.count > 1 else { throw EditError.invalid("a project keeps at least one track") }
        var items = tracks.items
        items.remove(at: c.index)
        var edits: [(path: JSONPath, new: JSON)] = [(JSONPath.sceneTracks, .array(renumbered(items)))]
        if let attrs = trackAttributesPath.resolve(in: project.root)?.array, attrs.items.indices.contains(c.index) {
            var a = attrs.items
            a.remove(at: c.index)
            edits.append((trackAttributesPath, .array(JSONArray(a))))
        }
        try c.swap.commit(edits, in: project)
    }

    static func setTrackFlag(_ c: SetTrackFlag, _ project: Project) throws {
        guard let attrs = trackAttributesPath.resolve(in: project.root)?.array,
              attrs.items.indices.contains(c.index), let old = attrs.items[c.index].object
        else { throw EditError.trackNotFound(c.index) }
        let a = old.copy()
        switch c.flag {
        case .locked:
            if a["metadata"]?.object == nil { a["metadata"] = J.emptyObject }
            a["metadata"]?.object?["IsLocked"] = .string(c.value ? "True" : "False")
        default:
            a[c.flag.rawValue] = .bool(c.value)
        }
        var edits: [(path: JSONPath, new: JSON)] = [(trackAttributesPath.appending(.index(c.index)), .object(a))]
        // Turning magnetic on closes the track's gaps at once [inf].
        if c.flag == .magnetic, c.value, let t = JSONPath.sceneTracks.appending(.index(c.index)).resolve(in: project.root)?.object {
            let packed = t.copy()
            Magnetic.pack(packed)
            if JSON.object(packed) != JSON.object(t) {
                edits.append((JSONPath.sceneTracks.appending(.index(c.index)), .object(packed)))
            }
        }
        try c.swap.commit(edits, in: project)
    }

    // MARK: SetParameter

    static func setParameter(_ c: SetParameter, _ project: Project) throws {
        guard c.value.isFinite else { throw EditError.invalid("value must be finite") }
        guard !c.parameter.isEmpty else { throw EditError.invalid("empty parameter name") }
        let loc = try Locator.locate(c.clipID, in: project)
        var edits = TrackEdits(project)
        let track = try edits.track(at: loc.trackPath)
        guard let clip = track["medias"]?.array?[loc.index].object else { throw EditError.clipNotFound(c.clipID) }
        let owner = try parameterOwner(clip, c.parameter)
        try writeParameter(owner, c.parameter, c.value, keyframeAt: c.keyframeAt, grid: FrameGrid(project))
        try edits.commit(&c.swap)
    }

    /// The clip object whose `parameters` hold `name`.
    static func parameterOwner(_ clip: JSONObject, _ name: String) throws -> JSONObject {
        guard clip.clipType == "UnifiedMedia" else { return clip }
        guard let o = clip[name == "volume" ? "audio" : "video"]?.object else {
            throw EditError.invalid("UnifiedMedia \(clip.clipID ?? -1) has no part for \(name)")
        }
        return o
    }

    /// Writes a constant or a keyframe into `owner.parameters`, then syncs `animationTracks`.
    static func writeParameter(_ owner: JSONObject, _ name: String, _ value: Double, keyframeAt: Int64?,
                               grid: FrameGrid) throws {
        if owner["parameters"]?.object == nil { owner["parameters"] = J.emptyObject }
        guard let params = owner["parameters"]?.object else { throw EditError.invalid("no parameters") }
        if let at = keyframeAt {
            let m = grid.nearest(at)
            guard m >= 0 else { throw EditError.invalid("keyframe time must be ≥ 0") }
            let visible = Retime.isStill(owner)
                ? owner["trimStartSum"]?.int ?? 0
                : Exact.floor(Rational(owner["mediaStart"]) ?? Rational(0))
            ParamWriter.setKeyframe(params, name, value, at: m, visibleStart: visible)
        } else {
            ParamWriter.setConstant(params, name, value)
        }
        AnimationSync.sync(owner)
    }

    // MARK: RelinkSource

    static func relinkSource(_ c: RelinkSource, _ project: Project) throws {
        let d = c.descriptor
        guard !d.src.isEmpty, !d.tracks.isEmpty else { throw EditError.invalid("source has no path or streams") }
        let items = project.root["sourceBin"]?.array?.items ?? []
        guard let i = items.firstIndex(where: { $0.object?["id"]?.int == c.sourceID }),
              let old = items[i].object
        else { throw EditError.invalid("source \(c.sourceID) not found") }
        let s = old.copy()
        s["src"] = .string(d.src)
        s["rect"] = MediaJSON.rect(d)
        s["lastMod"] = .string(Stamp.string(d.lastModified, micro: false))
        s["sourceTracks"] = MediaJSON.sourceTracks(d)
        try c.swap.commit([(sourceBinPath.appending(.index(i)), .object(s))], in: project)
    }
}
