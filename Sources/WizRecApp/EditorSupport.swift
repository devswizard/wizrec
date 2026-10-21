import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// UI-only state of an editor window (never stored in the project).
@MainActor @Observable
final class EditorUIState {
    var showOverlay = false
    var compositorError: String?
    /// Last error or status line shown above the canvas; cleared after a few seconds.
    var message: String?
    var isImporting = false
    /// Media is being dragged over the canvas (it shows a drop outline).
    var canvasDropTargeted = false
    /// A long-running job's status (e.g. "Transcribing voice.wav… 40%"); nil when idle.
    var activity: String?
    private var messageToken = 0

    func show(_ text: String, seconds: Double = 6) {
        message = text
        print("WizRec: status \(text)")   // UI checks read status lines
        fflush(stdout)
        messageToken += 1
        let token = messageToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if self?.messageToken == token { self?.message = nil }
        }
    }
}

/// What a drag onto the bin, canvas or timeline carries.
enum MediaDrop: Equatable {
    /// Files from Finder (imported first).
    case files([URL])
    /// Source-bin ids dragged from the media bin.
    case sources([Int64])

    /// Pasteboard type of a media-bin item: UTF-8 string = source id.
    static let sourceType = NSPasteboard.PasteboardType("com.devswizard.wizrec.source-id")
    static let sourceUTType = UTType(exportedAs: "com.devswizard.wizrec.source-id")
    static let types: [NSPasteboard.PasteboardType] = [sourceType, .fileURL]

    /// Reads a drop from `pasteboard`; bin items win over files.
    static func read(_ pasteboard: NSPasteboard) -> MediaDrop? {
        let ids = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: sourceType).flatMap { Int64($0) } }
        if !ids.isEmpty { return .sources(ids) }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : .files(urls)
    }
}

/// Editor window: routes Undo/Redo to the project's undo history unless a text field
/// is being edited (then the field editor's own undo applies).
final class EditorWindow: NSWindow, NSToolbarItemValidation {
    weak var editor: EditorWindowController?
    private let fieldUndo = UndoManager()

    private var editingText: Bool { firstResponder is NSText }

    override var undoManager: UndoManager? { editingText ? fieldUndo : nil }

    @objc func undo(_ sender: Any?) {
        if editingText { fieldUndo.undo() } else { editor?.undoEdit() }
    }

    @objc func redo(_ sender: Any?) {
        if editingText { fieldUndo.redo() } else { editor?.redoEdit() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            let isUndo = item.action == #selector(undo(_:))
            if editingText {
                let ok = isUndo ? fieldUndo.canUndo : fieldUndo.canRedo
                (item as? NSMenuItem)?.title = isUndo ? fieldUndo.undoMenuItemTitle : fieldUndo.redoMenuItemTitle
                return ok
            }
            let name = isUndo ? editor?.model.undo.undoName : editor?.model.undo.redoName
            (item as? NSMenuItem)?.title = (isUndo ? "Undo" : "Redo") + (name.map { " " + $0 } ?? "")
            return name != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Undo/Redo toolbar items: the same rules as the Edit menu (other items reach the
    /// controller, which `NSToolbarItem` asks itself).
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) { return validateUserInterfaceItem(item) }
        return true
    }
}

/// Split view whose divider positions persist in UserDefaults (`autosaveName`), with
/// default positions on first launch.
final class EditorSplitView: NSSplitView {
    /// Default sizes of the first `n − 1` panes (points along the split axis) for the
    /// split's size, used when nothing was saved yet.
    var defaultSizes: (CGSize) -> [CGFloat] = { _ in [] }
    private var needsDefaults = false

    /// Sets `autosaveName`, remembering whether a saved layout existed before AppKit
    /// writes one during the first layout.
    func persist(as name: String) {
        needsDefaults = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") == nil
        autosaveName = name
    }

    /// Uses the default layout without restoring or saving one (`--window-size` runs).
    func useDefaultLayout() {
        needsDefaults = true
        autosaveName = nil
    }

    /// Applies `defaultSizes` once, when no layout was saved. Call after the window is laid out.
    func applyDefaultsIfNeeded() {
        guard needsDefaults, bounds.width > 0, bounds.height > 0 else { return }
        needsDefaults = false
        var pos: CGFloat = 0
        for (i, size) in defaultSizes(bounds.size).enumerated() where i < subviews.count - 1 {
            pos += size
            setPosition(pos, ofDividerAt: i)
            pos += dividerThickness
        }
    }
}

/// Hosting view that lets clicks through wherever its SwiftUI content has no control
/// (the canvas overlay: banners pass clicks to the canvas, buttons still work).
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Media drags over the overlay's own controls (e.g. the empty canvas's buttons) go to this
    /// view (the canvas below), so the whole canvas area takes drops.
    weak var dropTarget: NSView? {
        didSet { if dropTarget != nil { registerForDraggedTypes(MediaDrop.types) } else { unregisterDraggedTypes() } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingEntered(sender) ?? []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingUpdated(sender) ?? []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropTarget?.draggingExited(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { dropTarget?.draggingEnded(sender) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget?.performDragOperation(sender) ?? false
    }
}
