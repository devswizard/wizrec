import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

// MARK: - Hand-built projects

/// Project with `editRate` 30 and 30 fps (one tick per frame), so values stay readable.
/// `tracks` and `attrs` are JSON text of the scene's `tracks` and `trackAttributes`.
@MainActor
func makeProject(tracks: String, attrs: String = "[]", sourceBin: String = defaultSourceBin,
                 editRate: Int = 30, fps: Int = 30) throws -> Project {
    let text = """
    {"title" : "t", "editRate" : \(editRate), "videoFormatFrameRate" : \(fps), "sourceBin" : \(sourceBin),
     "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : \(tracks)}}]},
                   "trackAttributes" : \(attrs)}}
    """
    return try Project(data: Data(text.utf8))
}

let defaultSourceBin = """
[{"id" : 1, "src" : "./media/1/clip.mp4", "rect" : [0, 0, 1920, 1080],
  "sourceTracks" : [{"type" : 0, "editRate" : 30, "range" : [0, 100000]},
                    {"type" : 2, "editRate" : 44100, "range" : [0, 100000000]}]},
 {"id" : 2, "src" : "./media/2/voice.m4a", "sourceTracks" : [{"type" : 2, "editRate" : 44100, "range" : [0, 100000000]}]},
 {"id" : 3, "src" : "./media/3/still.png", "rect" : [0, 0, 800, 600], "sourceTracks" : [{"type" : 1, "editRate" : 1, "range" : [0, 1]}]},
 {"id" : 4, "src" : "./media/4/bg.tscshadervid", "sourceTracks" : [{"type" : 0, "editRate" : 1, "range" : [0, 9223372036854775807]}]}]
"""

func vm(_ id: Int64, start: Int64, dur: Int64, ms: Int64 = 0, type: String = "VMFile", src: Int = 1,
        trackNumber: Int = 0, scalar: String = "1", md: String? = nil, extra: String = "") -> String {
    """
    {"id" : \(id), "_type" : "\(type)", "src" : \(src), "trackNumber" : \(trackNumber), \
    "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), "mediaDuration" : \(md ?? String(dur)), \
    "scalar" : \(scalar), "parameters" : {}, "effects" : []\(extra)}
    """
}

func unified(_ id: Int64, start: Int64, dur: Int64, ms: Int64 = 0) -> String {
    """
    {"id" : \(id), "_type" : "UnifiedMedia", "start" : \(start), "duration" : \(dur), "mediaStart" : \(ms), \
    "mediaDuration" : \(dur), "scalar" : 1, \
    "video" : \(vm(id + 1000, start: start, dur: dur, ms: ms)), \
    "audio" : \(vm(id + 2000, start: start, dur: dur, ms: ms, type: "AMFile", trackNumber: 1)), "effects" : []}
    """
}

func trackJSON(_ index: Int, _ medias: [String], transitions: String? = nil) -> String {
    let t = transitions.map { #", "transitions" : \#($0)"# } ?? ""
    return #"{"trackIndex" : \#(index), "medias" : [\#(medias.joined(separator: ", "))]\#(t), "parameters" : {}}"#
}

func tracksJSON(_ ts: String...) -> String { "[" + ts.joined(separator: ", ") + "]" }

func attr(_ ident: String = "", muted: Bool = false, hidden: Bool = false, locked: Bool = false,
          magnetic: Bool = false, height: Int? = nil) -> String {
    let h = height.map { #", "trackHeight" : "\#($0)""# } ?? ""
    return """
    {"ident" : "\(ident)", "audioMuted" : \(muted), "videoHidden" : \(hidden), "magnetic" : \(magnetic), \
    "matte" : 0, "solo" : false, "metadata" : {"IsLocked" : "\(locked ? "True" : "False")"\(h)}}
    """
}

/// Three tracks: 0 = unified A (0–90) + video B (120–210); 1 = audio C (30–150); 2 = empty, locked.
@MainActor
func sampleProject() throws -> Project {
    try makeProject(
        tracks: tracksJSON(
            trackJSON(0, [unified(10, start: 0, dur: 90), vm(20, start: 120, dur: 90, ms: 300)]),
            trackJSON(1, [vm(30, start: 30, dur: 120, type: "AMFile", src: 2)]),
            trackJSON(2, [])),
        attrs: "[\(attr("Video")), \(attr()), \(attr("Locked", locked: true))]")
}

// MARK: - Rendering

/// Renders `view` (dark appearance by default) into a bitmap at 1× scale.
@MainActor
func render(_ view: NSView, appearance: NSAppearance.Name = .darkAqua) -> NSBitmapImageRep {
    view.appearance = NSAppearance(named: appearance)
    view.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                               pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// sRGB components 0…255 at view point `p` (top-left origin).
func pixel(_ rep: NSBitmapImageRep, _ p: CGPoint) -> (r: Int, g: Int, b: Int) {
    guard let c = rep.colorAt(x: Int(p.x), y: Int(p.y))?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
    return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded()))
}

/// Writes `rep` as PNG into the test output folder and returns the URL.
@discardableResult
func savePNG(_ rep: NSBitmapImageRep, _ name: String) -> URL? {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIZREC_TUI_PNG_DIR"]
                  ?? NSTemporaryDirectory()).appendingPathComponent("timelineui-snapshots", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name + ".png")
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
    try? data.write(to: url)
    return url
}

/// Lets queued main-actor tasks (observation callbacks, media loads) run.
@MainActor
func drainMainQueue(_ iterations: Int = 20) async {
    for _ in 0..<iterations { await Task.yield() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<iterations { await Task.yield() }
}
