import CoreGraphics
import CoreMedia
import Foundation
import TSCProjKit

/// Every geometry and time-mapping convention RenderEngine assumes about the
/// project format, in one place so it is easy to correct when
/// `docs/specs/transform.md` and `docs/specs/time-mapping.md` land.
///
/// Status of each rule: [obs] observed in project files, [inf] inferred.
enum Conventions {
    // MARK: Time

    /// Media (inner) time for parent time `t`: `mediaStart + (t − start) / scalar`.
    /// `scalar = 1/speed`, `mediaDuration × scalar = duration` [obs, vlog].
    static func mediaTime(parent t: Rational, start: Int64, mediaStart: Rational, scalar: Rational) -> Rational {
        Q.add(mediaStart, Q.div(Q.sub(t, Rational(start)), scalar))
    }

    /// Parent time for media time `m` (inverse of `mediaTime`).
    static func parentTime(media m: Rational, start: Int64, mediaStart: Rational, scalar: Rational) -> Rational {
        Q.add(Rational(start), Q.mul(Q.sub(m, mediaStart), scalar))
    }

    /// Time at which a clip's keyframes are evaluated: parent time minus the
    /// clip's `start`, in parent ticks [inf: keyframes are relative to the clip start].
    static func keyframeTime(parent t: Rational, start: Int64) -> Double {
        Q.sub(t, Rational(start)).double
    }

    /// Stream time for media ticks: stream time 0 = media tick 0 [inf].
    static func streamTime(ticks m: Rational, editRate: Int64) -> CMTime {
        let ticks = Q.round(m)
        if editRate > 0, editRate <= Int64(Int32.max) {
            return CMTime(value: ticks, timescale: Int32(editRate))
        }
        return CMTime(seconds: m.double / Double(max(editRate, 1)), preferredTimescale: 1_000_000)
    }

    // MARK: Geometry

    /// translate(`translation0`, `translation1`) · rotate(`rotation2`) · scale(`scale0`, `scale1`),
    /// in parent px, origin at the parent centre, +y up [inf: translation1 < 0 places the demo
    /// camera bottom-right]. Rotation in radians, counter-clockwise in +y-up space [inf].
    static func transform(_ p: SParams, at t: Double) -> CGAffineTransform {
        let tx = p.value("translation0", at: t, default: 0)
        let ty = p.value("translation1", at: t, default: 0)
        let rot = p.value("rotation2", at: t, default: 0)
        let sx = p.value("scale0", at: t, default: 1)
        let sy = p.value("scale1", at: t, default: 1)
        // Applied to a point: scale first, then rotate, then translate.
        return CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(rotationAngle: rot))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// `geometryCrop0..3` = left, top, right, bottom fractions [inf], clamped to 0…1
    /// (Camtasia writes −1e−13-style noise).
    static func geometryCrop(_ p: SParams, at t: Double) -> Insets {
        insets(p, prefix: "geometryCrop", at: t)
    }

    /// `sourceCrop0..3` = left, top, right, bottom fractions of the source [inf].
    static func sourceCrop(_ p: SParams, at t: Double) -> Insets {
        insets(p, prefix: "sourceCrop", at: t)
    }

    static func opacity(_ p: SParams, at t: Double) -> Double {
        clamp01(p.value("opacity", at: t, default: 1))
    }

    /// Natural size of a media leaf: the stream's `trackRect` w×h when non-empty
    /// (the demo camera stream is 1920×1080 inside a 3024×1964 `.trec`) [obs],
    /// else the source `rect` w×h, else `fallback`.
    static func leafSize(source: SourceMedia?, trackNumber: Int, fallback: CGSize) -> CGSize {
        if let source {
            let tracks = source.tracks
            if trackNumber >= 0, trackNumber < tracks.count {
                let r = tracks[trackNumber].object["trackRect"]?.array?.items.compactMap(\.double) ?? []
                if r.count == 4, r[2] > 0, r[3] > 0 { return CGSize(width: r[2], height: r[3]) }
            }
            let r = source.rect
            if r.count == 4, r[2] > 0, r[3] > 0 { return CGSize(width: r[2], height: r[3]) }
        }
        return fallback
    }

    /// Group size: `attributes.widthAttr`/`heightAttr` [obs], else `fallback`.
    static func groupSize(attributes: JSONObject?, fallback: CGSize) -> CGSize {
        let w = attributes?["widthAttr"]?.double ?? 0, h = attributes?["heightAttr"]?.double ?? 0
        return w > 0 && h > 0 ? CGSize(width: w, height: h) : fallback
    }

    /// Canvas background: `timeline.backgroundColor` RGBA 0–255 [obs].
    static func background(_ c: [Int64]) -> RGBA {
        func ch(_ i: Int, _ d: Double) -> Double { i < c.count ? clamp01(Double(c[i]) / 255) : d }
        return RGBA(ch(0, 0), ch(1, 0), ch(2, 0), ch(3, 1))
    }

    // MARK: Helpers

    static func clamp01(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    private static func insets(_ p: SParams, prefix: String, at t: Double) -> Insets {
        Insets(left: clamp01(p.value("\(prefix)0", at: t, default: 0)),
               top: clamp01(p.value("\(prefix)1", at: t, default: 0)),
               right: clamp01(p.value("\(prefix)2", at: t, default: 0)),
               bottom: clamp01(p.value("\(prefix)3", at: t, default: 0)))
    }
}
