import TSCProjKit

/// An audio clip the Captions menu works on: a top-level `AMFile` or `UnifiedMedia` with
/// audio, the source it plays and the source track (= stream index) holding the speech.
public struct CaptionTarget: Equatable, Sendable {
    /// Top-level clip id (what `AddDynamicCaption(audioClipID:)` takes).
    public var clipID: Int64
    public var sourceID: Int64
    /// Index into the source's `sourceTracks`, which is also the media stream index.
    public var track: Int
    /// Clip start on the timeline, ticks (for ordering).
    public var start: Int64

    /// Targets among `selection` (top-level clips only), timeline order. `perSourceTrack`: one
    /// per source track (two clips of the same recording are transcribed once); false = one per
    /// clip (Add Captions writes captions onto each clip).
    public static func find(in project: Project, selection: Set<Int64>, perSourceTrack: Bool = true) -> [CaptionTarget] {
        targets(project.tracks.flatMap(\.clips).filter { selection.contains($0.id) }, in: project, perSourceTrack: perSourceTrack)
    }

    /// Targets of the top-level audio clips playing at `ticks` (start ≤ ticks < end), one per
    /// source track, timeline order: what a dynamic caption at the playhead shows.
    public static func under(ticks: Int64, in project: Project) -> [CaptionTarget] {
        targets(project.tracks.flatMap(\.clips).filter { $0.start <= ticks && ticks < $0.end }, in: project, perSourceTrack: true)
    }

    private static func targets(_ clips: [Clip], in project: Project, perSourceTrack: Bool) -> [CaptionTarget] {
        var out: [CaptionTarget] = []
        var seen = Set<[Int64]>()
        for c in clips.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let audio: Clip?
            switch c.kind {
            case .audio: audio = c
            case .unified: audio = c.audio
            default: audio = nil
            }
            guard let a = audio, let src = a.sourceID else { continue }
            let track = Int(a.sourceTrackNumber ?? 0)
            guard let s = project.source(id: src), s.tracks.indices.contains(track), s.tracks[track].isAudio else { continue }
            guard !perSourceTrack || seen.insert([src, Int64(track)]).inserted else { continue }
            out.append(CaptionTarget(clipID: c.id, sourceID: src, track: track, start: c.start))
        }
        return out
    }
}
