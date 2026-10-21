import Testing
@testable import PlayerKit

// QA15-1 / APP14-2: the editor window's whole Tab loop, composed the way the app wires it
// (`EditorKeyLoop`, `LibraryTileFocus`, the library search field's Tab handler, the window's
// key monitor), at the model level: `WindowKeyLoop.step` decides pane edges, and
// `LibraryFocusOrder` the library grid's own order. The app target is not testable, so the glue
// below follows those classes line by line:
// - a focused library tile handles Tab itself (`LibraryFocusOrder.step`); `.leavePanel` and a
//   `.searchField` step with no search field (the media bin) leave through
//   `EditorKeyLoop.leave` = `WindowKeyLoop.step(pane:, position: nil, …)`;
// - anything else goes through `EditorKeyLoop.handleTab`: `WindowKeyLoop.step` with the view's
//   index among its pane's stops; `.withinPane` in the library (it owns its Tab order) passes
//   the key on to the search field's handler (`LibraryFocusOrder.stepFromSearchField`), in other
//   panes moves to the next stop in reading order;
// - entering a pane focuses its first stop (Tab) or last stop (Shift-Tab); the library's stops
//   are its search field (when it has one) and the tiles realized on screen.

@Suite struct WindowKeyLoopIntegrationTests {
    enum Focus: Hashable, CustomStringConvertible {
        case search
        case tile(String)
        /// Stop `index` of pane `pane` (1 canvas, 2 inspector, 3 timeline).
        case stop(pane: Int, index: Int)

        var description: String {
            switch self {
            case .search: "search"
            case .tile(let id): id
            case .stop(let p, let i): "pane\(p)[\(i)]"
            }
        }
    }

    /// The window: panes library (0) → canvas (1) → inspector (2) → timeline (3).
    struct Window {
        /// Every tile of the library grid in reading order.
        var tiles: [String]
        /// Tiles the lazy grid has realized (a prefix or any subset of `tiles`).
        var realized: Set<String>
        /// The Library tab has a search field; the media bin does not.
        var hasSearchField = true
        /// Focusable stops of canvas, inspector and timeline.
        var otherCounts = [1, 3, 1]

        var realizedTiles: [String] { tiles.filter(realized.contains) }
        var libraryStops: [Focus] { (hasSearchField ? [.search] : []) + realizedTiles.map(Focus.tile) }
        var counts: [Int] { [libraryStops.count] + otherCounts }

        func enter(_ pane: Int, atEnd: Bool) -> Focus? {
            if pane == 0 { return atEnd ? libraryStops.last : libraryStops.first }
            let n = otherCounts[pane - 1]
            guard n > 0 else { return nil }
            return .stop(pane: pane, index: atEnd ? n - 1 : 0)
        }

        func perform(_ step: WindowKeyLoopStep) -> Focus? {
            guard case .enter(let p, let atEnd) = step else { return nil }
            return enter(p, atEnd: atEnd)
        }

        /// `EditorKeyLoop.leave(from:backward:)` out of the library.
        func leaveLibrary(backward: Bool) -> Focus? {
            perform(WindowKeyLoop.step(pane: 0, position: nil, counts: counts, backward: backward))
        }

        /// Where Tab (`backward` false) or Shift-Tab moves focus from `f`; nil = the key is
        /// left alone.
        func tab(from f: Focus, backward: Bool) -> Focus? {
            switch f {
            case .tile(let id):
                switch LibraryFocusOrder.step(from: id, backward: backward, in: tiles) {
                case .tile(let next): return .tile(next)
                case .searchField: return hasSearchField ? .search : leaveLibrary(backward: true)
                case .leavePanel: return leaveLibrary(backward: false)
                }
            case .search:
                let step = WindowKeyLoop.step(pane: 0, position: 0, counts: counts, backward: backward)
                if step == .withinPane {
                    // The library owns its order: the search field's own Tab handler.
                    guard case .tile(let id)? = LibraryFocusOrder.stepFromSearchField(backward: backward, in: tiles)
                    else { return nil }
                    return .tile(id)
                }
                return perform(step)
            case .stop(let pane, let index):
                let step = WindowKeyLoop.step(pane: pane, position: index, counts: counts, backward: backward)
                if step == .withinPane { return .stop(pane: pane, index: index + (backward ? -1 : 1)) }
                return perform(step)
            }
        }

        /// Focus after each of `presses` presses from `start`.
        func walk(from start: Focus, presses: Int, backward: Bool) -> [Focus] {
            var out: [Focus] = []
            var f = start
            for _ in 0..<presses {
                guard let next = tab(from: f, backward: backward) else { break }
                out.append(next)
                f = next
            }
            return out
        }
    }

    static let tiles = (1...6).map { "library.item\($0)" }

    /// Every stop once per lap, in order library → canvas → inspector → timeline, then back to
    /// the library's search field.
    @Test func tabVisitsEveryPaneInOrderAndWraps() {
        let w = Window(tiles: Self.tiles, realized: Set(Self.tiles))
        let lap: [Focus] = Self.tiles.map(Focus.tile)
            + [.stop(pane: 1, index: 0), .stop(pane: 2, index: 0), .stop(pane: 2, index: 1), .stop(pane: 2, index: 2),
               .stop(pane: 3, index: 0), .search]
        #expect(w.walk(from: .search, presses: lap.count, backward: false) == lap)
        #expect(w.walk(from: .search, presses: 2 * lap.count, backward: false) == lap + lap, "the loop repeats")
    }

    /// Shift-Tab runs the same lap backwards.
    @Test func shiftTabIsTheExactReverse() {
        let w = Window(tiles: Self.tiles, realized: Set(Self.tiles))
        let forward = w.walk(from: .search, presses: 11, backward: false)
        let back = w.walk(from: .search, presses: 11, backward: true)
        #expect(forward.count == 11 && back == Array(forward.reversed()))
    }

    /// Tab leaves the library from its last tile even when the lazy grid has realized only the
    /// first tiles (the grid's order covers every tile; the pane edge is crossed by `leave`).
    @Test func tabLeavesTheLibraryWithLazyTiles() {
        let w = Window(tiles: Self.tiles, realized: Set(Self.tiles.prefix(2)))
        let walk = w.walk(from: .search, presses: 8, backward: false)
        #expect(Array(walk.prefix(6)) == Self.tiles.map(Focus.tile), "unrealized tiles still in order")
        #expect(walk[6] == .stop(pane: 1, index: 0), "then the canvas")
        // Shift-Tab into the library lands on the last realized tile and walks back from there.
        let back = w.walk(from: .stop(pane: 1, index: 0), presses: 4, backward: true)
        #expect(back == [.tile("library.item2"), .tile("library.item1"), .search, .stop(pane: 3, index: 0)])
    }

    /// No clip selected: the inspector has nothing to focus and is skipped both ways.
    @Test func anEmptyInspectorIsSkipped() {
        var w = Window(tiles: Self.tiles, realized: Set(Self.tiles))
        w.otherCounts = [1, 0, 1]
        #expect(w.tab(from: .stop(pane: 1, index: 0), backward: false) == .stop(pane: 3, index: 0))
        #expect(w.tab(from: .stop(pane: 3, index: 0), backward: true) == .stop(pane: 1, index: 0))
    }

    /// The media bin grid has no search field: Shift-Tab from its first tile leaves backwards
    /// to the timeline, Tab from the last goes on to the canvas.
    @Test func theMediaBinLeavesAtBothEnds() {
        var w = Window(tiles: Self.tiles, realized: Set(Self.tiles))
        w.hasSearchField = false
        #expect(w.tab(from: .tile("library.item1"), backward: true) == .stop(pane: 3, index: 0))
        #expect(w.tab(from: .tile("library.item6"), backward: false) == .stop(pane: 1, index: 0))
        #expect(w.tab(from: .stop(pane: 3, index: 0), backward: false) == .tile("library.item1"))
    }

    /// A search with no hits: Tab from the search field leaves the library at once.
    @Test func anEmptySearchLeavesTheLibrary() {
        let w = Window(tiles: [], realized: [])
        #expect(w.tab(from: .search, backward: false) == .stop(pane: 1, index: 0))
        #expect(w.tab(from: .search, backward: true) == .stop(pane: 3, index: 0))
    }
}
