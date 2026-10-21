import Testing
@testable import PlayerKit

/// Editor toolbar layout (APP13-2).
@Suite struct EditorToolbarLayoutTests {
    @Test func defaultLayoutHasRecordAndExportLast() {
        let items = EditorToolbarLayout.defaultSlots.compactMap { slot -> EditorToolbarLayout.Item? in
            if case .item(let i) = slot { return i }
            return nil
        }
        #expect(items == [.importMedia, .record, .undo, .redo, .cropMode, .export])
        #expect(EditorToolbarLayout.defaultSlots.last == .item(.export))
        // Export sits alone on the trailing side, after a flexible space.
        #expect(EditorToolbarLayout.defaultSlots.dropLast().last == .flexibleSpace)
    }

    @Test func everyDefaultItemIsAllowedAndIdentifiersAreUnique() {
        let allowed = Set(EditorToolbarLayout.allowedItems)
        for case .item(let i) in EditorToolbarLayout.defaultSlots { #expect(allowed.contains(i)) }
        let ids = EditorToolbarLayout.Item.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("WizRec.toolbar.") })
        #expect(allowed.isSuperset(of: [.zoomIn, .zoomOut, .zoomToFit]))
    }
}
