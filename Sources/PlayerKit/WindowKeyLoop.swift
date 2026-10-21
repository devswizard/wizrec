import Foundation

/// Where Tab / Shift-Tab moves keyboard focus in the editor window's pane loop.
public enum WindowKeyLoopStep: Equatable, Sendable {
    /// The key stays in the pane: AppKit (or the pane's own handler) moves focus.
    case withinPane
    /// Focus the first (`atEnd` false) or last (`atEnd` true) focusable view of pane `pane`.
    case enter(pane: Int, atEnd: Bool)
    /// No pane has anything to focus: leave the key alone.
    case none
}

/// The editor window's key view loop at pane level (APP14-2): library sidebar → canvas →
/// inspector → timeline → back to the sidebar. Each pane keeps its own order inside (AppKit's
/// loop, the library grid's `LibraryFocusOrder`); this decides only when focus crosses a pane
/// edge. Panes with nothing to focus (e.g. the inspector with no clip selected) are skipped.
public enum WindowKeyLoop {
    /// The step for Tab (`backward` false) or Shift-Tab.
    ///
    /// - `pane`: index of the pane holding the focused view; nil when focus is on no pane
    ///   (e.g. the window itself).
    /// - `position`: index of the focused view among that pane's focusable views (reading
    ///   order); nil when the focused view is not one of them.
    /// - `counts`: number of focusable views in each pane, in loop order.
    public static func step(pane: Int?, position: Int?, counts: [Int], backward: Bool) -> WindowKeyLoopStep {
        let n = counts.count
        guard n > 0 else { return .none }
        guard let pane, counts.indices.contains(pane) else {
            // Nothing focused yet: Tab starts at the first pane, Shift-Tab at the last.
            return enterFirst(from: backward ? n - 1 : 0, counts: counts, backward: backward)
        }
        if let position, counts[pane] > 0, position >= 0, position < counts[pane] {
            let atEdge = backward ? position == 0 : position == counts[pane] - 1
            if !atEdge { return .withinPane }
        }
        let next = (pane + (backward ? n - 1 : 1)) % n
        return enterFirst(from: next, counts: counts, backward: backward)
    }

    /// The first pane at or after `start` (in the key's direction, wrapping) with something to focus.
    private static func enterFirst(from start: Int, counts: [Int], backward: Bool) -> WindowKeyLoopStep {
        let n = counts.count
        for k in 0..<n {
            let i = backward ? (start - k + n) % n : (start + k) % n
            if counts[i] > 0 { return .enter(pane: i, atEnd: backward) }
        }
        return .none
    }
}
