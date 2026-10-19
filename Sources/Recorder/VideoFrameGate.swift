import CoreMedia

/// Decides which video frames to write and at which recording time.
///
/// Screen capture is variable frame rate: ScreenCaptureKit only delivers a frame when the
/// screen changes. So a frame that arrives before the start or during a pause is *held*
/// (latest one wins) and written at the start of the next recorded segment; otherwise a static
/// screen would leave the segment showing stale content (or nothing at t=0). Output times are
/// strictly increasing; the very first frame is written at t=0 so the file never starts black.
struct VideoFrameGate<Frame> {
    private var held: Frame?
    private(set) var lastOutput: CMTime?

    /// Offers a captured frame stamped `hostTime`. Returns the frames to append, in order, with
    /// their recording times.
    mutating func offer(_ frame: Frame, hostTime: CMTime, timeline: TimelineStitcher) -> [(Frame, CMTime)] {
        guard var out = timeline.map(hostTime) else {
            if !timeline.isStopped { held = frame }
            return []
        }
        var result = flushHeld(timeline: timeline)
        if lastOutput == nil { out = .zero }
        if let last = lastOutput, out <= last { return result }
        lastOutput = out
        result.append((frame, out))
        return result
    }

    /// Called right after the timeline starts or resumes: writes the held frame at the start of
    /// the new segment.
    mutating func activate(timeline: TimelineStitcher) -> [(Frame, CMTime)] {
        flushHeld(timeline: timeline)
    }

    private mutating func flushHeld(timeline: TimelineStitcher) -> [(Frame, CMTime)] {
        guard let h = held, let start = timeline.startTime, !timeline.isPaused, !timeline.isStopped else { return [] }
        held = nil
        let segmentStart = timeline.recordingTime(at: timeline.pauses.last?.resumedAt ?? start)
        if let last = lastOutput, segmentStart <= last { return [] }
        lastOutput = segmentStart
        return [(h, segmentStart)]
    }
}
