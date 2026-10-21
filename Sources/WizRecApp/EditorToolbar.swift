import AppKit
import PlayerKit
import TimelineUI

/// The editor window's toolbar (unified style, customizable; layout in `EditorToolbarLayout`).
/// Items send the same actions as their menu items to the first responder, so they enable and
/// disable with the menus (`EditorWindowController.validateToolbarItem`).
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    /// `autosave`: remember the user's arrangement (off in scripted runs, which never write
    /// the user's defaults).
    func make(autosave: Bool) -> NSToolbar {
        let bar = NSToolbar(identifier: EditorToolbarLayout.identifier)
        bar.delegate = self
        bar.allowsUserCustomization = true
        bar.autosavesConfiguration = autosave
        bar.displayMode = .iconOnly
        return bar
    }

    private static func id(_ item: EditorToolbarLayout.Item) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(item.rawValue)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        EditorToolbarLayout.defaultSlots.map { slot in
            switch slot {
            case .item(let i): Self.id(i)
            case .flexibleSpace: .flexibleSpace
            case .space: .space
            }
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        EditorToolbarLayout.allowedItems.map(Self.id) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let kind = EditorToolbarLayout.Item(rawValue: itemIdentifier.rawValue) else { return nil }
        let spec = Self.spec(kind)
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.tip
        item.image = Self.image(spec.symbol, label: spec.label, tint: kind == .record ? .systemRed : nil)
        item.action = spec.action
        item.target = nil   // first responder: the editor window, then its controller
        item.isBordered = true
        item.autovalidates = true
        if kind == .export {
            // The one primary action of the window: a prominent, accent-tinted button on macOS 26+.
            if #available(macOS 26.0, *) {
                item.style = .prominent
                item.backgroundTintColor = .controlAccentColor
            }
            // Text, not an icon: the button reads "Export" even in icon-only mode.
            item.image = nil
            item.title = spec.label
        }
        return item
    }

    private struct Spec {
        let label: String
        let tip: String
        let symbol: String
        let action: Selector
    }

    private static func spec(_ item: EditorToolbarLayout.Item) -> Spec {
        switch item {
        case .importMedia:
            Spec(label: String(localized: "Import"), tip: String(localized: "Import media into the project (⌘I)"),
                 symbol: "square.and.arrow.down", action: #selector(EditorWindowController.importMedia(_:)))
        case .record:
            Spec(label: String(localized: "Record"), tip: String(localized: "New recording (⌘R)"),
                 symbol: "record.circle", action: #selector(EditorWindowController.newRecording(_:)))
        case .undo:
            Spec(label: String(localized: "Undo"), tip: String(localized: "Undo (⌘Z)"),
                 symbol: "arrow.uturn.backward", action: #selector(EditorWindow.undo(_:)))
        case .redo:
            Spec(label: String(localized: "Redo"), tip: String(localized: "Redo (⇧⌘Z)"),
                 symbol: "arrow.uturn.forward", action: #selector(EditorWindow.redo(_:)))
        case .zoomOut:
            Spec(label: String(localized: "Zoom Out"), tip: String(localized: "Zoom the timeline out (⌘-)"),
                 symbol: "minus.magnifyingglass", action: #selector(TimelineView.zoomOut(_:)))
        case .zoomToFit:
            Spec(label: String(localized: "Zoom to Fit"), tip: String(localized: "Fit the timeline to the window (⌘0)"),
                 symbol: "arrow.left.and.right.square", action: #selector(TimelineView.zoomToFit(_:)))
        case .zoomIn:
            Spec(label: String(localized: "Zoom In"), tip: String(localized: "Zoom the timeline in (⌘=)"),
                 symbol: "plus.magnifyingglass", action: #selector(TimelineView.zoomIn(_:)))
        case .export:
            Spec(label: String(localized: "Export"), tip: String(localized: "Export the project as a video, GIF or audio file (⌘E)"),
                 symbol: "film.stack", action: #selector(EditorWindowController.showExport(_:)))
        }
    }

    private static func image(_ symbol: String, label: String, tint: NSColor?) -> NSImage? {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        guard let tint else { return base }
        return base?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
    }
}
