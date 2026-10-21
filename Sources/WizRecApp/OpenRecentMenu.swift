import AppKit
import PlayerKit

/// File ▸ Open Recent, rebuilt from `NSDocumentController.recentDocumentURLs` each time it
/// opens (AppKit only fills a recents menu it created from a nib).
@MainActor
final class OpenRecentMenu: NSObject, NSMenuDelegate {
    static let shared = OpenRecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Without the projects removed from the start screen's list.
        let urls = StartScreenModel.visibleRecents()
        for entry in RecentDocuments.entries(urls) {
            let item = NSMenuItem(title: entry.title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            item.toolTip = entry.url.path
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: String(localized: "Clear Menu"),
                     action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}
