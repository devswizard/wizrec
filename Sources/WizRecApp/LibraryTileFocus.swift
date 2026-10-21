import AppKit
import PlayerKit

/// Keyboard focus across one library grid's tiles (APP12-1). SwiftUI's hosting view leaves the
/// tiles' AppKit elements out of the window's key view loop, and the lazy grid only realizes
/// the tiles near the visible area, so the grid keeps its own order (`LibraryFocusOrder`, every
/// tile, realized or not). Tab to a tile that is not realized scrolls it into view and focuses
/// it once its element appears. At the ends focus leaves for the search field (Shift-Tab) or
/// the key view after the panel (Tab).
@MainActor final class LibraryTileFocus {
    /// Tile identifiers (`library.<name>`) in reading order, as the grid shows them now.
    var order: [String] = []
    /// Scrolls the tile with this identifier into view (`backward`: toward the top).
    var scrollTo: (_ id: String, _ backward: Bool) -> Void = { _, _ in }
    /// Focuses the search field above the grid.
    var focusSearchField: () -> Void = {}

    private final class Weak { weak var element: LibraryTileAccessibility.Element? }
    private var elements: [String: Weak] = [:]
    /// The tile to focus as soon as its element is realized (after a scroll), and until when.
    private var pending: (id: String, until: Date)?

    /// Records the realized element showing tile `id`; focuses it when a Tab is waiting for it.
    func register(_ element: LibraryTileAccessibility.Element, id: String) {
        let w = Weak()
        w.element = element
        elements[id] = w
        resolvePending()
    }

    /// The realized, on-window element of tile `id`, if any.
    func element(for id: String) -> LibraryTileAccessibility.Element? {
        guard let e = elements[id]?.element, e.tileID == id,
              e.window != nil, !e.isHiddenOrHasHiddenAncestor else { return nil }
        return e
    }

    /// Handles Tab / Shift-Tab on `element` (showing tile `id`). Always consumes the key.
    func move(from element: LibraryTileAccessibility.Element, id: String, backward: Bool) {
        let step = LibraryFocusOrder.step(from: id, backward: backward, in: order)
        perform(step, from: element, backward: backward)
    }

    /// Handles Tab from the search field: true when focus went into the grid.
    func enterFromSearchField(backward: Bool) -> Bool {
        guard let step = LibraryFocusOrder.stepFromSearchField(backward: backward, in: order) else { return false }
        perform(step, from: nil, backward: backward)
        return true
    }

    private func perform(_ step: LibraryFocusStep, from element: LibraryTileAccessibility.Element?, backward: Bool) {
        switch step {
        case .tile(let id):
            if let e = self.element(for: id), focus(e) { return }
            pending = (id, Date().addingTimeInterval(1.5))
            scrollTo(id, backward)
            // The element may already be realized off screen (no new registration follows).
            DispatchQueue.main.async { [weak self] in self?.resolvePending() }
        case .searchField:
            pending = nil
            focusSearchField()
        case .leavePanel:
            pending = nil
            guard let element else { return }
            leavePanel(from: element)
        }
    }

    private func resolvePending() {
        guard let p = pending else { return }
        if Date() > p.until { pending = nil; return }
        if let e = element(for: p.id), focus(e) { pending = nil }
    }

    private func focus(_ e: LibraryTileAccessibility.Element) -> Bool {
        guard let window = e.window, window.makeFirstResponder(e) else { return false }
        e.scrollToVisible(e.bounds)
        return true
    }

    /// Tab from the last tile: the key view AppKit's loop puts after the panel (the split
    /// view pane holding the grid); with no such key view the loop wraps to the search field.
    private func leavePanel(from element: LibraryTileAccessibility.Element) {
        guard let window = element.window else { return }
        let pane = Self.pane(of: element)
        if let next = pane.nextValidKeyView, next !== pane, !next.isDescendant(of: pane),
           window.makeFirstResponder(next) {
            return
        }
        focusSearchField()
    }

    /// The split view pane (or the outermost view below the window's content view) holding `view`.
    static func pane(of view: NSView) -> NSView {
        var v = view
        while let s = v.superview, !(s is NSSplitView), s !== v.window?.contentView { v = s }
        return v
    }
}
