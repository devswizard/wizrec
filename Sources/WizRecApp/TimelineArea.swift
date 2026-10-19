import AppKit
import PlayerKit
import TimelineUI
import TSCProjKit

/// Hosts the timeline view (agent "timelineui") and accepts drops of files and bin
/// items. Until the real `TimelineView` draws, a read-only overview of the tracks is
/// drawn underneath (clip blocks, selection, playhead) and a click on a clip selects it.
final class TimelineAreaView: NSView {
    weak var editor: EditorWindowController?
    let timeline: TimelineView
    /// Draw the fallback overview (true while TimelineView is the contract stub).
    var drawsFallback = true

    init(timeline: TimelineView) {
        self.timeline = timeline
        super.init(frame: .zero)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeline)
        NSLayoutConstraint.activate([
            timeline.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeline.topAnchor.constraint(equalTo: topAnchor),
            timeline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(MediaDrop.types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: Fallback overview

    private let headerWidth: CGFloat = 72
    private let rulerHeight: CGFloat = 18
    private var rowHeight: CGFloat {
        let n = max(1, editor?.model.project.tracks.count ?? 1)
        return max(18, min(44, (bounds.height - rulerHeight - 4) / CGFloat(n)))
    }

    /// Points per tick so the whole timeline fits.
    private var scale: CGFloat {
        guard let editor else { return 0 }
        let d = max(editor.engine.grid.duration, editor.model.project.timebase.ticks(seconds: 10))
        return (bounds.width - headerWidth - 12) / CGFloat(d)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard drawsFallback, let editor else { return }
        let project = editor.model.project
        let tracks = project.tracks
        let k = scale
        let tb = project.timebase
        // Ruler: a tick per second (every 5 s labelled).
        let seconds = Int(tb.seconds(max(editor.engine.grid.duration, tb.ticks(seconds: 10))))
        let step = max(1, seconds / 20)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        for sec in stride(from: 0, through: seconds, by: step) {
            let x = headerWidth + CGFloat(tb.ticks(seconds: Double(sec))) * k
            NSColor.separatorColor.setFill()
            NSRect(x: x, y: rulerHeight - 5, width: 1, height: 5).fill()
            if sec % (step * 5) == 0 {
                ("\(sec / 60):" + String(format: "%02d", sec % 60) as NSString).draw(at: NSPoint(x: x + 2, y: 2), withAttributes: attrs)
            }
        }
        let h = rowHeight
        let selected = editor.timelineModel.selection
        for (i, track) in tracks.enumerated() {
            // Track 0 is the bottom of the stack: draw it last row.
            let y = rulerHeight + CGFloat(tracks.count - 1 - i) * h
            let row = NSRect(x: 0, y: y, width: bounds.width, height: h - 2)
            (i % 2 == 0 ? NSColor.alternatingContentBackgroundColors[0] : NSColor.alternatingContentBackgroundColors[1]).setFill()
            row.fill()
            ("Track \(i + 1)" as NSString).draw(at: NSPoint(x: 6, y: y + (h - 14) / 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            for clip in track.clips {
                let r = NSRect(x: headerWidth + CGFloat(clip.start) * k, y: y + 2,
                               width: max(2, CGFloat(clip.duration) * k), height: h - 6)
                let color: NSColor = switch clip.kind {
                case .audio: .systemGreen
                case .image: .systemPurple
                case .group: .systemOrange
                case .callout: .systemPink
                default: .systemBlue
                }
                color.withAlphaComponent(0.55).setFill()
                let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                path.fill()
                if selected.contains(clip.id) {
                    NSColor.controlAccentColor.setStroke()
                    path.lineWidth = 2
                    path.stroke()
                }
                let label = (clip.name.flatMap { $0.isEmpty ? nil : $0 } ?? sourceName(clip, project)) as NSString
                label.draw(in: r.insetBy(dx: 4, dy: 2), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
            }
        }
        let px = headerWidth + CGFloat(editor.engine.currentTicks) * k
        NSColor.systemRed.setFill()
        NSRect(x: px - 0.5, y: 0, width: 1.5, height: bounds.height).fill()
    }

    private func sourceName(_ clip: Clip, _ project: Project) -> String {
        var id = clip.sourceID
        if id == nil { id = clip.video?.sourceID ?? clip.audio?.sourceID }
        if let id, let s = project.source(id: id) { return (s.src as NSString).lastPathComponent }
        return clip.kind.typeName
    }

    override func mouseDown(with event: NSEvent) {
        guard drawsFallback, let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let tracks = editor.model.project.tracks
        let k = scale
        guard k > 0 else { return }
        let ticks = Int64(max(0, (p.x - headerWidth) / k))
        if p.y < rulerHeight { editor.engine.seek(toTicks: ticks); return }
        let row = Int((p.y - rulerHeight) / rowHeight)
        let index = tracks.count - 1 - row
        guard tracks.indices.contains(index) else { editor.select([]); return }
        if let clip = tracks[index].clip(at: ticks) { editor.select([clip.id]) } else {
            editor.select([])
            editor.engine.seek(toTicks: ticks)
        }
    }

    /// Track index and time (ticks) under a point in this view, for drops.
    private func target(at p: CGPoint) -> (track: Int?, ticks: Int64) {
        guard let editor else { return (nil, 0) }
        let k = scale
        let ticks = k > 0 ? Int64(max(0, (p.x - headerWidth) / k)) : editor.engine.currentTicks
        let n = editor.model.project.tracks.count
        let row = Int((p.y - rulerHeight) / rowHeight)
        let index = n - 1 - row
        let snapped = editor.engine.grid.snap(ticks)
        return ((0..<n).contains(index) ? index : nil, p.x < headerWidth ? editor.engine.currentTicks : snapped)
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MediaDrop.read(sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let drop = MediaDrop.read(sender.draggingPasteboard), let editor else { return false }
        let t = target(at: convert(sender.draggingLocation, from: nil))
        editor.place(drop, track: t.track, at: drawsFallback ? t.ticks : editor.engine.currentTicks)
        return true
    }
}
