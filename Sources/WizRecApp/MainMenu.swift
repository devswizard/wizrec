import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "WizRec")
        app.addItem(withTitle: "About WizRec", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide WizRec", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                                 keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit WizRec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)

        let view = NSMenu(title: "View")
        let overlay = view.addItem(withTitle: "Show Performance Overlay",
                                   action: #selector(PlayerWindowController.togglePerformanceOverlay(_:)),
                                   keyEquivalent: "p")
        overlay.keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                              keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        add(view, to: main)

        // Keys are handled by the player window; the menu lists them.
        let play = NSMenu(title: "Playback")
        play.addItem(withTitle: "Play/Pause  (Space)", action: #selector(PlayerWindowController.playPause(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Next Frame  (→)", action: #selector(PlayerWindowController.stepForward(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Previous Frame  (←)", action: #selector(PlayerWindowController.stepBackward(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Go to Start  (Home)", action: #selector(PlayerWindowController.goToStart(_:)), keyEquivalent: "")
        play.addItem(withTitle: "Go to End  (End)", action: #selector(PlayerWindowController.goToEnd(_:)), keyEquivalent: "")
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
