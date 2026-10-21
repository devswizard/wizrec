import Testing
@testable import PlayerKit

@Suite struct WindowKeyLoopTests {
    // Panes: 0 library, 1 canvas, 2 inspector, 3 timeline.
    @Test func tabCrossesPanesAtTheirEdges() {
        let counts = [5, 1, 3, 1]
        #expect(WindowKeyLoop.step(pane: 0, position: 4, counts: counts, backward: false) == .enter(pane: 1, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 1, position: 0, counts: counts, backward: false) == .enter(pane: 2, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 2, position: 2, counts: counts, backward: false) == .enter(pane: 3, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 3, position: 0, counts: counts, backward: false) == .enter(pane: 0, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 0, position: 0, counts: counts, backward: true) == .enter(pane: 3, atEnd: true))
        #expect(WindowKeyLoop.step(pane: 2, position: 0, counts: counts, backward: true) == .enter(pane: 1, atEnd: true))
    }

    @Test func insideAPaneTheKeyStays() {
        let counts = [5, 1, 3, 1]
        #expect(WindowKeyLoop.step(pane: 0, position: 2, counts: counts, backward: false) == .withinPane)
        #expect(WindowKeyLoop.step(pane: 2, position: 1, counts: counts, backward: true) == .withinPane)
        #expect(WindowKeyLoop.step(pane: 0, position: 4, counts: counts, backward: true) == .withinPane)
    }

    @Test func emptyPanesAreSkipped() {
        // No clip selected: the inspector has nothing to focus.
        let counts = [5, 1, 0, 1]
        #expect(WindowKeyLoop.step(pane: 1, position: 0, counts: counts, backward: false) == .enter(pane: 3, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 3, position: 0, counts: counts, backward: true) == .enter(pane: 1, atEnd: true))
    }

    @Test func focusOutsideEveryPaneStartsAtAnEnd() {
        let counts = [0, 1, 3, 1]
        #expect(WindowKeyLoop.step(pane: nil, position: nil, counts: counts, backward: false) == .enter(pane: 1, atEnd: false))
        #expect(WindowKeyLoop.step(pane: nil, position: nil, counts: counts, backward: true) == .enter(pane: 3, atEnd: true))
        // A focused view that is no pane stop leaves its pane in the key's direction.
        #expect(WindowKeyLoop.step(pane: 2, position: nil, counts: counts, backward: false) == .enter(pane: 3, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 9, position: nil, counts: counts, backward: false) == .enter(pane: 1, atEnd: false))
    }

    @Test func aSinglePaneWrapsToItself() {
        #expect(WindowKeyLoop.step(pane: 1, position: 0, counts: [0, 1, 0, 0], backward: false) == .enter(pane: 1, atEnd: false))
        #expect(WindowKeyLoop.step(pane: 0, position: 0, counts: [0, 0, 0, 0], backward: false) == WindowKeyLoopStep.none)
        #expect(WindowKeyLoop.step(pane: nil, position: nil, counts: [], backward: false) == WindowKeyLoopStep.none)
    }
}
