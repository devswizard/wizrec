import Foundation
import TSCProjKit

/// How edge edits treat a clip's time-based data, and the frame grid.
///
/// Per `docs/specs/time-mapping.md` §6–7, keyframe `time`/`endTime`, effect
/// `start`/`duration` windows and `animationTracks.visual` ranges are on the
/// clip's **media time axis** (the axis of `mediaStart`), not relative to the
/// clip's `start`. Moving an edge moves `mediaStart`, so this data needs no
/// change: split halves and trimmed clips keep it as is, including keyframes
/// in the trimmed-off part (Camtasia keeps those too [obs]).
///
/// Exception: still images (`IMFile`) have no media time (`mediaStart` 0,
/// `mediaDuration` 1 tick, whatever the duration [obs]); their animation base
/// is `t − start + trimStartSum` [inf]. Their `mediaStart`/`mediaDuration` are
/// never changed, and left-edge moves go to `trimStartSum` instead.
enum Retime {
    /// True for clips whose media fields must not be rescaled (images).
    static func isStill(_ clip: JSONObject) -> Bool { clip.clipType == "IMFile" }

    /// Moves an image's animation base when its left edge moves by `delta`
    /// ticks (positive = trimmed). Assumption: never below 0, and only when
    /// the key exists (it does on every observed image).
    static func moveStillStart(_ clip: JSONObject, by delta: Int64) {
        guard delta != 0, let sum = clip["trimStartSum"]?.int else { return }
        TimeWriter.set(max(sum + delta, 0), "trimStartSum", in: clip)
    }
}

/// Output-frame grid. With `allowSubFrameEditing` false (Camtasia's default
/// and every observed v10 project), clip `start`/`duration`/`mediaStart`
/// are whole frames of `editRate / videoFormatFrameRate` ticks [obs,
/// time-mapping.md §2]; commands snap requested times to it.
struct FrameGrid {
    let timebase: Timebase
    /// Frames per second; `nil` = sub-frame editing (1-tick grid).
    let fps: Rational?

    init(_ project: Project) {
        timebase = project.timebase
        let subFrame = project.root["allowSubFrameEditing"]?.bool ?? false
        let r = project.frameRate
        fps = subFrame || r.num <= 0 ? nil : r
    }

    func floor(_ t: Int64) -> Int64 {
        guard let fps else { return t }
        let f = timebase.frame(t, fps: fps)
        let s = timebase.ticks(frame: f, fps: fps)
        // Integer division truncates toward zero; fix up negatives.
        return s > t ? timebase.ticks(frame: f - 1, fps: fps) : s
    }

    func ceil(_ t: Int64) -> Int64 {
        let f = floor(t)
        guard f != t, let fps else { return t }
        return timebase.ticks(frame: timebase.frame(f, fps: fps) + 1, fps: fps)
    }

    /// Nearest frame boundary; ties go to the earlier frame.
    func nearest(_ t: Int64) -> Int64 {
        let lo = floor(t), hi = ceil(t)
        return t - lo <= hi - t ? lo : hi
    }
}
