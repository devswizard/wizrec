// wizrec-record: manual check of the Recorder module from Terminal.
//
//   swift run wizrec-record --list
//   swift run wizrec-record <out-dir> [--seconds 5] [--pause-at 2 --pause-for 1] [--window ID]
//                           [--region X,Y,W,H] [--mic] [--camera] [--system-audio] [--keys] [--hevc]
//   swift run wizrec-record <out-dir> --hud      (recorder HUD; each recording goes to <out-dir>/<date>)
//
// Permissions are granted to the app that runs it (Terminal, iTerm, VS Code…).

import AppKit
import CoreMedia
import Foundation
import Recorder

let args = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if args.contains("--list") {
    for d in CaptureSources.displays() {
        print("display \(d.id)\(d.isMain ? " (main)" : ""): \(d.name) \(Int(d.frame.width))×\(Int(d.frame.height)) pt, \(d.pixelWidth)×\(d.pixelHeight) px")
    }
    for c in CaptureSources.cameras() { print("camera \(c.id)\(c.isDefault ? " (default)" : ""): \(c.name)") }
    for m in CaptureSources.microphones() { print("microphone \(m.id)\(m.isDefault ? " (default)" : ""): \(m.name)") }
    print("permissions: screen \(RecorderPermissions.screenRecording), camera \(RecorderPermissions.camera.rawValue), microphone \(RecorderPermissions.microphone.rawValue), keystrokes \(RecorderPermissions.keystrokeMonitoring)")
    Task { @MainActor in
        do {
            for w in try await CaptureSources.windows() { print("window \(w.id): \(w.appName) — \(w.title)") }
        } catch {
            print("windows: unavailable (\(error.localizedDescription))")
        }
        exit(0)
    }
    app.run()
}

guard let outArg = args.first, !outArg.hasPrefix("--") else { fail("usage: wizrec-record <out-dir> [options] | --list") }
let outDir = URL(fileURLWithPath: (outArg as NSString).expandingTildeInPath, isDirectory: true)
if outDir.standardizedFileURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/WizRec").path) {
    fail("refusing to write into ~/Movies/WizRec; pick another folder")
}

func printResult(_ r: RecordingResult, warnings: [String]) {
    print("duration: \(String(format: "%.3f", r.duration.seconds)) s")
    print("screen: \(r.screen.path)")
    if let c = r.camera { print("camera: \(c.path)") }
    for a in r.audio { print("audio: \(a.path)") }
    if let l = r.cursorLog { print("cursor log: \(l.path)") }
    for w in warnings { print("warning: \(w)") }
}

if args.contains("--hud") {
    let hud = RecorderHUDController(
        outputDirectory: { outDir.appendingPathComponent(HUDFormat.folderName(for: Date()), isDirectory: true) },
        onFinish: { result in
            switch result {
            case let .success(r): printResult(r, warnings: [])
            case let .failure(e): print("error: \(e)")
            }
        }
    )
    hud.present()
    print("HUD open: \(HUDHotKey.startStop.displayString) start/stop, \(HUDHotKey.pauseResume.displayString) pause. Ctrl-C to quit.")
    app.run()
}

var target = CaptureTarget.display(CGMainDisplayID())
if let w = value("--window"), let id = UInt32(w) { target = .window(id) }
if let r = value("--region") {
    let n = r.split(separator: ",").compactMap { Double($0) }
    guard n.count == 4 else { fail("--region X,Y,W,H (points, top-left of the main display)") }
    target = .region(CGMainDisplayID(), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
}
var options = RecordingOptions(target: target, outputDirectory: outDir)
options.captureSystemAudio = args.contains("--system-audio")
options.logKeystrokes = args.contains("--keys")
options.codec = args.contains("--hevc") ? .hevc : .h264
if args.contains("--mic") { options.microphoneID = CaptureSources.microphones().first(where: \.isDefault)?.id ?? CaptureSources.microphones().first?.id }
if args.contains("--camera") { options.cameraID = CaptureSources.cameras().first(where: \.isDefault)?.id ?? CaptureSources.cameras().first?.id }
let seconds = Double(value("--seconds") ?? "5") ?? 5
let pauseAt = value("--pause-at").flatMap(Double.init)
let pauseFor = Double(value("--pause-for") ?? "1") ?? 1

Task { @MainActor in
    let session = RecordingSession(options: options)
    session.onStateChange = { print("state: \($0)") }
    do {
        try await session.start(countdown: 3)
        let start = Date()
        if let p = pauseAt, p < seconds {
            try await Task.sleep(nanoseconds: UInt64(p * 1e9))
            session.pause()
            try await Task.sleep(nanoseconds: UInt64(pauseFor * 1e9))
            session.resume()
        }
        let remaining = seconds - Date().timeIntervalSince(start) + (pauseAt == nil ? 0 : pauseFor)
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
        let result = try await session.stop()
        printResult(result, warnings: session.warnings)
        exit(0)
    } catch {
        fail("error: \(error)")
    }
}
app.run()
