import CoreGraphics
import CoreMedia
import Foundation

/// The cursor/click/keystroke log of one recording (`cursor.json`).
///
/// Our own format, specified in `docs/specs/cursor-log.md`. Coordinates are captured-video
/// pixels with the origin at the top-left; times are seconds of recording time (0 = start,
/// pauses removed, same clock as the video and audio files). Plain `Codable` is fine here: this
/// is not a Camtasia project file.
public struct CursorLog: Codable, Sendable, Equatable {
    /// Value of `format`.
    public static let formatName = "wizrec-cursor-log"
    /// Version written by this build. Readers accept any version with the same major number.
    public static let currentVersion = 1

    public var format: String = CursorLog.formatName
    public var version: Int = CursorLog.currentVersion
    /// Always `"capturedPixels"` in version 1.
    public var coordinateSpace: String = "capturedPixels"
    /// Always `"topLeft"` in version 1.
    public var origin: String = "topLeft"
    /// Always `"seconds"` in version 1.
    public var timeUnit: String = "seconds"
    /// Captured video size, pixels.
    public var videoWidth: Int
    public var videoHeight: Int
    /// Captured pixels per screen point (2 on a Retina display at native scale).
    public var pixelsPerPoint: Double
    /// Position sampling rate, samples per second (= capture frame rate).
    public var sampleRate: Int
    /// Recording duration, seconds.
    public var duration: Double
    /// True when keystroke logging was enabled for this recording.
    public var keystrokesLogged: Bool
    /// Every distinct cursor image seen, in order of first appearance.
    public var cursors: [CursorImage]
    /// All events, sorted by `t`.
    public var events: [CursorEvent]

    public init(videoWidth: Int, videoHeight: Int, pixelsPerPoint: Double, sampleRate: Int, duration: Double,
                keystrokesLogged: Bool, cursors: [CursorImage] = [], events: [CursorEvent] = []) {
        self.videoWidth = videoWidth; self.videoHeight = videoHeight
        self.pixelsPerPoint = pixelsPerPoint; self.sampleRate = sampleRate; self.duration = duration
        self.keystrokesLogged = keystrokesLogged; self.cursors = cursors; self.events = events
    }

    /// Encodes as compact, stable JSON (sorted keys).
    public func jsonData(pretty: Bool = false) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// Decodes `cursor.json`; unknown keys and unknown event types are ignored.
    public static func decode(_ data: Data) throws -> CursorLog {
        try JSONDecoder().decode(CursorLog.self, from: data)
    }
}

/// One distinct cursor image, stored once as a PNG next to `cursor.json`.
public struct CursorImage: Codable, Sendable, Equatable {
    /// Referenced by `CursorEvent.Kind.cursor(id:)`.
    public var id: Int
    /// PNG path relative to the folder holding `cursor.json`, e.g. `cursors/cursor-0.png`.
    public var file: String
    /// Image size in captured pixels (already scaled by `pixelsPerPoint`).
    public var width: Int
    public var height: Int
    /// Hot spot in captured pixels from the image's top-left: the pixel placed at the logged position.
    public var hotspotX: Double
    public var hotspotY: Double

    public init(id: Int, file: String, width: Int, height: Int, hotspotX: Double, hotspotY: Double) {
        self.id = id; self.file = file; self.width = width; self.height = height
        self.hotspotX = hotspotX; self.hotspotY = hotspotY
    }
}

/// Mouse button of a click event.
public enum MouseButton: Sendable, Equatable, Codable {
    case left, right, middle
    /// Any other button, by CoreGraphics button number (3, 4, …).
    case other(Int)

    public var name: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .middle: "middle"
        case let .other(n): "button\(n)"
        }
    }

    public init(name: String) {
        switch name {
        case "left": self = .left
        case "right": self = .right
        case "middle": self = .middle
        default: self = .other(Int(name.dropFirst("button".count)) ?? 3)
        }
    }

    /// From a CoreGraphics button number (0 left, 1 right, 2 middle).
    public init(cgButton n: Int) {
        switch n {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        default: self = .other(n)
        }
    }

    public init(from decoder: Decoder) throws { self.init(name: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(name)
    }
}

/// One timestamped entry of the log. Positions are captured pixels, top-left origin; they may
/// lie outside the video when the cursor leaves the captured area.
public struct CursorEvent: Codable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Position sample (written only when the position changed since the last sample).
        case move(x: Double, y: Double)
        /// Button pressed; `clickCount` 2 = double click.
        case down(button: MouseButton, x: Double, y: Double, clickCount: Int)
        case up(button: MouseButton, x: Double, y: Double)
        /// Scroll at a position; deltas in points, CoreGraphics sign (dy > 0 = wheel away from user).
        case scroll(dx: Double, dy: Double, x: Double, y: Double)
        /// The cursor image changed to `CursorLog.cursors[id]`.
        case cursor(id: Int)
        /// Key pressed (only when keystroke logging is on). `keyCode` = macOS virtual key code,
        /// `characters` = produced text (nil when none), `modifiers` ⊆ shift/control/option/command/function/capsLock.
        case key(keyCode: Int, characters: String?, modifiers: [String], isRepeat: Bool)
        /// An event type this build does not know (kept when decoding, written back as its type only).
        case unknown(String)
    }

    /// Recording time, seconds.
    public var t: Double
    public var kind: Kind

    public init(t: Double, kind: Kind) { self.t = t; self.kind = kind }

    private enum Keys: String, CodingKey {
        case t, type, x, y, button, clickCount, dx, dy, id, keyCode, characters, modifiers, isRepeat = "repeat"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        t = try c.decode(Double.self, forKey: .t)
        let type = try c.decode(String.self, forKey: .type)
        func d(_ k: Keys) throws -> Double { try c.decode(Double.self, forKey: k) }
        switch type {
        case "move": kind = .move(x: try d(.x), y: try d(.y))
        case "down":
            kind = .down(button: try c.decode(MouseButton.self, forKey: .button), x: try d(.x), y: try d(.y),
                         clickCount: try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1)
        case "up": kind = .up(button: try c.decode(MouseButton.self, forKey: .button), x: try d(.x), y: try d(.y))
        case "scroll": kind = .scroll(dx: try d(.dx), dy: try d(.dy), x: try d(.x), y: try d(.y))
        case "cursor": kind = .cursor(id: try c.decode(Int.self, forKey: .id))
        case "key":
            kind = .key(keyCode: try c.decode(Int.self, forKey: .keyCode),
                        characters: try c.decodeIfPresent(String.self, forKey: .characters),
                        modifiers: try c.decodeIfPresent([String].self, forKey: .modifiers) ?? [],
                        isRepeat: try c.decodeIfPresent(Bool.self, forKey: .isRepeat) ?? false)
        default: kind = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(t, forKey: .t)
        switch kind {
        case let .move(x, y):
            try c.encode("move", forKey: .type); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case let .down(b, x, y, n):
            try c.encode("down", forKey: .type); try c.encode(b, forKey: .button)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(n, forKey: .clickCount)
        case let .up(b, x, y):
            try c.encode("up", forKey: .type); try c.encode(b, forKey: .button)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case let .scroll(dx, dy, x, y):
            try c.encode("scroll", forKey: .type); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case let .cursor(id):
            try c.encode("cursor", forKey: .type); try c.encode(id, forKey: .id)
        case let .key(code, chars, mods, rep):
            try c.encode("key", forKey: .type); try c.encode(code, forKey: .keyCode)
            try c.encodeIfPresent(chars, forKey: .characters); try c.encode(mods, forKey: .modifiers)
            if rep { try c.encode(true, forKey: .isRepeat) }
        case let .unknown(type):
            try c.encode(type, forKey: .type)
        }
    }
}

/// Where the captured area is on screen and how big the video is; maps global screen points
/// (CoreGraphics global space, top-left origin) to captured pixels.
public struct CaptureGeometry: Sendable, Equatable {
    /// Captured area in global display points, top-left origin.
    public var sourceRect: CGRect
    /// Output video size, pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.sourceRect = sourceRect; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    /// Horizontal pixels per point.
    public var pixelsPerPoint: Double {
        sourceRect.width > 0 ? Double(pixelWidth) / Double(sourceRect.width) : 1
    }

    /// Captured-pixel position of global point `p`, rounded to 1/100 px.
    public func pixels(_ p: CGPoint) -> CGPoint {
        let sx = sourceRect.width > 0 ? Double(pixelWidth) / Double(sourceRect.width) : 1
        let sy = sourceRect.height > 0 ? Double(pixelHeight) / Double(sourceRect.height) : 1
        return CGPoint(x: round2((Double(p.x) - Double(sourceRect.minX)) * sx),
                       y: round2((Double(p.y) - Double(sourceRect.minY)) * sy))
    }
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
/// Seconds rounded to 0.1 ms, so JSON stays short.
func roundTime(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

/// Builds the event list from host-time inputs. Pure: no AppKit, testable.
///
/// Events before the start, during a pause or after the stop are dropped; consecutive
/// identical positions and repeated cursor ids collapse. At each start/resume the current
/// position and cursor image are written again, so a segment never depends on dropped events.
struct CursorLogBuilder {
    private(set) var events: [CursorEvent] = []
    private var lastPosition: CGPoint?
    private var lastCursorID: Int?
    private var currentPosition: CGPoint?
    private var currentCursorID: Int?
    var geometry: CaptureGeometry

    init(geometry: CaptureGeometry) { self.geometry = geometry }

    /// Position sample at global point `p`.
    mutating func move(to p: CGPoint, hostTime: CMTime, timeline: TimelineStitcher) {
        let px = geometry.pixels(p)
        currentPosition = px
        guard let t = timeline.map(hostTime), px != lastPosition else { return }
        lastPosition = px
        events.append(CursorEvent(t: roundTime(t.seconds), kind: .move(x: px.x, y: px.y)))
    }

    /// Current cursor image is `id`.
    mutating func cursor(_ id: Int, hostTime: CMTime, timeline: TimelineStitcher) {
        currentCursorID = id
        guard let t = timeline.map(hostTime), id != lastCursorID else { return }
        lastCursorID = id
        events.append(CursorEvent(t: roundTime(t.seconds), kind: .cursor(id: id)))
    }

    /// Any other event; `make` receives the captured-pixel position of `p`.
    mutating func event(at p: CGPoint, hostTime: CMTime, timeline: TimelineStitcher, _ make: (CGPoint) -> CursorEvent.Kind) {
        let px = geometry.pixels(p)
        guard let t = timeline.map(hostTime) else { return }
        events.append(CursorEvent(t: roundTime(t.seconds), kind: make(px)))
    }

    /// A keystroke (no position).
    mutating func key(_ kind: CursorEvent.Kind, hostTime: CMTime, timeline: TimelineStitcher) {
        guard let t = timeline.map(hostTime) else { return }
        events.append(CursorEvent(t: roundTime(t.seconds), kind: kind))
    }

    /// Call right after the timeline starts or resumes: re-states position and cursor image.
    mutating func segmentStarted(timeline: TimelineStitcher) {
        guard let start = timeline.startTime, !timeline.isPaused, !timeline.isStopped else { return }
        let t = roundTime(timeline.recordingTime(at: timeline.pauses.last?.resumedAt ?? start).seconds)
        if let p = currentPosition {
            events.append(CursorEvent(t: t, kind: .move(x: p.x, y: p.y))); lastPosition = p
        }
        if let id = currentCursorID {
            events.append(CursorEvent(t: t, kind: .cursor(id: id))); lastCursorID = id
        }
    }

    /// Events sorted by time (stable, so same-time events keep arrival order).
    var sortedEvents: [CursorEvent] {
        events.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
    }
}
