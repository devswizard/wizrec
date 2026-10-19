import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Recorder

@Suite struct HUDFormatTests {
    @Test func elapsedText() {
        #expect(HUDFormat.elapsed(0) == "0:00")
        #expect(HUDFormat.elapsed(7.9) == "0:07")
        #expect(HUDFormat.elapsed(754) == "12:34")
        #expect(HUDFormat.elapsed(3723) == "1:02:03")
        #expect(HUDFormat.elapsed(-5) == "0:00")
        #expect(HUDFormat.elapsed(.nan) == "0:00")
    }

    @Test func regionFromDragFlipsToTopLeft() {
        // Display 1000 pt high; drag from (400, 700) to (100, 200) in view coordinates (bottom-left origin).
        let r = HUDFormat.regionRect(from: CGPoint(x: 400, y: 700), to: CGPoint(x: 100, y: 200), displayHeight: 1000)
        #expect(r == CGRect(x: 100, y: 300, width: 300, height: 500))
    }

    @Test func folderName() throws {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 19; c.hour = 17; c.minute = 11; c.second = 20
        let d = try #require(Calendar.current.date(from: c))
        #expect(HUDFormat.folderName(for: d) == "Recording 2026-10-19 17-11-20")
    }

    @Test func hotKeys() {
        #expect(HUDHotKey.startStop.displayString == "⇧⌘2")
        #expect(HUDHotKey.pauseResume.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(HUDHotKey.pauseResume.keyCode == UInt32(kVK_ANSI_P))
    }
}

@MainActor @Suite struct HUDModelTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-hud-test")

    @Test func optionsFollowTheChoices() throws {
        let m = RecorderHUDModel(outputDirectory: { [dir] in dir })
        m.target = .window(42)
        m.microphoneID = "mic"
        m.captureSystemAudio = true
        m.codec = .hevc
        m.frameRate = 60
        let o = try #require(m.makeOptions(outputDirectory: dir))
        #expect(o.target == .window(42))
        #expect(o.microphoneID == "mic" && o.cameraID == nil)
        #expect(o.captureSystemAudio && o.codec == .hevc && o.frameRate == 60)
        #expect(o.logCursor && !o.logKeystrokes && !o.cursorInVideo)
    }

    @Test func regionNeedsASelection() {
        let m = RecorderHUDModel(outputDirectory: { [dir] in dir })
        m.target = .region
        #expect(m.captureTarget == nil)
        m.toggleRecording()
        #expect(m.state == .idle && m.message != nil && m.session == nil)
        m.region = (1, CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(m.captureTarget == .region(1, CGRect(x: 0, y: 0, width: 100, height: 50)))
    }

    @Test func keystrokesNeedConsent() {
        let m = RecorderHUDModel()
        m.requestKeystrokeConsent = { false }
        m.setLogKeystrokes(true)
        #expect(!m.logKeystrokes)
    }

    @Test func controllerBuildsItsPanel() throws {
        _ = NSApplication.shared
        let c = RecorderHUDController(outputDirectory: { [dir] in dir })
        let panel = try #require(c.window as? NSPanel)
        #expect(panel.isFloatingPanel && panel.title == "WizRec Recorder")
        #expect(c.model.state == .idle)
        #expect(panel.contentView is NSHostingView<RecorderHUDView>)
    }

    @Test func pauseIgnoredWhenIdle() {
        let m = RecorderHUDModel()
        m.togglePause()
        #expect(m.state == .idle)
    }
}
