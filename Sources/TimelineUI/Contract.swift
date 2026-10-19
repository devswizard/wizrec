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

    public init(undo: UndoStack) { self.undo = undo }
}

/// Multi-track timeline view: ruler, track headers (mute/hide/lock), clips with
/// thumbnails/waveforms, playhead, selection, drag to move/trim, split at playhead.
@MainActor
public final class TimelineView: NSView {
    public let model: TimelineModel

    public init(model: TimelineModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
