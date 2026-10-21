import AppKit
import Observation
import SwiftUI

/// Which timeline toolbar buttons can act now; the window controller refreshes it when the
/// selection, playhead, project, undo history or pasteboard change.
@MainActor @Observable
final class TimelineToolbarState {
    var canUndo = false
    var canRedo = false
    var undoName: String?
    var redoName: String?
    var canCut = false
    var canCopy = false
    var canPaste = false
    var canSplit = false
    var canDelete = false
    var canZoomIn = true
    var canZoomOut = true
    var snapping = true
}

/// What the timeline toolbar's buttons do (the same actions as the Edit and Timeline menus).
struct TimelineToolbarActions {
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var cut: () -> Void = {}
    var copy: () -> Void = {}
    var paste: () -> Void = {}
    var split: () -> Void = {}
    var delete: () -> Void = {}
    var rippleDelete: () -> Void = {}
    var addTrack: () -> Void = {}
    var toggleSnapping: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomToFit: () -> Void = {}
    var zoomIn: () -> Void = {}
}

/// The bar above the timeline (ui-workflow.md §9): undo/redo, clipboard, split and delete on
/// the left, track and snapping in the middle, zoom on the right. Every button names its
/// shortcut in its tooltip and is disabled when it cannot act.
struct TimelineToolbar: View {
    static let height: CGFloat = 30
    let state: TimelineToolbarState
    let actions: TimelineToolbarActions

    var body: some View {
        HStack(spacing: 4) {
            button("arrow.uturn.backward", "Undo", undoHelp, "timeline.undo", state.canUndo, actions.undo)
            button("arrow.uturn.forward", "Redo", redoHelp, "timeline.redo", state.canRedo, actions.redo)
            divider
            button("scissors", "Cut", "Cut the selected clips (⌘X)", "timeline.cut", state.canCut, actions.cut)
            button("doc.on.doc", "Copy", "Copy the selected clips (⌘C)", "timeline.copy", state.canCopy, actions.copy)
            button("doc.on.clipboard", "Paste", "Paste at the playhead (⌘V)", "timeline.paste", state.canPaste, actions.paste)
            divider
            button("square.split.1x2", "Split", "Split at the playhead (S)", "timeline.split", state.canSplit, actions.split)
            button("trash", "Delete", "Delete the selected clips, leaving a gap (⌫)", "timeline.delete",
                   state.canDelete, actions.delete)
            button("delete.backward", "Ripple Delete", "Delete the selected clips and close the gap (⇧⌫)",
                   "timeline.rippleDelete", state.canDelete, actions.rippleDelete)
            divider
            button("plus.rectangle.on.rectangle", "Add Track", "Add a track on top", "timeline.addTrack", true, actions.addTrack)
            Toggle(isOn: Binding(get: { state.snapping }, set: { _ in actions.toggleSnapping() })) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Snapping: clips snap to edges, the playhead and markers")
            .accessibilityLabel("Snapping")
            .accessibilityIdentifier("timeline.snapping")
            Spacer(minLength: 8)
            button("minus.magnifyingglass", "Zoom Out", "Zoom out (⌘−)", "timeline.zoomOut", state.canZoomOut, actions.zoomOut)
            button("arrow.left.and.right.square", "Zoom to Fit", "Show the whole timeline (⌘0)", "timeline.zoomToFit",
                   true, actions.zoomToFit)
            button("plus.magnifyingglass", "Zoom In", "Zoom in (⌘=)", "timeline.zoomIn", state.canZoomIn, actions.zoomIn)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline tools")
    }

    private var undoHelp: String {
        state.undoName.map { String(localized: "Undo \($0) (⌘Z)") } ?? String(localized: "Undo (⌘Z)")
    }

    private var redoHelp: String {
        state.redoName.map { String(localized: "Redo \($0) (⇧⌘Z)") } ?? String(localized: "Redo (⇧⌘Z)")
    }

    private var divider: some View { Divider().frame(height: 16).padding(.horizontal, 3) }

    private func button(_ symbol: String, _ label: LocalizedStringKey, _ help: String, _ id: String, _ enabled: Bool,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 22, height: 20) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(help)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}
