import TimelineEngine
import TSCProjKit

/// The Audio Effects panel and Edit ▸ Add Audio Point, as edit commands on the timeline
/// selection (`docs/specs/audio.md` §3–§4).
@MainActor
public enum AudioPanel {
    /// Top-level selected clips that carry audio (`AMFile`, `UnifiedMedia` with an audio part,
    /// `StitchedMedia`, `Group`), timeline order.
    public static func audioClips(in project: Project, selection: Set<Int64>) -> [Clip] {
        project.tracks.flatMap(\.clips)
            .filter { selection.contains($0.id) && hasAudio($0) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    static func hasAudio(_ c: Clip) -> Bool {
        switch c.kind {
        case .unified: c.audio != nil
        default: ["AMFile", "StitchedMedia", "Group"].contains(c.kind.typeName)
        }
    }

    /// `item` on every selected audio clip as one undo step; nil when no selected clip has audio
    /// or for `.captions` (captions come from the Captions menu: Add Captions).
    public static func command(_ item: AudioPanelItem, project: Project, selection: Set<Int64>) -> (any EditCommand)? {
        guard item != .captions else { return nil }
        let clips = audioClips(in: project, selection: selection)
        guard !clips.isEmpty else { return nil }
        let steps = clips.map { ApplyAudioItem(clipID: $0.id, item: item) }
        if steps.count == 1, let only = steps.first { return only }
        return CompoundCommand(name: item.displayName, steps.map { s in { _, _ in s } })
    }

    /// Edit ▸ Add Audio Point: a volume point at the playhead (`ticks`, timeline) on each selected
    /// audio clip under it, as one undo step; nil when none is under the playhead.
    public static func addPointCommand(project: Project, selection: Set<Int64>, playhead ticks: Int64) -> (any EditCommand)? {
        let steps = audioClips(in: project, selection: selection).filter { $0.contains(ticks) }.map { c in
            AddAudioPoint(clipID: c.id, at: c.mediaTime(atTimeline: ticks).roundedTicks)
        }
        guard !steps.isEmpty else { return nil }
        if steps.count == 1, let only = steps.first { return only }
        return CompoundCommand(name: "Add Audio Point", steps.map { s in { _, _ in s } })
    }
}

private extension Rational {
    /// Nearest integer (ticks); 0 for a zero denominator.
    var roundedTicks: Int64 {
        guard den != 0 else { return 0 }
        return Int64((Double(num) / Double(den)).rounded())
    }
}
