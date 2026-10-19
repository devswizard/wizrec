import CoreGraphics
import Foundation
import os

/// Read-only view of a WizRec `cursor.json` (`docs/specs/cursor-log.md`, v1), indexed for
/// sampling at any recording time. Mirrors only what rendering needs; the writer's model is
/// `Recorder.CursorLog`. Immutable after load.
final class CursorTrack: Sendable {
    struct Image: Sendable, Equatable {
        var url: URL
        var size: CGSize
        var hotspot: CGPoint
    }

    /// Captured video size, px.
    let videoSize: CGSize
    let images: [Int: Image]
    /// `move` (and `down`/`up`, which also carry positions) samples, sorted by time: seconds, px.
    let positions: [(t: Double, x: Double, y: Double)]
    /// `cursor` events, sorted: seconds, image id.
    let shapes: [(t: Double, id: Int)]

    init(videoSize: CGSize, images: [Int: Image], positions: [(t: Double, x: Double, y: Double)],
         shapes: [(t: Double, id: Int)]) {
        self.videoSize = videoSize; self.images = images; self.positions = positions; self.shapes = shapes
    }

    /// Position (video px, top-left origin) and image at recording time `t` seconds:
    /// the last sample at or before `t` holds [cursor-log.md §3]. Nil before the first sample.
    func sample(at t: Double) -> (position: CGPoint, image: Image)? {
        guard let p = Self.last(positions.count, { positions[$0].t <= t }),
              let s = Self.last(shapes.count, { shapes[$0].t <= t }),
              let img = images[shapes[s].id] else { return nil }
        return (CGPoint(x: positions[p].x, y: positions[p].y), img)
    }

    /// Index of the last element satisfying a monotone `pred` (true…true false…false).
    private static func last(_ n: Int, _ pred: (Int) -> Bool) -> Int? {
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(mid) { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    // MARK: Loading

    private struct File: Decodable {
        struct Cursor: Decodable { var id: Int; var file: String; var width: Double; var height: Double
            var hotspotX: Double; var hotspotY: Double }
        struct Event: Decodable { var t: Double; var type: String; var x: Double?; var y: Double?; var id: Int? }
        var format: String
        var version: Int
        var videoWidth: Double
        var videoHeight: Double
        var cursors: [Cursor]
        var events: [Event]
    }

    /// Parses `cursor.json` at `url`; nil when it is not a WizRec cursor log.
    static func load(_ url: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.format == "wizrec-cursor-log", f.version >= 1, f.videoWidth > 0, f.videoHeight > 0 else { return nil }
        let dir = url.deletingLastPathComponent()
        var images: [Int: Image] = [:]
        for c in f.cursors {
            images[c.id] = Image(url: dir.appendingPathComponent(c.file), size: CGSize(width: c.width, height: c.height),
                                 hotspot: CGPoint(x: c.hotspotX, y: c.hotspotY))
        }
        var pos: [(t: Double, x: Double, y: Double)] = []
        var shapes: [(t: Double, id: Int)] = []
        for e in f.events where e.t.isFinite {
            switch e.type {
            case "move", "down", "up", "scroll":
                if let x = e.x, let y = e.y { pos.append((e.t, x, y)) }
            case "cursor":
                if let id = e.id { shapes.append((e.t, id)) }
            default: break
            }
        }
        // The file is sorted by t [def]; a stable sort guards hand-edited files.
        pos = pos.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        shapes = shapes.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        return CursorTrack(videoSize: CGSize(width: f.videoWidth, height: f.videoHeight), images: images,
                           positions: pos, shapes: shapes)
    }

    /// `cursor.json` next to a screen recording's video file [cursor-log.md §1], cached per file
    /// and modification date (SceneModel is rebuilt after every edit).
    static func sidecar(for video: URL) -> CursorTrack? {
        let url = video.deletingLastPathComponent().appendingPathComponent("cursor.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let stamp = (attrs[.modificationDate] as? Date) ?? .distantPast
        if let hit = cache.withLock({ $0[url] }), hit.stamp == stamp { return hit.track }
        let track = load(url)
        cache.withLock { $0[url] = (stamp, track) }
        return track
    }

    private static let cache = OSAllocatedUnfairLock<[URL: (stamp: Date, track: CursorTrack?)]>(initialState: [:])
}
