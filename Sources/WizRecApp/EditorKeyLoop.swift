import AppKit
import PlayerKit
import TimelineUI

/// The editor window's pane-level key view loop (APP14-2): library sidebar → canvas →
/// inspector → timeline → back to the sidebar, Shift-Tab the other way round.
///
/// Inside a pane, Tab keeps its usual order (AppKit's loop for fields, the library grids' own
/// `LibraryTileFocus`); `WindowKeyLoop` decides when focus crosses a pane edge. A pane's stops
/// are the views keyboard focus can rest on: controls that can become key views (text fields;
/// with Full Keyboard Access also buttons and sliders), library and media tiles, and the
/// pane's `singleStop` (the canvas, the timeline). Panes with no stop are skipped.
@MainActor final class EditorKeyLoop {
    /// One pane of the loop. `singleStop`: the pane is that one stop (its subviews are not).
    struct Pane {
        var view: NSView
        var singleStop: NSView?
        /// Views that are stops in addition to the pane's controls and tiles.
        var extraStops: [NSView] = []
        /// The pane moves focus between its own stops (the library grids); otherwise the loop
        /// moves Tab through the stops in reading order (SwiftUI's own field order can jump out
        /// of the pane).
        var ownsTabOrder = false
    }

    var panes: [Pane] = []

    /// Handles Tab (`backward` false) or Shift-Tab in `window`: true when the loop moved focus
    /// (the key is consumed), false when the key belongs to the focused pane (`ownsTabOrder`).
    func handleTab(in window: NSWindow, backward: Bool) -> Bool {
        let v = Self.responderView(window)
        let pane = v.flatMap(paneIndex(of:))
        var at: Int?
        if let pane, let v { at = stopIndex(of: v, in: pane) }
        let step = WindowKeyLoop.step(pane: pane, position: at, counts: counts(), backward: backward)
        if step == .withinPane, let pane, let at, !panes[pane].ownsTabOrder {
            let s = stops(in: pane)
            let next = at + (backward ? -1 : 1)
            guard s.indices.contains(next) else { return false }
            return window.makeFirstResponder(s[next])
        }
        return perform(step, in: window)
    }

    /// Leaves the pane holding `view` in the key's direction (a library grid's Tab past its last
    /// tile, or Shift-Tab before its first one). False when `view` is in no pane or nothing else
    /// takes focus.
    func leave(from view: NSView, backward: Bool) -> Bool {
        guard let window = view.window, let pane = paneIndex(of: view) else { return false }
        let step = WindowKeyLoop.step(pane: pane, position: nil, counts: counts(), backward: backward)
        return perform(step, in: window)
    }

    /// Index of the pane holding `view`.
    func paneIndex(of view: NSView) -> Int? {
        panes.firstIndex { view === $0.view || view.isDescendant(of: $0.view) }
    }

    /// The pane's stops in reading order (top to bottom, then left to right).
    func stops(in pane: Int) -> [NSView] {
        guard panes.indices.contains(pane) else { return [] }
        let p = panes[pane]
        if let s = p.singleStop { return Self.canFocus(s) ? [s] : [] }
        var found: [NSView] = p.extraStops.filter(Self.canFocus)
        Self.collect(in: p.view, into: &found)
        return found.sorted(by: Self.readingOrder)
    }

    // MARK: Private

    private func counts() -> [Int] { panes.indices.map { stops(in: $0).count } }

    private func stopIndex(of view: NSView, in pane: Int) -> Int? {
        let s = stops(in: pane)
        return s.firstIndex { view === $0 || view.isDescendant(of: $0) }
    }

    private func perform(_ step: WindowKeyLoopStep, in window: NSWindow) -> Bool {
        guard case .enter(let pane, let atEnd) = step else { return false }
        let s = stops(in: pane)
        guard let target = atEnd ? s.last : s.first else { return false }
        if window.makeFirstResponder(target) {
            target.scrollToVisible(target.bounds)
            (target as? KeyboardFocusRing)?.showsKeyboardFocus = true
            return true
        }
        return false
    }

    /// The view that has keyboard focus: a text field while its field editor is active.
    static func responderView(_ window: NSWindow) -> NSView? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            return (editor.delegate as? NSView) ?? editor
        }
        return window.firstResponder as? NSView
    }

    private static func isStop(_ v: NSView) -> Bool {
        (v is NSControl || v is LibraryTileAccessibility.Element) && canFocus(v)
    }

    private static func canFocus(_ v: NSView) -> Bool {
        v.window != nil && !v.isHiddenOrHasHiddenAncestor && v.canBecomeKeyView && !v.visibleRect.isEmpty
    }

    private static func collect(in view: NSView, into out: inout [NSView]) {
        for sub in view.subviews {
            if isStop(sub) {
                if !out.contains(where: { $0 === sub }) { out.append(sub) }
                // A control's subviews (e.g. a search field's buttons) are part of it.
                continue
            }
            collect(in: sub, into: &out)
        }
    }

    private static func readingOrder(_ a: NSView, _ b: NSView) -> Bool {
        let ra = a.convert(a.bounds, to: nil), rb = b.convert(b.bounds, to: nil)
        let ta = ra.maxY.rounded(), tb = rb.maxY.rounded()
        if abs(ta - tb) > 2 { return ta > tb }   // window coordinates: larger y is higher up
        return ra.minX < rb.minX
    }
}

/// A pane stop that draws its focus ring only when focused from the keyboard.
@MainActor protocol KeyboardFocusRing: AnyObject {
    var showsKeyboardFocus: Bool { get set }
}

extension EditorCanvasView: KeyboardFocusRing {}
extension TimelineUI.TimelineView: KeyboardFocusRing {}
