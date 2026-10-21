import AppKit

/// Which timeline toolbar buttons can act now; the window controller recomputes it when the
/// selection, playhead, project, undo history or pasteboard change.
struct TimelineToolbarState: Equatable {
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
/// the left, add track and snapping next, zoom on the right. Every button names its shortcut
/// in its tooltip and is disabled when it cannot act. Plain AppKit buttons (never the keyboard
/// focus without Full Keyboard Access, so Space and the arrow keys stay with the editor).
@MainActor final class TimelineToolbarView: NSView {
    static let height: CGFloat = 30

    private let actions: TimelineToolbarActions
    private var buttons: [String: NSButton] = [:]
    private var handlers: [ObjectIdentifier: () -> Void] = [:]
    private(set) var state = TimelineToolbarState()

    init(actions: TimelineToolbarActions) {
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Timeline tools"))

        let left = NSStackView(views: [
            make("timeline.undo", "arrow.uturn.backward", String(localized: "Undo"), String(localized: "Undo (⌘Z)"), actions.undo),
            make("timeline.redo", "arrow.uturn.forward", String(localized: "Redo"), String(localized: "Redo (⇧⌘Z)"), actions.redo),
            Self.separator(),
            make("timeline.cut", "scissors", String(localized: "Cut"), String(localized: "Cut the selected clips (⌘X)"), actions.cut),
            make("timeline.copy", "doc.on.doc", String(localized: "Copy"), String(localized: "Copy the selected clips (⌘C)"), actions.copy),
            make("timeline.paste", "doc.on.clipboard", String(localized: "Paste"), String(localized: "Paste at the playhead (⌘V)"),
                 actions.paste),
            Self.separator(),
            make("timeline.split", "square.split.1x2", String(localized: "Split"), String(localized: "Split at the playhead (S)"),
                 actions.split),
            make("timeline.delete", "trash", String(localized: "Delete"),
                 String(localized: "Delete the selected clips, leaving a gap (⌫)"), actions.delete),
            make("timeline.rippleDelete", "delete.backward", String(localized: "Ripple Delete"),
                 String(localized: "Delete the selected clips and close the gap (⇧⌫)"), actions.rippleDelete),
            Self.separator(),
            make("timeline.addTrack", "plus.rectangle.on.rectangle", String(localized: "Add Track"),
                 String(localized: "Add a track on top"), actions.addTrack),
            make("timeline.snapping", "point.topleft.down.to.point.bottomright.curvepath", String(localized: "Snapping"),
                 String(localized: "Snapping: clips snap to edges, the playhead and markers"), actions.toggleSnapping, toggle: true),
        ])
        let right = NSStackView(views: [
            make("timeline.zoomOut", "minus.magnifyingglass", String(localized: "Zoom Out"), String(localized: "Zoom out (⌘−)"),
                 actions.zoomOut),
            make("timeline.zoomToFit", "arrow.left.and.right.square", String(localized: "Zoom to Fit"),
                 String(localized: "Show the whole timeline (⌘0)"), actions.zoomToFit),
            make("timeline.zoomIn", "plus.magnifyingglass", String(localized: "Zoom In"), String(localized: "Zoom in (⌘=)"),
                 actions.zoomIn),
        ])
        for s in [left, right] {
            s.orientation = .horizontal
            s.spacing = 2
            s.translatesAutoresizingMaskIntoConstraints = false
            addSubview(s)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
        ])
        apply(state, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Shows `new`: enabled states, the snapping toggle and the undo/redo tooltips.
    func apply(_ new: TimelineToolbarState, force: Bool = false) {
        guard force || new != state else { return }
        state = new
        let enabled: [String: Bool] = [
            "timeline.undo": new.canUndo, "timeline.redo": new.canRedo, "timeline.cut": new.canCut,
            "timeline.copy": new.canCopy, "timeline.paste": new.canPaste, "timeline.split": new.canSplit,
            "timeline.delete": new.canDelete, "timeline.rippleDelete": new.canDelete,
            "timeline.zoomIn": new.canZoomIn, "timeline.zoomOut": new.canZoomOut,
        ]
        for (id, on) in enabled { buttons[id]?.isEnabled = on }
        buttons["timeline.snapping"]?.state = new.snapping ? .on : .off
        buttons["timeline.undo"]?.toolTip = new.undoName.map { String(localized: "Undo \($0) (⌘Z)") } ?? String(localized: "Undo (⌘Z)")
        buttons["timeline.redo"]?.toolTip = new.redoName.map { String(localized: "Redo \($0) (⇧⌘Z)") } ?? String(localized: "Redo (⇧⌘Z)")
    }

    private func make(_ id: String, _ symbol: String, _ label: String, _ tip: String, _ action: @escaping () -> Void,
                      toggle: Bool = false) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: label) ?? NSImage()
        let b = NSButton(image: image, target: self, action: #selector(press(_:)))
        b.bezelStyle = .accessoryBarAction
        b.isBordered = toggle
        b.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
        b.imageScaling = .scaleProportionallyDown
        b.toolTip = tip
        b.setAccessibilityLabel(label)
        b.setAccessibilityIdentifier(id)
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        buttons[id] = b
        handlers[ObjectIdentifier(b)] = action
        return b
    }

    @objc private func press(_ sender: NSButton) { handlers[ObjectIdentifier(sender)]?() }

    private static func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 9).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }
}
