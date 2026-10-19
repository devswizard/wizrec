import Foundation
import TSCProjKit

/// Magnetic tracks (`trackAttributes[i].magnetic`): clips on them sit end to
/// end with no gaps, the first at tick 0 [inf: Camtasia's UI behaviour; the
/// corpus has no magnetic track]. Commands that change a top-level track pack
/// it afterwards when the flag is set; inserting into a magnetic track never
/// fails for overlap — the clip goes before the first clip whose midpoint
/// lies after the requested start.
@MainActor
enum Magnetic {
    static func isMagnetic(_ project: Project, track index: Int) -> Bool {
        let attrs = project.timeline?.trackAttributes ?? []
        return attrs.indices.contains(index) && (attrs[index]["magnetic"]?.bool ?? false)
    }

    /// Magnetic flag of any track: `trackAttributes` for top-level tracks,
    /// the inline `magnetic` key for tracks inside groups [obs: demo group tracks].
    static func isMagnetic(_ project: Project, path: JSONPath) -> Bool {
        if path.isTopLevelTrack, case .index(let i)? = path.steps.last { return isMagnetic(project, track: i) }
        return path.resolve(in: project.root)?.object?["magnetic"]?.bool ?? false
    }

    /// Moves every clip of `track` (an editable copy) left so they touch,
    /// keeping their order by `start`. `UnifiedMedia` halves move with their parent.
    static func pack(_ track: JSONObject) {
        guard let medias = track["medias"]?.array else { return }
        let ordered = medias.items.enumerated().sorted {
            (($0.element.object?["start"]?.int ?? 0), $0.offset) < (($1.element.object?["start"]?.int ?? 0), $1.offset)
        }.map(\.element)
        medias.items = ordered
        var t: Int64 = 0
        for m in ordered {
            guard let o = m.object else { continue }
            let s = o["start"]?.int ?? 0
            if s != t { shift(o, by: t - s) }
            t += o["duration"]?.int ?? 0
        }
    }

    /// Index in `medias` at which a clip requested at `start` goes on a magnetic track.
    static func insertionIndex(_ track: JSONObject, start: Int64) -> Int {
        let clips = trackClips(track)
        return clips.firstIndex { o in
            let s = o["start"]?.int ?? 0, d = o["duration"]?.int ?? 0
            return s * 2 + d > start * 2
        } ?? clips.count
    }

    /// Inserts `clip` for a magnetic track: placed at the insertion point, then packed.
    static func insert(_ clip: JSONObject, into track: JSONObject, start: Int64) {
        if track["medias"]?.array == nil { track["medias"] = J.emptyArray }
        guard let medias = track["medias"]?.array else { return }
        let i = insertionIndex(track, start: start)
        // Give the clip a start between its neighbours so `pack` keeps the order.
        let before = i > 0 ? medias.items[i - 1].object.map { ($0["start"]?.int ?? 0) } ?? 0 : Int64.min / 4
        shift(clip, by: (before + 1) - (clip["start"]?.int ?? 0))
        medias.items.insert(.object(clip), at: i)
        pack(track)
    }

    /// Shifts a clip and its `UnifiedMedia` halves by `delta` ticks.
    static func shift(_ clip: JSONObject, by delta: Int64) {
        guard delta != 0 else { return }
        let s = clip["start"]?.int ?? 0
        for part in TrimClip.timedParts(clip) {
            TimeWriter.set((part["start"]?.int ?? s) + delta, "start", in: part)
        }
    }
}

@MainActor
extension TrackEdits {
    /// Packs every edited track that is magnetic: top-level tracks by
    /// `trackAttributes`, group tracks by their inline flag.
    mutating func packMagnetic() throws {
        for (path, t) in nested where Magnetic.isMagnetic(project, path: path) { Magnetic.pack(t) }
        for i in editedTopIndices where Magnetic.isMagnetic(project, track: i) {
            Magnetic.pack(try topTrack(i))
        }
    }
}
