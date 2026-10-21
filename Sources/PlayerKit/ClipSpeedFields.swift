import Foundation
import TSCProjKit

/// Text of the inspector's Clip Speed fields (APP14-3, edit-semantics.md ED2b).
///
/// - Duration is shown as `M:SS;FF` (minutes, seconds, frames at the project rate; `H:MM:SS;FF`
///   from one hour), which is exact because a retimed duration is always a whole number of
///   frames. Typed text may be `S;FF`, `M:SS;FF`, `H:MM:SS;FF`, or seconds with an optional
///   fraction (`7.5`, `1:07.5`, `0:01:07.5`).
/// - Speed is shown as the effective speed (`1 / scalar`) with two decimals (1.91 after a typed
///   1.9 on 300 frames).
public enum ClipSpeedFields {
    /// `ticks` as `M:SS;FF` (or `H:MM:SS;FF`): whole frames at `grid.fps`, floored.
    public static func durationText(_ ticks: Int64, grid: FrameGrid) -> String {
        let frames = grid.index(of: ticks)
        // `S;FF`: the whole seconds before the frame's start, then the frames that start in that
        // second (at 29.97 fps a second can hold 30 frame starts).
        let secondsTotal = grid.ticks(ofFrame: frames) / max(1, grid.timebase.editRate)
        let ff = max(0, frames - firstFrame(inSecond: secondsTotal, grid: grid))
        let h = secondsTotal / 3600, m = (secondsTotal / 60) % 60, s = secondsTotal % 60
        if h > 0 { return String(format: "%lld:%02lld:%02lld;%02lld", h, m, s, ff) }
        return String(format: "%lld:%02lld;%02lld", m, s, ff)
    }

    /// Ticks for typed duration text, or nil when it is not a duration. `S;FF` forms give the
    /// first tick of that frame; seconds forms give the nearest tick, moved up to a frame start
    /// less than half a millisecond above it (so a shown `7.667` keeps frame 230 at 30 fps).
    public static func durationTicks(_ text: String, grid: FrameGrid) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        let halves = t.split(separator: ";", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        let clock = halves[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(clock.count) else { return nil }
        var seconds = 0.0
        for (k, part) in clock.enumerated() {
            let isLast = k == clock.count - 1
            guard !part.isEmpty || (clock.count == 1 && halves.count == 2) else { return nil }
            let v: Double
            if part.isEmpty { v = 0 } else if isLast { guard let d = Double(part) else { return nil }; v = d }
            else { guard let n = Int(part) else { return nil }; v = Double(n) }
            guard v >= 0, v.isFinite else { return nil }
            seconds = seconds * 60 + v
        }
        guard seconds < 360_000 else { return nil }   // 100 h
        if halves.count == 2 {
            guard seconds == seconds.rounded(), let ff = Int64(halves[1]), ff >= 0 else { return nil }
            return grid.ticks(ofFrame: firstFrame(inSecond: Int64(seconds), grid: grid) + ff)
        }
        let ticks = grid.timebase.ticks(seconds: seconds)
        let halfMs = grid.timebase.editRate / 2000
        let up = grid.index(of: ticks + halfMs)
        return up > grid.index(of: ticks) ? grid.ticks(ofFrame: up) : ticks
    }

    /// The first frame that starts at or after whole second `s`.
    private static func firstFrame(inSecond s: Int64, grid: FrameGrid) -> Int64 {
        let t = grid.timebase.editRate * s
        let i = grid.index(of: t)
        return grid.ticks(ofFrame: i) < t ? i + 1 : i
    }

    /// The effective speed (1 = normal) as the Speed field shows it: two decimals.
    public static func speedText(_ speed: Double) -> String {
        guard speed.isFinite, speed > 0 else { return "1.00" }
        return String(format: "%.2f", speed)
    }

    /// The typed speed as an exact rational with two-decimal precision (`1.9` → 190/100), or nil
    /// when the text is not a positive number. A trailing `x` or `×` is allowed.
    public static func speed(_ text: String) -> Rational? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").lowercased()
        if t.hasSuffix("x") || t.hasSuffix("×") { t.removeLast() }
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), v.isFinite, v > 0 else { return nil }
        let hundredths = Int64((v * 100).rounded())
        guard hundredths > 0, hundredths <= 100 * 100 else { return nil }
        return Rational(hundredths, 100)
    }
}
