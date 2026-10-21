import Foundation

/// Where Tab / Shift-Tab moves keyboard focus from a library tile.
public enum LibraryFocusStep: Equatable, Sendable {
    /// Focus the tile with this identifier (it may not be on screen yet: scroll it in first).
    case tile(String)
    /// Focus the key view before the grid (the panel's search field).
    case searchField
    /// Leave the panel: focus the key view after it in the window's key view loop.
    case leavePanel
}

/// Keyboard focus order of a library grid. Tiles are visited in reading order (`order`: the
/// sections top to bottom, each grid row-major), including tiles the lazy grid has not
/// realized yet. At the ends focus leaves the grid the way AppKit's key view loop runs through
/// the panel: Shift-Tab from the first tile goes back to the search field above the grid, and
/// Tab from the last tile goes on to the key view after the panel (AppKit then wraps the
/// window's loop round as usual).
public enum LibraryFocusOrder {
    /// The step for Tab (`backward` false) or Shift-Tab from the tile `id`. An `id` that is not
    /// in `order` (e.g. filtered out meanwhile) leaves the grid in the key's direction.
    public static func step(from id: String, backward: Bool, in order: [String]) -> LibraryFocusStep {
        guard let i = order.firstIndex(of: id) else { return backward ? .searchField : .leavePanel }
        let j = backward ? i - 1 : i + 1
        if order.indices.contains(j) { return .tile(order[j]) }
        return backward ? .searchField : .leavePanel
    }

    /// The step for Tab (`backward` false) or Shift-Tab from the search field: Tab enters the
    /// grid at its first tile; Shift-Tab (or Tab with no tiles shown) returns nil, leaving the
    /// key to AppKit's own key view loop.
    public static func stepFromSearchField(backward: Bool, in order: [String]) -> LibraryFocusStep? {
        guard !backward, let first = order.first else { return nil }
        return .tile(first)
    }
}
