import CoreGraphics
import Foundation
import TSCProjKit
@testable import RenderEngine

/// Builders for small hand-written projects. The JSON is test input only;
/// projects are parsed with `Project(data:)` like any real file.
enum P {
    static let rate: Int64 = 705_600_000

    static func project(tracks: [[String: Any]], sources: [[String: Any]] = defaultSources,
                        trackAttributes: [[String: Any]]? = nil, background: [Int]? = nil,
                        width: Double = 1920, height: Double = 1080) throws -> Project {
        var timeline: [String: Any] = [
            "id": 1,
            "sceneTrack": ["scenes": [["csml": ["tracks": tracks]]]],
        ]
        if let trackAttributes { timeline["trackAttributes"] = trackAttributes }
        if let background { timeline["backgroundColor"] = background }
        let root: [String: Any] = [
            "version": "10.0", "editRate": rate, "width": width, "height": height,
            "videoFormatFrameRate": 30, "sourceBin": sources, "timeline": timeline,
        ]
        return try Project(data: JSONSerialization.data(withJSONObject: root))
    }

    static var defaultSources: [[String: Any]] { [
        source(1, "./media/a.mp4", w: 1280, h: 720, tracks: [0, 2]),
        source(2, "./media/b.png", w: 400, h: 300, tracks: [1]),
        source(3, "./media/bg.tscshadervid", w: 1920, h: 1080, tracks: [0]),
        source(4, "./media/c.m4a", w: 0, h: 0, tracks: [2]),
    ] }

    static func source(_ id: Int, _ src: String, w: Int, h: Int, tracks: [Int],
                       trackRects: [[Int]]? = nil) -> [String: Any] {
        ["id": id, "src": src, "rect": [0, 0, w, h],
         "sourceTracks": tracks.enumerated().map { i, t -> [String: Any] in
             ["type": t, "editRate": 30, "range": [0, 1000],
              "trackRect": trackRects?[i] ?? (t == 2 ? [0, 0, 0, 0] : [0, 0, w, h])]
         }]
    }

    static func track(_ index: Int, _ medias: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = ["trackIndex": index, "medias": medias, "parameters": [String: Any]()]
        for (k, v) in extra { t[k] = v }
        return t
    }

    static func clip(_ type: String, id: Int, src: Int? = nil, trackNumber: Int = 0, start: Int64, duration: Int64,
                     mediaStart: Any = 0, scalar: Any = 1, parameters: [String: Any] = [:],
                     effects: [[String: Any]] = [], attributes: [String: Any] = [:],
                     extra: [String: Any] = [:]) -> [String: Any] {
        var c: [String: Any] = [
            "id": id, "_type": type, "start": start, "duration": duration, "mediaStart": mediaStart,
            "mediaDuration": duration, "scalar": scalar, "parameters": parameters, "effects": effects,
            "attributes": attributes, "metadata": [String: Any](), "animationTracks": [String: Any](),
        ]
        if let src { c["src"] = src; c["trackNumber"] = trackNumber }
        for (k, v) in extra { c[k] = v }
        return c
    }

    static func keyframed(_ base: Double, _ kfs: [(time: Int64, end: Int64, value: Double)],
                          interp: String = "linr") -> [String: Any] {
        ["type": "double", "defaultValue": base, "interp": interp,
         "keyframes": kfs.map { ["time": $0.time, "endTime": $0.end, "duration": $0.end - $0.time,
                                 "value": $0.value, "interp": interp] }]
    }

    static func scene(_ project: Project) -> SceneModel {
        SceneModel(project: project) { URL(fileURLWithPath: "/m").appendingPathComponent($0.src) }
    }
}

func fixtureURL(_ name: String) throws -> URL {
    guard let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return u
}

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

func approx(_ a: CGPoint, _ b: CGPoint, _ eps: Double = 1e-6) -> Bool {
    approx(a.x, b.x, eps) && approx(a.y, b.y, eps)
}

let demoBundleURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/demo project.cmproj")
let vlogBundleURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Moheshkali Dwip Vlog.cmproj")
