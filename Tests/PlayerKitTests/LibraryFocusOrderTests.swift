import Testing
@testable import PlayerKit

@Suite struct LibraryFocusOrderTests {
    let order = ["library.A", "library.B", "library.C"]

    @Test func tabAndShiftTabWalkTheReadingOrder() {
        #expect(LibraryFocusOrder.step(from: "library.A", backward: false, in: order) == .tile("library.B"))
        #expect(LibraryFocusOrder.step(from: "library.B", backward: false, in: order) == .tile("library.C"))
        #expect(LibraryFocusOrder.step(from: "library.C", backward: true, in: order) == .tile("library.B"))
        #expect(LibraryFocusOrder.step(from: "library.B", backward: true, in: order) == .tile("library.A"))
    }

    @Test func endsLeaveTheGrid() {
        #expect(LibraryFocusOrder.step(from: "library.C", backward: false, in: order) == .leavePanel)
        #expect(LibraryFocusOrder.step(from: "library.A", backward: true, in: order) == .searchField)
        #expect(LibraryFocusOrder.step(from: "library.X", backward: false, in: order) == .leavePanel)
        #expect(LibraryFocusOrder.step(from: "library.X", backward: true, in: order) == .searchField)
        #expect(LibraryFocusOrder.step(from: "library.A", backward: false, in: ["library.A"]) == .leavePanel)
    }

    /// The order covers every tile, realized or not: the 60th of 60 is reached from the 59th.
    @Test func reachesTilesBeyondTheRealizedOnes() {
        let many: [String] = (0..<60).map { "library.T\($0)" }
        var id = many[0]
        var visited: [String] = [id]
        while case .tile(let next) = LibraryFocusOrder.step(from: id, backward: false, in: many) {
            visited.append(next)
            id = next
        }
        #expect(visited == many)
        #expect(LibraryFocusOrder.step(from: id, backward: false, in: many) == .leavePanel)
    }

    @Test func searchFieldEntersTheGrid() {
        #expect(LibraryFocusOrder.stepFromSearchField(backward: false, in: order) == .tile("library.A"))
        #expect(LibraryFocusOrder.stepFromSearchField(backward: true, in: order) == nil)
        #expect(LibraryFocusOrder.stepFromSearchField(backward: false, in: []) == nil)
    }
}
