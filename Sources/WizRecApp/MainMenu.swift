import AppKit
import TimelineUI

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: String(localized: "WizRec"))
        app.addItem(withTitle: String(localized: "About WizRec"), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide WizRec"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)),
                    keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit WizRec"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: String(localized: "File"))
        file.addItem(withTitle: String(localized: "New Project"), action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: String(localized: "Open…"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.delegate = OpenRecentMenu.shared
        let recentItem = file.addItem(withTitle: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: String(localized: "Save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: String(localized: "Save As…"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(withTitle: String(localized: "Export…"), action: #selector(EditorWindowController.showExport(_:)), keyEquivalent: "e")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "New Recording…"), action: #selector(EditorWindowController.newRecording(_:)), keyEquivalent: "r")
        file.addItem(withTitle: String(localized: "Import Media…"), action: #selector(EditorWindowController.importMedia(_:)), keyEquivalent: "i")
        file.addItem(withTitle: String(localized: "Relink Missing Media…"), action: #selector(EditorWindowController.showRelink(_:)),
                     keyEquivalent: "")
        add(file, to: main)

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: #selector(EditorWindow.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: #selector(EditorWindow.redo(_:)), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let del = edit.addItem(withTitle: String(localized: "Delete"), action: #selector(EditorWindowController.delete(_:)),
                               keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter).map { Character($0) } ?? "\u{8}"))
        del.keyEquivalentModifierMask = []
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let clip = NSMenu(title: String(localized: "Clip"))
        clip.addItem(withTitle: String(localized: "Group"), action: #selector(EditorWindowController.groupClips(_:)), keyEquivalent: "g")
        clip.addItem(withTitle: String(localized: "Ungroup"), action: #selector(EditorWindowController.ungroupClip(_:)), keyEquivalent: "G")
        clip.addItem(.separator())
        clip.addItem(withTitle: String(localized: "Stitch Selected Media"), action: #selector(EditorWindowController.stitchClips(_:)), keyEquivalent: "")
        clip.addItem(withTitle: String(localized: "Unstitch"), action: #selector(EditorWindowController.unstitchClip(_:)), keyEquivalent: "")
        clip.addItem(.separator())
        clip.addItem(withTitle: String(localized: "Separate Video and Audio"), action: #selector(EditorWindowController.detachAudio(_:)), keyEquivalent: "")
        add(clip, to: main)

        let captions = NSMenu(title: String(localized: "Captions"))
        captions.addItem(withTitle: String(localized: "Transcribe Selected Audio"),
                         action: #selector(EditorWindowController.transcribeSelection(_:)), keyEquivalent: "")
        captions.addItem(withTitle: String(localized: "Cancel Transcription"),
                         action: #selector(EditorWindowController.cancelTranscription(_:)), keyEquivalent: "")
        captions.addItem(withTitle: String(localized: "Add Dynamic Captions"),
                         action: #selector(EditorWindowController.addDynamicCaptions(_:)), keyEquivalent: "")
        captions.addItem(withTitle: String(localized: "Dynamic Caption Style…"),
                         action: #selector(EditorWindowController.editDynamicCaptionStyle(_:)), keyEquivalent: "")
        captions.addItem(.separator())
        captions.addItem(withTitle: String(localized: "Import Captions…"),
                         action: #selector(EditorWindowController.importCaptions(_:)), keyEquivalent: "")
        captions.addItem(withTitle: String(localized: "Export Captions as SRT…"),
                         action: #selector(EditorWindowController.exportCaptionsSRT(_:)), keyEquivalent: "")
        captions.addItem(withTitle: String(localized: "Export Captions as WebVTT…"),
                         action: #selector(EditorWindowController.exportCaptionsVTT(_:)), keyEquivalent: "")
        captions.addItem(.separator())
        captions.addItem(withTitle: String(localized: "Delete All Captions"),
                         action: #selector(EditorWindowController.deleteCaptions(_:)), keyEquivalent: "")

        // Sent to the first responder: TimelineView implements and validates these; the
        // editor window forwards them to the timeline when it is not focused.
        let timeline = NSMenu(title: String(localized: "Timeline"))
        timeline.addItem(withTitle: String(localized: "Split at Playhead  (S)"), action: #selector(TimelineView.splitAtPlayhead(_:)), keyEquivalent: "")
        timeline.addItem(withTitle: String(localized: "Ripple Delete"), action: #selector(TimelineView.rippleDelete(_:)),
                         keyEquivalent: String(Character(UnicodeScalar(NSBackspaceCharacter) ?? "\u{8}")))
            .keyEquivalentModifierMask = [.shift]
        timeline.addItem(.separator())
        timeline.addItem(withTitle: String(localized: "Add Marker  (M)"), action: #selector(TimelineView.addMarker(_:)), keyEquivalent: "")
        timeline.addItem(withTitle: String(localized: "Extend Frame"), action: #selector(TimelineView.extendFrame(_:)), keyEquivalent: "")
        timeline.addItem(.separator())
        timeline.addItem(withTitle: String(localized: "Add Track"), action: #selector(TimelineView.addTrack(_:)), keyEquivalent: "")
        // Removes the selected clip's track (inside an open group: its inner track).
        timeline.addItem(withTitle: String(localized: "Remove Track"), action: #selector(TimelineView.removeTrack(_:)), keyEquivalent: "")
        timeline.addItem(withTitle: String(localized: "Snapping"), action: #selector(TimelineView.toggleSnapping(_:)), keyEquivalent: "")
        timeline.addItem(.separator())
        timeline.addItem(withTitle: String(localized: "Zoom In"), action: #selector(TimelineView.zoomIn(_:)), keyEquivalent: "=")
        timeline.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(TimelineView.zoomOut(_:)), keyEquivalent: "-")
        timeline.addItem(withTitle: String(localized: "Zoom to Fit"), action: #selector(TimelineView.zoomToFit(_:)), keyEquivalent: "0")
        timeline.addItem(.separator())
        timeline.addItem(withTitle: String(localized: "Deselect All"), action: #selector(TimelineView.deselectAll(_:)), keyEquivalent: "A")
        add(timeline, to: main)
        add(captions, to: main)

        let view = NSMenu(title: String(localized: "View"))
        view.addItem(withTitle: String(localized: "Show Performance Overlay"),
                     action: #selector(EditorWindowController.togglePerformanceOverlay(_:)),
                     keyEquivalent: "p").keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: String(localized: "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        add(view, to: main)

        // Keys are handled by the editor window; the menu lists them.
        let play = NSMenu(title: String(localized: "Playback"))
        play.addItem(withTitle: String(localized: "Play/Pause  (Space)"), action: #selector(EditorWindowController.playPause(_:)), keyEquivalent: "")
        play.addItem(withTitle: String(localized: "Next Frame  (→)"), action: #selector(EditorWindowController.stepForward(_:)), keyEquivalent: "")
        play.addItem(withTitle: String(localized: "Previous Frame  (←)"), action: #selector(EditorWindowController.stepBackward(_:)), keyEquivalent: "")
        play.addItem(withTitle: String(localized: "Go to Start  (Home)"), action: #selector(EditorWindowController.goToStart(_:)), keyEquivalent: "")
        play.addItem(withTitle: String(localized: "Go to End  (End)"), action: #selector(EditorWindowController.goToEnd(_:)), keyEquivalent: "")
        add(play, to: main)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApplication.shared.windowsMenu = window

        let help = NSMenu(title: String(localized: "Help"))
        help.addItem(withTitle: String(localized: "Welcome to WizRec"), action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "")
        help.addItem(withTitle: String(localized: "Show Crash Reports"), action: #selector(AppDelegate.showCrashReports(_:)), keyEquivalent: "")
        add(help, to: main)
        NSApplication.shared.helpMenu = help

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
