import TimelineEngine
import TSCProjKit
import WizRecAssets

/// Annotations library → `InsertCallout` (`docs/specs/callouts.md` §3.1, CO3).
@MainActor
public enum CalloutInsertion {
    /// The callout `def` of a preset as JSON object text (project form, preset key order).
    public static func defJSON(_ preset: CalloutPreset) -> String {
        String(decoding: JSON.object(object(preset.definition)).serialized(), as: UTF8.self)
    }

    static func object(_ entries: [CalloutDefEntry]) -> JSONObject {
        JSONObject(entries.map { e in
            switch e.value {
            case .number(let v): (e.key, .number(JSONNumber(v)))
            case .string(let s): (e.key, .string(s))
            case .object(let inner): (e.key, .object(object(inner)))
            }
        })
    }

    /// On-canvas width for a new callout, px; nil = no scale. Region callouts are scaled to a
    /// third of the canvas width (640 px on 1920) as Camtasia does [CO3]; WizRec's other presets
    /// are sized for a 1920-px canvas and scale with the canvas width [WizRec]. Presets without
    /// a box (arrows) get no scale.
    public static func displayWidth(_ preset: CalloutPreset, canvasWidth: Double) -> Double? {
        guard preset.width > 0, canvasWidth > 0 else { return nil }
        return preset.kind.hasPrefix("TypeWin") ? canvasWidth / 3 : preset.width * canvasWidth / 1920
    }

    /// The track for a callout over [start, start + duration): the one just above the highest
    /// track with a clip in that span (callouts must sit above what they annotate); nil = a new
    /// track on top (also when that track does not exist yet).
    public static func track(in project: Project, start: Int64, duration: Int64) -> Int? {
        let end = start + max(1, duration)
        let tracks = project.tracks
        let busy = tracks.indices.filter { i in tracks[i].clips.contains { $0.start < end && $0.end > start } }
        let above = (busy.max() ?? -1) + 1
        return above < tracks.count ? above : nil
    }

    /// `preset` at `playhead` (timeline ticks): 5 s, scaled per `displayWidth`, on `track(in:…)`.
    public static func command(_ preset: CalloutPreset, project: Project, playhead: Int64) -> InsertCallout {
        let duration = project.timebase.editRate * InsertCallout.defaultSeconds
        return InsertCallout(def: defJSON(preset), start: playhead,
                             track: track(in: project, start: playhead, duration: duration),
                             displayWidth: displayWidth(preset, canvasWidth: project.width))
    }
}
