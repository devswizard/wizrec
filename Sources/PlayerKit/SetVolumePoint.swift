import TimelineEngine
import TSCProjKit

/// Sets the clip's volume at clip media time `at` (ticks) the way Camtasia writes audio points
/// (`docs/specs/audio.md` §4): when no point exists there, `AddAudioPoint` adds one in
/// Camtasia's shape (`{endTime, time, value, duration: 0}`, plus a first point at the clip's
/// start on a clip without points); then `SetParameter` changes that point's value, which keeps
/// the shape. Used for inspector volume edits on clips that have volume points. One undo step.
@MainActor
public final class SetVolumePoint: EditCommand {
    public let name = "Change Volume"
    public let clipID: Int64
    /// Clip media time, ticks (snapped to the frame grid by both steps).
    public let at: Int64
    /// Linear level (1 = 100 %).
    public let value: Double
    private var added: AddAudioPoint?
    private var set: SetParameter?

    public init(clipID: Int64, at mediaTime: Int64, value: Double) {
        self.clipID = clipID; self.at = mediaTime; self.value = value
    }

    public func apply(to project: Project) throws {
        let add = AddAudioPoint(clipID: clipID, at: at)
        do {
            try add.apply(to: project)
            added = add
        } catch {
            // A point already sits at `at` (or the clip refuses one): set the value in place.
            added = nil
        }
        let s = SetParameter(clipID: clipID, parameter: "volume", value: value, keyframeAt: at)
        do {
            try s.apply(to: project)
        } catch {
            if let added { try? added.revert(on: project); self.added = nil }
            throw error
        }
        set = s
    }

    public func revert(on project: Project) throws {
        try set?.revert(on: project)
        try added?.revert(on: project)
        set = nil; added = nil
    }
}
