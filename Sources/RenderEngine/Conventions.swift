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

    /// How a clip's keyframe times are measured.
    enum KeyframeBase: Sendable, Equatable {
        /// The clip's inner (media) time, `mediaStart + (t − start) / scalar`
        /// [obs for scalar 1: trimmed callouts; inf for speed ≠ 1, experiment X4].
        case media
        /// Images have no media time: `t − start + trimStartSum` [inf].
        case timelineOffset(trimStartSum: Double)
    }

    /// Keyframe evaluation time for parent time `t` (time-mapping.md §6).
    static func keyframeTime(parent t: Rational, start: Int64, mediaStart: Rational, scalar: Rational,
                             base: KeyframeBase) -> Double {
        switch base {
        case .media:
            mediaTime(parent: t, start: start, mediaStart: mediaStart, scalar: scalar).double
        case .timelineOffset(let trim):
            Q.sub(t, Rational(start)).double + trim
        }
    }

    /// Keyframe interpolation when neither the keyframe nor the parameter names one [?]
    /// (time-mapping.md §8). `bnce` and unknown codes are linear in M1.
    static let defaultInterp = "eioe"

    /// Stream time for media ticks: stream time 0 = media tick 0 [inf].
    static func streamTime(ticks m: Rational, editRate: Int64) -> CMTime {
        let ticks = Q.round(m)
        if editRate > 0, editRate <= Int64(Int32.max) {
            return CMTime(value: ticks, timescale: Int32(editRate))
        }
        return CMTime(seconds: m.double / Double(max(editRate, 1)), preferredTimescale: 1_000_000)
    }

    /// Shader time uniform, seconds: the clip's inner time / editRate [inf, time-mapping.md §4].
    static func shaderTime(media m: Rational, editRate: Int64) -> Double {
        m.double / Double(max(editRate, 1))
    }

    /// `.tscshadervid` `_TexCoord` has its origin at the layer's top-left, y down [obs: the demo's
    /// `ProjectThumbnail` top-left pixel is exactly `Color0`, which the user's shader puts at
    /// `_TexCoord` (0, 0)]. `true` = y down.
    static let shaderTexCoordY = true

    /// Length of a behaviour's in/out phase, seconds [?: behaviors.md §3, BH1]. Behaviours render as
    /// opacity fades over these phases until their motion is specified.
    static let behaviorPhaseSeconds = 0.5

    /// Effect `start`/`duration` window, on the keyframe axis [inf, time-mapping.md §7]:
    /// active on `[start, start + duration)`.
    static func effectWindowContains(start: Double, duration: Double, _ t: Double) -> Bool {
        t >= start && t < start + duration
    }

    /// Transition window in parent ticks [inf, pending `docs/specs/transitions.md`]:
    /// between two clips it is centred on the cut (`d/2` on each side, both clips
    /// pre/post-roll into their media handles); a one-sided fade-out ends at the clip's
    /// end, a fade-in starts at the clip's start.
    static func transitionWindow(leftEnd: Int64?, rightStart: Int64?, duration d: Int64)
        -> (lo: Rational, hi: Rational) {
        let dur = Rational(d)
        switch (leftEnd, rightStart) {
        case (_, let r?) where leftEnd != nil:
            let half = Q.div(dur, Rational(2))
            return (Q.sub(Rational(r), half), Q.add(Rational(r), half))
        case (let l?, nil):
            return (Q.sub(Rational(l), dur), Rational(l))
        case (nil, let r?):
            return (Rational(r), Q.add(Rational(r), dur))
        default:
            return (Q.zero, Q.zero)
        }
    }

    /// WizRec recordings keep `cursor.json` next to `screen.mp4` [cursor-log.md §1]; only the screen
    /// file gets the cursor (not `camera.mp4` in the same folder).
    static func hasCursorSidecar(_ video: URL) -> Bool {
        video.deletingPathExtension().lastPathComponent == "screen"
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

    /// Crop edge order 0..3 = left, top, right, bottom. x-edges 0/2 are [obs]; 1 = top is [?]
    /// (transform.md §6). |v| < 1e−9 is float noise → 0, then clamp to 0…1.
    private static func insets(_ p: SParams, prefix: String, at t: Double) -> Insets {
        func v(_ i: Int) -> Double {
            let x = p.value("\(prefix)\(i)", at: t, default: 0)
            return abs(x) < 1e-9 ? 0 : clamp01(x)
        }
        return Insets(left: v(0), top: v(1), right: v(2), bottom: v(3))
    }

    /// The visible part of a layer in layer-local px (+y up) and the matching texture
    /// coordinates (origin top-left, y down). Both crop families trim edges without moving
    /// the remaining pixels [inf, transform.md §6]; they add per edge until the
    /// difference between them is specified (experiment X1).
    static func visibleRegion(size: CGSize, sourceCrop sc: Insets, geometryCrop gc: Insets)
        -> (rect: CGRect, uv: (u0: Double, vBottom: Double, u1: Double, vTop: Double))? {
        let l = min(sc.left + gc.left, 1), r = min(sc.right + gc.right, 1)
        let t = min(sc.top + gc.top, 1), b = min(sc.bottom + gc.bottom, 1)
        guard l + r < 1, t + b < 1, size.width > 0, size.height > 0 else { return nil }
        let w = size.width, h = size.height
        let rect = CGRect(x: -w / 2 + l * w, y: -h / 2 + b * h, width: (1 - l - r) * w, height: (1 - t - b) * h)
        return (rect, (u0: l, vBottom: 1 - b, u1: 1 - r, vTop: t))
    }
}
