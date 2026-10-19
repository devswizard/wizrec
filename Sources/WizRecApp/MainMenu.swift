import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "WizRec")
        app.addItem(withTitle: "About WizRec", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide WizRec", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                    keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit WizRec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Project", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(.separator())
        file.addItem(withTitle: "Import Media…", action: #selector(EditorWindowController.importMedia(_:)), keyEquivalent: "i")
        file.addItem(withTitle: "Relink Missing Media…", action: #selector(EditorWindowController.showRelink(_:)),
                     keyEquivalent: "")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(EditorWindow.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(EditorWindow.redo(_:)), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let del = edit.addItem(withTitle: "Delete", action: #selector(EditorWindowController.delete(_:)),
                               keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter).map { Character($0) } ?? "\u{8}"))
        del.keyEquivalentModifierMask = []
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Show Performance Overlay",
                     action: #selector(EditorWindowController.togglePerformanceOverlay(_:)),
                     keyEquivalent: "p").keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        add(view, to: main)

        // Keys are handled by the editor window; the menu lists them.
        let play = NSMenu(title: "Playback")
        play.addItem(withTitle: "Play/Pause  (Space)", action: #selector(EditorWindowController.playPause(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Next Frame  (→)", action: #selector(EditorWindowController.stepForward(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Previous Frame  (←)", action: #selector(EditorWindowController.stepBackward(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Go to Start  (Home)", action: #selector(EditorWindowController.goToStart(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Go to End  (End)", action: #selector(EditorWindowController.goToEnd(_:)), keyEquivalent: "")
        add(play, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApplication.shared.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
