import CoreGraphics
import Foundation
import TSCProjKit

/// Fixed sizes of the timeline chrome, points.
public struct TimelineMetrics: Sendable, Equatable {
    /// Height of the time ruler at the top.
    public var rulerHeight: CGFloat = 28
    /// Width of the track-header column on the left.
    public var headerWidth: CGFloat = 176
    /// Row height when the project stores none.
    public var defaultTrackHeight: CGFloat = 56
    public var minTrackHeight: CGFloat = 36
    public var maxTrackHeight: CGFloat = 160
    /// Blank space before tick 0, points.
    public var leadingInset: CGFloat = 12
    /// Gap between rows, points.
    public var rowGap: CGFloat = 1
    /// Width of the trim grab zone inside each clip edge, points.
    public var edgeGrab: CGFloat = 6
    /// Size of the header flag buttons, points.
    public var buttonSize: CGFloat = 20
    /// Height of the breadcrumb band shown above the ruler while a group is open.
    public var breadcrumbHeight: CGFloat = 26

    public init() {}
}

/// Zoom limits, points per second.
public enum TimelineZoom {
    public static let minPointsPerSecond: Double = 0.5
    public static let maxPointsPerSecond: Double = 4000
    /// Factor applied by one zoom-in / zoom-out step.
    public static let step: Double = 1.5

    public static func clamp(_ pps: Double) -> Double {
        guard pps.isFinite, pps > 0 else { return 100 }
        return min(max(pps, minPointsPerSecond), maxPointsPerSecond)
    }

    /// Zoom that fits `duration` ticks into `width` points (with a 5 % margin).
    public static func fit(duration: Int64, editRate: Int64, width: CGFloat) -> Double {
        let secs = Double(max(duration, 1)) / Double(max(editRate, 1))
        return clamp(Double(max(width, 50)) * 0.95 / secs)
    }
}

/// One track row. `y` is in content coordinates (0 = top of the first row, below the ruler).
public struct TimelineRow: Sendable, Equatable {
    public var trackIndex: Int
    public var y: CGFloat
    public var height: CGFloat
}

/// Header buttons, left to right.
public enum TrackHeaderControl: String, Sendable, CaseIterable {
    case magnetic, locked, videoHidden, audioMuted
}

/// What lies under a point of the timeline view.
public enum TimelineHit: Sendable, Equatable {
    public enum ClipZone: Sendable, Equatable { case body, leadingEdge, trailingEdge }
    /// Breadcrumb band (open group); `level` = number of groups that stay open when clicked
    /// (0 = back to the top-level timeline).
    case breadcrumb(level: Int)
    /// Top-left corner (add-track button).
    case corner
    /// Time ruler at `ticks`.
    case ruler(ticks: Int64)
    /// Track header; `control` when on a flag button.
    case header(track: Int, control: TrackHeaderControl?)
    case clip(id: Int64, track: Int, zone: ClipZone)
    /// Empty part of a track row at `ticks`.
    case track(Int, ticks: Int64)
    /// Below the last row.
    case empty(ticks: Int64)
}

/// Pure geometry of the timeline: tick ↔ x, rows (highest track at the top, track 0 at
/// the bottom, as in Camtasia's track list), clip rectangles and hit testing.
/// View coordinates are flipped (y down), points.
public struct TimelineLayout: Sendable, Equatable {
    public var metrics: TimelineMetrics
    public var editRate: Int64
    /// Zoom, points per second.
    public var pointsPerSecond: Double
    /// Horizontal scroll, points of content hidden left of the clip area.
    public var scrollX: CGFloat
    /// Vertical scroll, points of rows hidden above.
    public var scrollY: CGFloat
    /// View size, points.
    public var size: CGSize
    /// Rows top → bottom.
    public private(set) var rows: [TimelineRow]
    /// Height of the breadcrumb band (0 at the top level).
    public var banner: CGFloat
    /// Bottom of the ruler = top of the first row, view y.
    public var rulerBottom: CGFloat { banner + metrics.rulerHeight }

    public init(snapshot: TimelineSnapshot, pointsPerSecond: Double, scrollX: CGFloat = 0, scrollY: CGFloat = 0,
                size: CGSize, metrics: TimelineMetrics = TimelineMetrics()) {
        self.metrics = metrics
        editRate = max(snapshot.editRate, 1)
        self.pointsPerSecond = TimelineZoom.clamp(pointsPerSecond)
        self.scrollX = scrollX; self.scrollY = scrollY; self.size = size
        banner = snapshot.groupPath.isEmpty ? 0 : metrics.breadcrumbHeight
        var rows: [TimelineRow] = []
        var y: CGFloat = 0
        for t in snapshot.tracks.reversed() {
            let h = min(max(t.storedHeight.map { CGFloat($0) } ?? metrics.defaultTrackHeight,
                            metrics.minTrackHeight), metrics.maxTrackHeight)
            rows.append(TimelineRow(trackIndex: t.index, y: y, height: h))
            y += h + metrics.rowGap
        }
        self.rows = rows
    }

    // MARK: Areas

    /// Clip area (right of headers, below the ruler), view coordinates.
    public var clipArea: CGRect {
        CGRect(x: metrics.headerWidth, y: rulerBottom,
               width: max(0, size.width - metrics.headerWidth), height: max(0, size.height - rulerBottom))
    }

    public var rulerRect: CGRect {
        CGRect(x: metrics.headerWidth, y: banner, width: max(0, size.width - metrics.headerWidth), height: metrics.rulerHeight)
    }

    public var cornerRect: CGRect { CGRect(x: 0, y: banner, width: metrics.headerWidth, height: metrics.rulerHeight) }

    /// Breadcrumb band across the top (empty at the top level).
    public var bannerRect: CGRect { CGRect(x: 0, y: 0, width: size.width, height: banner) }

    /// Total height of all rows, points.
    public var contentHeight: CGFloat { rows.last.map { $0.y + $0.height } ?? 0 }

    /// Largest useful `scrollY`.
    public var maxScrollY: CGFloat { max(0, contentHeight - clipArea.height + 24) }

    /// Width of `duration` ticks of content plus trailing room, points.
    public func contentWidth(duration: Int64) -> CGFloat {
        width(ofTicks: duration) + metrics.leadingInset + clipArea.width * 0.5
    }

    public func maxScrollX(duration: Int64) -> CGFloat { max(0, contentWidth(duration: duration) - clipArea.width) }

    // MARK: Time ↔ x

    /// View x of track tick `t`.
    public func x(ofTicks t: Int64) -> CGFloat {
        metrics.headerWidth + metrics.leadingInset - scrollX + width(ofTicks: t)
    }

    /// Width of `ticks`, points.
    public func width(ofTicks ticks: Int64) -> CGFloat {
        CGFloat(Double(ticks) / Double(editRate) * pointsPerSecond)
    }

    /// Tick at view x (rounded to the nearest tick, may be negative).
    public func ticks(atX x: CGFloat) -> Int64 {
        let secs = Double(x - metrics.headerWidth - metrics.leadingInset + scrollX) / pointsPerSecond
        return Int64((secs * Double(editRate)).rounded())
    }

    /// Ticks spanned by `points`.
    public func ticks(forWidth points: CGFloat) -> Int64 {
        Int64((Double(points) / pointsPerSecond * Double(editRate)).rounded())
    }

    /// `scrollX` that keeps tick `t` at view x `anchorX` after zooming to `pps`.
    public func scrollX(keeping t: Int64, atX anchorX: CGFloat, pointsPerSecond pps: Double) -> CGFloat {
        let content = CGFloat(Double(t) / Double(editRate) * TimelineZoom.clamp(pps))
        return max(0, metrics.headerWidth + metrics.leadingInset + content - anchorX)
    }

    // MARK: Rows and clips

    public func row(forTrack index: Int) -> TimelineRow? { rows.first { $0.trackIndex == index } }

    /// Row rectangle across the clip area, view coordinates.
    public func rowRect(_ row: TimelineRow) -> CGRect {
        CGRect(x: metrics.headerWidth, y: rulerBottom + row.y - scrollY,
               width: max(0, size.width - metrics.headerWidth), height: row.height)
    }

    public func headerRect(_ row: TimelineRow) -> CGRect {
        CGRect(x: 0, y: rulerBottom + row.y - scrollY, width: metrics.headerWidth, height: row.height)
    }

    /// Clip rectangle on `track` from `start` for `duration` ticks (inset 2 pt vertically).
    public func clipRect(track: Int, start: Int64, duration: Int64) -> CGRect? {
        guard let r = row(forTrack: track) else { return nil }
        let rr = rowRect(r)
        let x0 = x(ofTicks: start), x1 = x(ofTicks: start + duration)
        return CGRect(x: x0, y: rr.minY + 2, width: max(1, x1 - x0), height: max(1, rr.height - 4))
    }

    /// Row whose band contains view y, if any.
    public func row(atY y: CGFloat) -> TimelineRow? {
        let cy = y - rulerBottom + scrollY
        return rows.first { cy >= $0.y && cy < $0.y + $0.height + metrics.rowGap }
    }

    /// Header button rectangle, view coordinates.
    public func buttonRect(_ control: TrackHeaderControl, in row: TimelineRow) -> CGRect {
        let h = headerRect(row)
        let order = TrackHeaderControl.allCases.firstIndex(of: control) ?? 0
        let count = CGFloat(TrackHeaderControl.allCases.count)
        let s = metrics.buttonSize
        let x0 = h.maxX - 8 - count * (s + 2) + CGFloat(order) * (s + 2)
        let y0 = h.minY + min(8, max(2, (h.height - s) / 2))
        return CGRect(x: x0, y: y0, width: s, height: s)
    }

    /// Track (by index) whose row contains view y; clamped to the first/last row.
    public func nearestTrack(atY y: CGFloat) -> Int? {
        if let r = row(atY: y) { return r.trackIndex }
        guard let first = rows.first, let last = rows.last else { return nil }
        return y < rowRect(first).minY ? first.trackIndex : last.trackIndex
    }

    /// Hit test at view point `p` against `snapshot`.
    public func hit(_ p: CGPoint, in snapshot: TimelineSnapshot) -> TimelineHit {
        if p.y < banner { return .breadcrumb(level: 0) }
        if p.y < rulerBottom {
            return p.x < metrics.headerWidth ? .corner : .ruler(ticks: ticks(atX: p.x))
        }
        guard let row = row(atY: p.y) else {
            return p.x < metrics.headerWidth ? .empty(ticks: 0) : .empty(ticks: ticks(atX: p.x))
        }
        if p.x < metrics.headerWidth {
            for c in TrackHeaderControl.allCases where buttonRect(c, in: row).insetBy(dx: -2, dy: -2).contains(p) {
                return .header(track: row.trackIndex, control: c)
            }
            return .header(track: row.trackIndex, control: nil)
        }
        let t = ticks(atX: p.x)
        if let track = snapshot.track(row.trackIndex) {
            for c in track.clips {
                guard let r = clipRect(track: track.index, start: c.start, duration: c.duration),
                      r.insetBy(dx: -1, dy: 0).contains(p) else { continue }
                let grab = min(metrics.edgeGrab, r.width / 4)
                if p.x <= r.minX + grab { return .clip(id: c.id, track: track.index, zone: .leadingEdge) }
                if p.x >= r.maxX - grab { return .clip(id: c.id, track: track.index, zone: .trailingEdge) }
                return .clip(id: c.id, track: track.index, zone: .body)
            }
        }
        return .track(row.trackIndex, ticks: t)
    }

    /// Ids of clips whose rectangles intersect `rect` (view coordinates).
    public func clips(in rect: CGRect, snapshot: TimelineSnapshot) -> Set<Int64> {
        var ids = Set<Int64>()
        for t in snapshot.tracks {
            for c in t.clips {
                if let r = clipRect(track: t.index, start: c.start, duration: c.duration), r.intersects(rect) {
                    ids.insert(c.id)
                }
            }
        }
        return ids
    }

    /// Visible tick range of the clip area.
    public var visibleTicks: ClosedRange<Int64> {
        let a = ticks(atX: clipArea.minX), b = ticks(atX: clipArea.maxX)
        return min(a, b)...max(a, b)
    }
}

// MARK: - Ruler

/// Ruler tick spacing for a zoom level.
public struct RulerScale: Sendable, Equatable {
    /// Seconds between labelled ticks.
    public var major: Double
    /// Unlabelled ticks per major interval.
    public var minorCount: Int
    /// Labels include frames.
    public var showsFrames: Bool

    /// Smallest spacing that keeps labels at least `minLabelSpacing` points apart.
    public static func choose(pointsPerSecond pps: Double, fps: Double, minLabelSpacing: Double = 72) -> RulerScale {
        let f = fps > 0 ? fps : 30
        let frames: [(Double, Int)] = [(1, 1), (2, 2), (5, 5), (10, 5)].map { ($0.0 / f, $0.1) }
        let half: [(Double, Int)] = f >= 4 ? [(Double((f / 2).rounded(.down)) / f, 3)] : []
        let secs: [(Double, Int)] = [(1, 5), (2, 4), (5, 5), (10, 5), (15, 3), (30, 6), (60, 6), (120, 4),
                                     (300, 5), (600, 5), (900, 3), (1800, 6), (3600, 4)]
        for (m, n) in frames + half + secs where m * pps >= minLabelSpacing {
            return RulerScale(major: m, minorCount: n, showsFrames: m < 1)
        }
        return RulerScale(major: 3600, minorCount: 4, showsFrames: false)
    }
}

/// Timecode text. Frames use the project frame rate; `;` separates frames (editor style).
public enum TimelineTimecode {
    /// `H:MM:SS;FF`, e.g. `0:01:05;12`.
    public static func full(_ ticks: Int64, editRate: Int64, fps: Rational) -> String {
        let (h, m, s, f) = parts(ticks, editRate: editRate, fps: fps)
        return String(format: "%lld:%02lld:%02lld;%02lld", h, m, s, f)
    }

    /// Ruler label: `M:SS` or `H:MM:SS`, with `;FF` when `frames`.
    public static func label(_ ticks: Int64, editRate: Int64, fps: Rational, frames: Bool) -> String {
        let (h, m, s, f) = parts(ticks, editRate: editRate, fps: fps)
        let base = h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, s) : String(format: "%lld:%02lld", m, s)
        return frames ? base + String(format: ";%02lld", f) : base
    }

    static func parts(_ ticks: Int64, editRate: Int64, fps: Rational) -> (Int64, Int64, Int64, Int64) {
        let t = max(0, ticks)
        let rate = max(editRate, 1)
        let fpsNum = max(fps.num, 1), fpsDen = max(fps.den, 1)
        let totalSeconds = t / rate
        // Frames since the start of the current second: floor(remainder × fps).
        let rem = t - totalSeconds * rate
        let (prod, overflow) = rem.multipliedReportingOverflow(by: fpsNum)
        let f = overflow ? Int64(Double(rem) * Double(fpsNum) / (Double(rate) * Double(fpsDen)))
                         : prod / (rate * fpsDen)
        let nominal = max(1, Int64((Double(fpsNum) / Double(fpsDen)).rounded(.up)))
        let ff = min(max(f, 0), nominal - 1)
        return (totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, ff)
    }
}
