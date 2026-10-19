// Public interface of TimelineUI (agent "timelineui"), frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import AppKit
import Observation
import TimelineEngine
import TSCProjKit

/// Timeline editing state shared by the timeline view and the app.
/// Mutations of the project go through `undo` (TimelineEngine commands) only.
@MainActor @Observable
public final class TimelineModel {
    public let undo: UndoStack
    public var project: Project { undo.project }
    /// Playhead, ticks.
    public var playhead: Int64 = 0
    /// Horizontal zoom, points per second.
    public var pointsPerSecond: Double = 100
    /// Selected clip ids.
    public var selection: Set<Int64> = []
    /// Called when the user moves the playhead (scrub, click on ruler). Ticks.
    public var onSeek: ((Int64) -> Void)?

    // Additive (API_CHANGE TimelineUI, approved 2026-10-19).

    /// Snap drags to clip edges, the playhead and tick 0.
    public var snappingEnabled = true
    /// Last edit that failed (command name and error), for a status line. Nil after success.
    public var lastError: String?
    /// Called when media is dropped on the timeline: payload, scene track index
    /// (0 = bottom; always an existing track, or 0 when there are none) and start ticks
    /// (snapped like moves). Return true when the drop was handled.
    public var onDrop: ((DropPayload, _ track: Int, _ ticks: Int64) -> Bool)?
    /// Groups opened for editing, outermost first (ids). Empty: the top-level timeline.
    /// Double-clicking a group appends it; Esc or `closeGroup:` removes the last one.
    /// While a group is open, track indices and `selection` refer to its inner tracks/clips.
    public var openGroups: [Int64] = []

    // Additive (API_CHANGE TimelineUI, session 3, S3-TUI-1).

    /// Called instead of `onDrop` when media is dropped while a group is open (inner track and
    /// inner ticks of the innermost open group). Nil: drops inside groups are refused.
    public var onGroupDrop: ((DropPayload, GroupDropTarget) -> Bool)?
    /// Builds inner-track add/remove commands (seam over TimelineEngine's group-track commands).
    @ObservationIgnored var groupTracks: any GroupTrackCommands = EngineGroupTracks()

    public init(undo: UndoStack) { self.undo = undo }
}

/// What was dropped on the timeline.
public enum DropPayload: Sendable, Equatable {
    /// Files from Finder (not yet imported).
    case files([URL])
    /// `sourceBin` ids dragged from the media bin (pasteboard type `TimelineView.sourceIDType`).
    case sources([Int64])
}

/// Multi-track timeline view: ruler, track headers (mute/hide/lock), clips with
/// thumbnails/waveforms, playhead, selection, drag to move/trim, split at playhead.
@MainActor
public final class TimelineView: NSView {
    public let model: TimelineModel
    /// Drawing and event handling; fills the view.
    let canvas: TimelineCanvas

    public init(model: TimelineModel) {
        self.model = model
        canvas = TimelineCanvas(model: model)
        super.init(frame: .zero)
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
