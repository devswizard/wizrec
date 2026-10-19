import AppKit
import Observation
import TimelineEngine
import TSCProjKit

/// Gesture in progress. Previews are view-only; the command is pushed on mouse-up.
/// Origins are content points (view point + scroll), so autoscroll during a drag keeps them.
enum TimelineDrag: Equatable {
    case none
    /// Scrubbing the playhead (ruler or playhead handle).
    case scrub
    /// Mouse down on a clip body, not yet past the drag threshold.
    case press(clipID: Int64, origin: CGPoint, wasSelected: Bool)
    case move(origin: CGPoint, plan: MovePlan)
    /// ⌥-drag of one clip: ripple move.
    case rippleMove(origin: CGPoint, plan: RippleMovePlan)
    case trim(origin: CGPoint, plan: TrimPlan)
    /// Rubber-band selection; `base` is the selection kept (shift/⌘).
    case marquee(origin: CGPoint, current: CGPoint, base: Set<Int64>)
}

/// Draws the timeline and turns events into edits. Lives inside `TimelineView`.
@MainActor
final class TimelineCanvas: NSView {
    let model: TimelineModel
    private(set) var snapshot: TimelineSnapshot = .empty
    var metrics = TimelineMetrics()
    /// Custom snap rule; nil = TimelineEngine `Snapping`.
    var snapper: (any TimelineSnapping)?
    let art = MediaArtCache()
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    var drag: TimelineDrag = .none
    /// Drop target shown while media is dragged over the view.
    var dropTarget: (track: Int, ticks: Int64)?
    /// Snap distance, points.
    var snapTolerancePoints: CGFloat = 8
    /// Fit the project once the view first gets a size.
    var fitsOnFirstLayout = true
    /// Set while `TimelineView` forwards a key event here (prevents a responder-chain loop).
    var forwardingKey = false
    /// Rasterised SF Symbols and resolved clip colours, keyed by appearance (drawing is hot).
    var symbolCache: [String: CGImage] = [:]
    var clipColorCache: [String: (body: CGColor, outline: CGColor)] = [:]

    private var builtChangeCount = -1
    private var lastPlayhead: Int64 = 0
    private var scrubbing = false
    private var trackingArea: NSTrackingArea?

    init(model: TimelineModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        rebuildIfNeeded()
        lastPlayhead = model.playhead
        art.onUpdate = { [weak self] in self?.needsDisplay = true }
        registerForDraggedTypes([.fileURL, TimelineView.sourceIDType])
        observeModel()
        observePlayhead()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    var layout: TimelineLayout {
        TimelineLayout(snapshot: snapshot, pointsPerSecond: model.pointsPerSecond, scrollX: scrollX,
                       scrollY: scrollY, size: bounds.size, metrics: metrics)
    }

    var editor: TimelineEditor { TimelineEditor(model: model, snapshot: snapshot, snapper: snapper) }

    var snapTolerance: Int64 { layout.ticks(forWidth: snapTolerancePoints) }

    // MARK: Model observation

    private func observeModel() {
        withObservationTracking {
            _ = model.undo.changeCount
            _ = model.pointsPerSecond
            _ = model.selection
            _ = model.snappingEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modelChanged()
                self.observeModel()
            }
        }
    }

    private func observePlayhead() {
        withObservationTracking {
            _ = model.playhead
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playheadChanged()
                self.observePlayhead()
            }
        }
    }

    /// Rebuilds the snapshot after an edit (cheap: value projection of top-level clips).
    func rebuildIfNeeded() {
        guard builtChangeCount != model.undo.changeCount else { return }
        builtChangeCount = model.undo.changeCount
        snapshot = TimelineSnapshot(project: model.project)
        let ids = Set(snapshot.allClips.map(\.id))
        if !model.selection.isSubset(of: ids) { model.selection.formIntersection(ids) }
    }

    func modelChanged() {
        rebuildIfNeeded()
        clampScroll()
        needsDisplay = true
    }

    func playheadChanged() {
        let old = lastPlayhead, new = model.playhead
        lastPlayhead = new
        guard old != new else { return }
        let L = layout
        if !scrubbing, case .none = drag {
            let x = L.x(ofTicks: new), area = L.clipArea
            if area.width > 40, x > area.maxX - 16 || x < area.minX {
                // Page-follow during playback or external seeks.
                scrollX = max(0, L.width(ofTicks: new) + metrics.leadingInset - area.width * 0.1)
                clampScroll()
                needsDisplay = true
                return
            }
        }
        invalidatePlayhead(at: old, layout: L)
        invalidatePlayhead(at: new, layout: L)
        setNeedsDisplay(L.cornerRect)
    }

    private func invalidatePlayhead(at t: Int64, layout L: TimelineLayout) {
        let x = L.x(ofTicks: t)
        setNeedsDisplay(CGRect(x: x - 9, y: 0, width: 18, height: bounds.height))
    }

    func clampScroll() {
        let L = layout
        scrollX = min(max(0, scrollX), L.maxScrollX(duration: snapshot.duration))
        scrollY = min(max(0, scrollY), L.maxScrollY)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitsOnFirstLayout, newSize.width > metrics.headerWidth + 50, snapshot.duration > 0 {
            fitsOnFirstLayout = false
            zoomToFit()
        }
        clampScroll()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        symbolCache = [:]; clipColorCache = [:]
        needsDisplay = true
    }

    // MARK: Zoom

    /// Zooms to `pps` keeping the time under view x `anchorX` in place.
    func zoom(to pps: Double, anchorX: CGFloat? = nil) {
        let L = layout
        let anchor = anchorX ?? {
            let px = L.x(ofTicks: model.playhead)
            return L.clipArea.contains(CGPoint(x: px, y: L.clipArea.midY)) ? px : L.clipArea.minX
        }()
        let t = L.ticks(atX: anchor)
        let clamped = TimelineZoom.clamp(pps)
        scrollX = L.scrollX(keeping: t, atX: anchor, pointsPerSecond: clamped)
        model.pointsPerSecond = clamped
        clampScroll()
        needsDisplay = true
    }

    func zoomToFit() {
        let L = layout
        let pps = TimelineZoom.fit(duration: max(snapshot.duration, snapshot.editRate),
                                   editRate: snapshot.editRate, width: L.clipArea.width - metrics.leadingInset)
        model.pointsPerSecond = pps
        scrollX = 0
        clampScroll()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        rebuildIfNeeded()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let L = layout
        drawAll(ctx, layout: L, dirty: dirtyRect)
    }

    // MARK: Tracking / cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    func updateCursor(at p: CGPoint) {
        if case .clip(_, let track, let zone) = layout.hit(p, in: snapshot), zone != .body,
           snapshot.track(track)?.locked == false {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let L = layout
        let flags = event.modifierFlags
        let additive = flags.contains(.shift) || flags.contains(.command)
        // Playhead handle in the ruler or a grab on the playhead line: scrub.
        if abs(p.x - L.x(ofTicks: model.playhead)) <= 5, p.x >= L.clipArea.minX, p.y < L.metrics.rulerHeight + 4 {
            beginScrub(at: p); return
        }
        switch L.hit(p, in: snapshot) {
        case .corner:
            if addTrackButtonRect(L).contains(p) { _ = editor.addTrack(at: snapshot.tracks.count) }
        case .ruler:
            beginScrub(at: p)
        case .header(let track, let control):
            if let control { editor.toggle(control, track: track) }
        case .clip(let id, let track, let zone):
            let locked = snapshot.track(track)?.locked ?? true
            if flags.contains(.command) {
                if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
                return
            }
            let wasSelected = model.selection.contains(id)
            if flags.contains(.shift) { model.selection.insert(id) }
            else if !wasSelected { model.selection = [id] }
            guard !locked else { return }
            switch zone {
            case .leadingEdge, .trailingEdge:
                model.selection = additive ? model.selection.union([id]) : [id]
                let edge: TrimEdge = zone == .leadingEdge ? .start : .end
                if let plan = editor.planTrim(id: id, edge: edge, rawDelta: 0, tolerance: 0) {
                    drag = .trim(origin: contentPoint(p), plan: plan)
                }
            case .body:
                drag = .press(clipID: id, origin: contentPoint(p), wasSelected: wasSelected && !flags.contains(.shift))
            }
        case .track, .empty:
            let base = additive ? model.selection : []
            if !additive { model.selection = [] }
            drag = .marquee(origin: contentPoint(p), current: contentPoint(p), base: base)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move, .rippleMove, .trim, .marquee: autoscroll(toward: p)
        default: break
        }
        let L = layout
        switch drag {
        case .none: return
        case .scrub:
            seek(to: L.ticks(atX: max(p.x, L.clipArea.minX)))
        case .press(let id, let origin, _):
            let o = viewPoint(origin)
            guard hypot(p.x - o.x, p.y - o.y) >= 3 else { return }
            let ids = model.selection.contains(id) ? Array(model.selection) : [id]
            drag = moveDrag(ids: ids, origin: origin, to: p, ripple: event.modifierFlags.contains(.option), layout: L)
        case .move(let origin, let plan):
            drag = moveDrag(ids: plan.ids, origin: origin, to: p, ripple: event.modifierFlags.contains(.option), layout: L)
        case .rippleMove(let origin, let plan):
            drag = moveDrag(ids: [plan.id], origin: origin, to: p, ripple: event.modifierFlags.contains(.option), layout: L)
        case .trim(let origin, let plan):
            let raw = L.ticks(forWidth: p.x - viewPoint(origin).x)
            if let np = editor.planTrim(id: plan.id, edge: plan.edge, rawDelta: raw, tolerance: snapTolerance,
                                        ripple: event.modifierFlags.contains(.option)) {
                drag = .trim(origin: origin, plan: np)
            }
        case .marquee(let origin, _, let base):
            drag = .marquee(origin: origin, current: contentPoint(p), base: base)
            let o = viewPoint(origin)
            let r = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y))
            model.selection = base.union(L.clips(in: r, snapshot: snapshot))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let current = drag
        drag = .none
        scrubbing = false
        switch current {
        case .press(let id, _, let wasSelected):
            if wasSelected { model.selection = [id] }
        case .move(_, let plan):
            if plan.isValid { _ = editor.performMove(plan) } else if plan.delta != 0 || plan.trackOffset != 0 { NSSound.beep() }
        case .rippleMove(_, let plan):
            if !editor.performRippleMove(plan) { NSSound.beep() }
        case .trim(_, let plan):
            _ = editor.performTrim(plan)
        default: break
        }
        needsDisplay = true
    }

    /// Plain move of `ids`, or a ripple move when ⌥ is held and one clip is dragged.
    private func moveDrag(ids: [Int64], origin: CGPoint, to p: CGPoint, ripple: Bool, layout L: TimelineLayout) -> TimelineDrag {
        let plan = planMove(ids: ids, origin: origin, to: p, layout: L)
        if ripple, ids.count == 1,
           let rp = editor.planRippleMove(id: ids[0], rawDelta: L.ticks(forWidth: p.x - viewPoint(origin).x),
                                          trackOffset: plan.trackOffset, tolerance: snapTolerance) {
            return .rippleMove(origin: origin, plan: rp)
        }
        return .move(origin: origin, plan: plan)
    }

    /// Clip positions that a ripple drag or trim changes (drawn instead of the originals).
    var previewPositions: [Int64: ClipPosition] {
        switch drag {
        case .trim(_, let plan): editor.preview(plan)
        case .rippleMove(_, let plan): editor.preview(plan)
        default: [:]
        }
    }

    private func planMove(ids: [Int64], origin content: CGPoint, to p: CGPoint, layout L: TimelineLayout) -> MovePlan {
        let origin = viewPoint(content)
        let raw = L.ticks(forWidth: p.x - origin.x)
        var offset = 0
        if let from = L.nearestTrack(atY: origin.y), let to = L.nearestTrack(atY: p.y),
           let fr = L.rows.firstIndex(where: { $0.trackIndex == from }),
           let tr = L.rows.firstIndex(where: { $0.trackIndex == to }) {
            offset = fr - tr  // rows run top → bottom = highest track first
        }
        return editor.planMove(ids: ids, rawDelta: raw, trackOffset: offset, tolerance: snapTolerance)
    }

    func contentPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + scrollX, y: p.y + scrollY) }
    func viewPoint(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x - scrollX, y: c.y - scrollY) }

    /// Scrolls when a drag nears the clip area's edges (speed grows with the overshoot).
    func autoscroll(toward p: CGPoint) {
        let area = layout.clipArea, margin: CGFloat = 24
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x > area.maxX - margin { dx = min(40, p.x - (area.maxX - margin)) }
        if p.x < area.minX + margin { dx = -min(40, area.minX + margin - p.x) }
        if p.y > area.maxY - margin { dy = min(20, p.y - (area.maxY - margin)) }
        if p.y < area.minY + margin { dy = -min(20, area.minY + margin - p.y) }
        guard dx != 0 || dy != 0 else { return }
        scrollX += dx; scrollY += dy
        clampScroll()
    }

    private func beginScrub(at p: CGPoint) {
        drag = .scrub
        scrubbing = true
        let L = layout
        seek(to: L.ticks(atX: max(p.x, L.clipArea.minX)))
    }

    /// Moves the playhead (frame-rounded, ≥ 0) and reports it through `onSeek`.
    func seek(to t: Int64) {
        let q = max(0, snapshot.quantize(t))
        guard q != model.playhead else { return }
        model.playhead = q
        model.onSeek?(q)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .clip(let id, _, _) = layout.hit(p, in: snapshot), !model.selection.contains(id) {
            model.selection = [id]
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return contextMenu(for: layout.hit(p, in: snapshot))
    }

    // MARK: Scroll / zoom gestures

    override func scrollWheel(with event: NSEvent) {
        let L = layout
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 }
        if flags.contains(.command) || flags.contains(.option) {
            let factor = exp(Double(dy + dx) * 0.01)
            zoom(to: model.pointsPerSecond * factor, anchorX: max(p.x, L.clipArea.minX))
            return
        }
        if flags.contains(.shift), !event.hasPreciseScrollingDeltas, dx == 0 { dx = dy; dy = 0 }
        if abs(dx) > 0 { scrollX -= dx }
        if abs(dy) > 0 {
            if L.maxScrollY > 0 { scrollY -= dy } else if !event.hasPreciseScrollingDeltas { scrollX -= dy }
        }
        clampScroll()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        zoom(to: model.pointsPerSecond * (1 + Double(event.magnification)), anchorX: max(p.x, layout.clipArea.minX))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let plain = flags.subtracting([.numericPad, .function, .capsLock]).isEmpty
        switch (event.keyCode, chars) {
        case (_, "s") where plain, (_, "S") where plain:
            if !editor.splitAtPlayhead() { NSSound.beep() }
        case (51, _), (117, _):  // delete, forward delete
            let ripple = flags.contains(.shift) || flags.contains(.command)
            if !editor.deleteSelection(ripple: ripple) { NSSound.beep() }
        case (_, "=") where flags.contains(.command), (_, "+") where flags.contains(.command):
            zoom(to: model.pointsPerSecond * TimelineZoom.step)
        case (_, "-") where flags.contains(.command):
            zoom(to: model.pointsPerSecond / TimelineZoom.step)
        case (_, "0") where flags.contains(.command):
            zoomToFit()
        case (123, _):  // left arrow: one frame back
            seek(to: model.playhead - snapshot.frameTicks)
        case (124, _):  // right arrow
            seek(to: model.playhead + snapshot.frameTicks)
        case (115, _):  // home
            seek(to: 0)
        case (119, _):  // end
            seek(to: snapshot.duration)
        case (_, "m") where plain, (_, "M") where plain:
            if !editor.addMarker(at: model.playhead) { NSSound.beep() }
        case (53, _):  // escape
            model.selection = []
        case (_, "a") where flags == .command:
            model.selection = Set(snapshot.allClips.map(\.id))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Drag and drop (media from Finder or the media bin)

    func dropPayload(_ info: any NSDraggingInfo) -> DropPayload? {
        let pb = info.draggingPasteboard
        let ids = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: TimelineView.sourceIDType) }
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }
            .compactMap { Int64($0) }
        if !ids.isEmpty { return .sources(ids) }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : .files(urls)
    }

    func dropLocation(_ p: CGPoint) -> (track: Int, ticks: Int64) {
        let L = layout
        let track = L.nearestTrack(atY: p.y) ?? 0
        var t = max(0, L.ticks(atX: max(p.x, L.clipArea.minX)))
        if let s = editor.snap(edges: [t], tolerance: snapTolerance, excluding: []) { t += s.delta }
        return (track, max(0, snapshot.quantize(t)))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard model.onDrop != nil, dropPayload(sender) != nil else { dropTarget = nil; return [] }
        dropTarget = dropLocation(convert(sender.draggingLocation, from: nil))
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropTarget = nil; needsDisplay = true }
        guard let payload = dropPayload(sender), let onDrop = model.onDrop else { return false }
        let loc = dropLocation(convert(sender.draggingLocation, from: nil))
        return onDrop(payload, loc.track, loc.ticks)
    }
}
