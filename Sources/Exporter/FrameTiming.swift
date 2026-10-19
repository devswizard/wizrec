import CoreGraphics
import CoreMedia
import Foundation
import TSCProjKit

/// Exact output-frame grid for an export: frame `n` of the output shows timeline time
/// `range.lowerBound + ceil(n · editRate · fps.den / fps.num)` ticks — the first tick of frame `n`,
/// the same rule as the player's `FrameGrid`, so export frame N is the preview frame N.
/// Its presentation time in the file is exactly `n · fps.den / fps.num` s.
struct FrameTiming: Sendable, Equatable {
    /// Ticks per second.
    let editRate: Int64
    /// Output frames per second (num/den > 0).
    let fps: Rational
    /// Exported timeline span, ticks.
    let range: Range<Int64>

    init(editRate: Int64, fps: Rational, range: Range<Int64>) {
        self.editRate = max(1, editRate)
        // Untrusted project data: never divide by a zero or negative rate.
        self.fps = fps.num > 0 && fps.den > 0 ? fps : Rational(30)
        self.range = range
    }

    /// Number of output frames: every frame whose first tick lies inside `range`.
    var frameCount: Int {
        let len = range.upperBound - range.lowerBound
        guard len > 0 else { return 0 }
        // Frame i starts inside iff ceil(i·E·d/n) < len  ⟺  i ≤ (len − 1)·n / (E·d).
        return Int(Self.mulDiv(len - 1, fps.num, editRate * fps.den)) + 1
    }

    /// Timeline ticks shown by output frame `n` (first tick of that frame).
    func ticks(frame n: Int) -> Int64 {
        range.lowerBound + Self.mulDiv(Int64(n) * fps.den, editRate, fps.num, roundUp: true)
    }

    /// Timescale for the output track: a multiple of `fps.num` ≥ 600 so frame times are exact.
    var timescale: CMTimeScale {
        let num = fps.num
        guard num > 0, num <= Int64(Int32.max) else { return 600 }
        if num >= 600 { return CMTimeScale(num) }
        let k = (600 + num - 1) / num
        return CMTimeScale(num * k)
    }

    /// Presentation time of output frame `n`.
    func presentationTime(frame n: Int) -> CMTime {
        CMTime(value: CMTimeValue(n) * fps.den, timescale: CMTimeScale(clamping: fps.num))
            .convertScale(timescale, method: .default)
    }

    /// Duration of the whole output (`frameCount` frames).
    var duration: CMTime { presentationTime(frame: frameCount) }

    /// Seconds per frame.
    var frameSeconds: Double { Double(fps.den) / Double(fps.num) }

    /// `a · b / c` with a 128-bit intermediate, rounded down (or up); `c > 0`, `a, b ≥ 0`.
    static func mulDiv(_ a: Int64, _ b: Int64, _ c: Int64, roundUp: Bool = false) -> Int64 {
        guard c > 0 else { return 0 }
        let p = a.multipliedFullWidth(by: b)
        let (q, r) = c.dividingFullWidth(p)
        return roundUp && r > 0 ? q + 1 : q
    }
}

extension CGSize {
    /// The largest size with `canvas`'s aspect ratio that fits in `box`, rounded to whole px
    /// (to even px when `even`), at least 2×2.
    static func aspectFit(_ canvas: CGSize, in box: CGSize, even: Bool) -> CGSize {
        let cw = max(canvas.width, 1), ch = max(canvas.height, 1)
        let s = min(box.width / cw, box.height / ch)
        func r(_ v: CGFloat, limit: CGFloat) -> CGFloat {
            guard v.isFinite, limit.isFinite else { return 2 }
            var x = even ? (v / 2).rounded() * 2 : v.rounded()
            if x > limit { x = even ? (limit / 2).rounded(.down) * 2 : limit.rounded(.down) }
            return max(2, x)
        }
        return CGSize(width: r(cw * s, limit: box.width), height: r(ch * s, limit: box.height))
    }
}
