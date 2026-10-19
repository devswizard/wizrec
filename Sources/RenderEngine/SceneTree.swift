import CaptionLayout
import CoreGraphics
import CoreMedia
import Foundation
import MediaEngine
import TSCProjKit

/// Sendable projection of one clip. Times are ticks in the parent's timeline.
struct SNode: Sendable {
    var id: Int64
    var type: String
    var start: Int64
    var duration: Int64
    var mediaStart: Rational
    var scalar: Rational
    var params: SParams
    var effects: [SEffect]
    /// Behaviours (`GenericBehaviorEffect` entries), kept apart from visual effects.
    var behaviors: [SBehavior] = []
    /// `attributes.gain` (audio), 1 when absent.
    var gain: Double
    var keyframeBase: Conventions.KeyframeBase
    var body: Body
    /// Audio leaves: the source track's transcription (seconds of media time), empty when none.
    var words: [TranscriptWord] = []

    var end: Int64 { start + duration }

    indirect enum Body: Sendable {
        case video(url: URL, stream: Int, size: CGSize, cursor: CursorTrack?)
        case image(url: URL, size: CGSize)
        case shader(url: URL, parameters: SParams, size: CGSize)
        case audio(url: URL, stream: Int)
        case group(tracks: [STrack], size: CGSize)
        case unified(video: SNode?, audio: SNode?)
        case stitched(segments: [SNode])
        case callout(SCallout, size: CGSize)
        case unsupported(type: String, size: CGSize)
    }

    func contains(_ t: Rational) -> Bool { Q.le(Rational(start), t) && Q.lt(t, Rational(end)) }
    func mediaTime(_ t: Rational) -> Rational {
        Conventions.mediaTime(parent: t, start: start, mediaStart: mediaStart, scalar: scalar)
    }
    func keyframeTime(_ t: Rational) -> Double {
        Conventions.keyframeTime(parent: t, start: start, mediaStart: mediaStart, scalar: scalar, base: keyframeBase)
    }

    /// Constant volume × gain of this clip (keyframes ignored in M1).
    var constantGain: Double {
        let v = params["volume"]
        return gain * (v?.base ?? v?.keys.first?.value ?? 1)
    }
}

/// Sendable projection of a `track.transitions[]` entry, resolved against the track's clips.
struct STransition: Sendable {
    var name: String
    var duration: Int64
    var reverse: Bool
    var parameters: SParams
    /// Indices into the track's sorted `clips`; nil = that side is absent (fade in/out).
    var left: Int?
    var right: Int?
    /// Active window `[lo, hi)`, parent ticks.
    var lo: Rational
    var hi: Rational

    func contains(_ t: Rational) -> Bool { Q.le(lo, t) && Q.lt(t, hi) }
    func progress(_ t: Rational) -> Double {
        let span = Q.sub(hi, lo).double
        return span > 0 ? Conventions.clamp01(Q.sub(t, lo).double / span) : 1
    }
}

/// Sendable projection of a track; clips sorted by `start`.
struct STrack: Sendable {
    var index: Int64
    var videoHidden: Bool
    var audioMuted: Bool
    var clips: [SNode]
    /// Non-bypassed transitions whose clips exist, in file order.
    var transitions: [STransition] = []

    /// The transition active at `t`, if any (first in file order).
    func transition(at t: Rational) -> STransition? { transitions.first { $0.contains(t) } }

    /// The clip visible at `t`, if any (last clip starting at or before `t` that still covers it).
    func clip(at t: Rational) -> SNode? {
        var lo = 0, hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Q.le(Rational(clips[mid].start), t) { lo = mid + 1 } else { hi = mid }
        }
        var i = lo - 1
        while i >= 0 {
            if clips[i].contains(t) { return clips[i] }
            // Clips on a track don't overlap; one step back covers equal starts.
            if Q.lt(Rational(clips[i].end), t) { break }
            i -= 1
        }
        return nil
    }
}

/// Builds the `SNode` tree from a `Project` without mutating it.
struct SceneBuilder {
    struct Source { var media: SourceMedia; var url: URL }

    let sources: [Int64: Source]
    let canvas: CGSize
    /// Project ticks per second (transcription keyframe times are project ticks).
    let editRate: Int64

    init(project: Project, resolve: (SourceMedia) -> URL) {
        var s: [Int64: Source] = [:]
        for m in project.sourceBin { s[m.id] = Source(media: m, url: resolve(m)) }
        sources = s
        canvas = CGSize(width: project.width, height: project.height)
        editRate = project.timebase.editRate
    }

    /// `attributes`: per-track UI state index-aligned with `tracks` (top level);
    /// nested group tracks carry the same keys inline.
    func tracks(_ tracks: [Track], attributes: [JSONObject] = []) -> [STrack] {
        let built = tracks.enumerated().map { i, t in
            let a = i < attributes.count ? attributes[i] : nil
            func flag(_ k: String) -> Bool { a?[k]?.bool ?? t.object[k]?.bool ?? false }
            let clips = t.clips.map(node).sorted { $0.start < $1.start }
            return STrack(index: t.index, videoHidden: flag("videoHidden"), audioMuted: flag("audioMuted"),
                          clips: clips, transitions: transitions(t.transitions, clips: clips))
        }
        .sorted { $0.index < $1.index }
        return Self.pairDynamicCaptions(built)
    }

    /// Gives every dynamic-caption callout the transcribed audio clips of the same track list
    /// (`docs/specs/captions.md` §3: no key links them; the caption shows the audio playing at the
    /// same time [inf]). Candidates are `AMFile`s and `UnifiedMedia` audio halves whose source track
    /// has words, overlapping the callout, bottom track first; at time t the first one playing wins
    /// [WizRec rule; which clip Camtasia picks with several is ?, experiment CA2]. Audio inside
    /// groups or stitched clips is not considered.
    static func pairDynamicCaptions(_ tracks: [STrack]) -> [STrack] {
        var audio: [SNode] = []
        for tr in tracks {
            for c in tr.clips {
                switch c.body {
                case .audio where !c.words.isEmpty: audio.append(c)
                case .unified(_, let a?) where !a.words.isEmpty: audio.append(a)
                default: break
                }
            }
        }
        guard !audio.isEmpty else { return tracks }
        return tracks.map { tr in
            var tr = tr
            tr.clips = tr.clips.map { c in
                guard case .callout(var sc, let size) = c.body, var dc = sc.caption else { return c }
                dc.audio = audio.filter { $0.start < c.end && $0.end > c.start }.map {
                    SDynamicCaption.Audio(start: $0.start, end: $0.end, mediaStart: $0.mediaStart, scalar: $0.scalar,
                                          timeline: DynamicCaptionTimeline(words: $0.words, rules: dc.rules, style: dc.style))
                }
                sc.caption = dc
                var n = c
                n.body = .callout(sc, size: size)
                return n
            }
            return tr
        }
    }

    /// Words of a clip's source track when it carries a transcription.
    func words(_ c: Clip) -> [TranscriptWord] {
        guard let src = c.sourceID.flatMap({ sources[$0] }) else { return [] }
        let tracks = src.media.tracks, i = Int(c.sourceTrackNumber ?? 0)
        guard tracks.indices.contains(i), tracks[i].object["parameters"]?.object?["transcription"] != nil else { return [] }
        return Transcript.words(tracks[i], editRate: editRate)
    }

    /// Resolves transitions against `clips`; bypassed ones and ones naming no existing clip are dropped.
    func transitions(_ list: [Transition], clips: [SNode]) -> [STransition] {
        list.compactMap { tr in
            guard !tr.bypassed, tr.duration > 0 else { return nil }
            let l = tr.leftMediaID.flatMap { id in clips.firstIndex { $0.id == id } }
            let r = tr.rightMediaID.flatMap { id in clips.firstIndex { $0.id == id } }
            guard l != nil || r != nil else { return nil }
            let w = Conventions.transitionWindow(leftEnd: l.map { clips[$0].end }, rightStart: r.map { clips[$0].start },
                                                 duration: tr.duration)
            return STransition(name: tr.name, duration: tr.duration, reverse: tr.reversed,
                               parameters: SParams(tr.object["parameters"]?.object),
                               left: l, right: r, lo: w.lo, hi: w.hi)
        }
    }

    func node(_ c: Clip) -> SNode {
        let o = c.object
        let params = SParams(o["parameters"]?.object)
        let entries = (o["effects"]?.array?.items ?? []).compactMap(\.object)
        let behaviors = entries.compactMap(SBehavior.init)
        let effects = entries.compactMap { e -> SEffect? in
            let name = e["effectName"]?.string ?? ""
            guard name != "dummy", !name.isEmpty, e["_type"]?.string != "GenericBehaviorEffect" else { return nil }
            let window: (Double, Double)? = e["duration"]?.double.map { (e["start"]?.double ?? 0, $0) }
            return SEffect(name: name, bypassed: e["bypassed"]?.bool ?? false,
                           parameters: SParams(e["parameters"]?.object), window: window, ramps: SEffect.ramps(e))
        }
        return SNode(id: c.id, type: c.kind.typeName, start: c.start, duration: max(c.duration, 0),
                     mediaStart: c.mediaStart, scalar: c.scalar.num == 0 ? Q.one : c.scalar,
                     params: params, effects: effects, behaviors: behaviors,
                     gain: c.attributes?["gain"]?.double ?? 1,
                     keyframeBase: c.kind == .image
                        ? .timelineOffset(trimStartSum: o["trimStartSum"]?.double ?? 0) : .media,
                     body: body(c), words: c.kind == .audio ? words(c) : [])
    }

    private func body(_ c: Clip) -> SNode.Body {
        let src = c.sourceID.flatMap { sources[$0] }
        let stream = Int(c.sourceTrackNumber ?? 0)
        switch c.kind {
        case .video, .screenVideo:
            guard let src else { return .unsupported(type: c.kind.typeName, size: canvas) }
            let size = Conventions.leafSize(source: src.media, trackNumber: stream, fallback: canvas)
            if src.url.pathExtension.lowercased() == "tscshadervid" || c.object["sourceEffect"] != nil {
                let p = SParams(c.object["sourceEffect"]?.object?["parameters"]?.object)
                return .shader(url: src.url, parameters: p, size: size)
            }
            var cursor: CursorTrack?
            if Conventions.hasCursorSidecar(src.url) {
                cursor = CursorTrack.sidecar(for: src.url)
            } else if Conventions.hasTrecCursor(src.url, stream: stream) {
                let tr = src.media.tracks.first
                let seconds = tr.map { $0.durationSeconds }
                cursor = TrecCursor.cached(src.url, duration: seconds.flatMap { $0 > 0 && $0.isFinite ? $0 : nil })
            }
            return .video(url: src.url, stream: stream, size: size, cursor: cursor)
        case .image:
            guard let src else { return .unsupported(type: c.kind.typeName, size: canvas) }
            return .image(url: src.url, size: Conventions.leafSize(source: src.media, trackNumber: stream,
                                                                     fallback: canvas))
        case .audio:
            guard let src else { return .unsupported(type: c.kind.typeName, size: .zero) }
            return .audio(url: src.url, stream: stream)
        case .group:
            return .group(tracks: tracks(c.tracks),
                          size: Conventions.groupSize(attributes: c.attributes, fallback: canvas))
        case .unified:
            return .unified(video: c.video.map(node), audio: c.audio.map(node))
        case .stitched:
            return .stitched(segments: c.segments.map(node).sorted { $0.start < $1.start })
        case .callout:
            let d = c.callout
            let size = (d?.width ?? 0) > 0 && (d?.height ?? 0) > 0
                ? CGSize(width: d?.width ?? 0, height: d?.height ?? 0) : canvas
            guard let def = c.object["def"]?.object else { return .unsupported(type: "Callout", size: size) }
            return .callout(SCallout(def), size: size)
        case .other(let t):
            return .unsupported(type: t, size: canvas)
        }
    }
}

// MARK: - Visual evaluation

struct SceneEvaluator {
    let editRate: Int64
    /// Output frame rate (motion-blur shutter).
    var frameRate: Rational = Rational(30)

    /// `space`: size of the parent coordinate space (canvas or group), px.
    func layers(_ tracks: [STrack], at t: Rational, space: CGSize) -> [Layer] {
        tracks.compactMap { tr in
            guard !tr.videoHidden else { return nil }
            if let tx = tr.transition(at: t) { return transitionLayer(tr, tx, at: t, space: space) }
            guard let c = tr.clip(at: t) else { return nil }
            return layer(c, at: t)
        }
    }

    /// Both sides are evaluated at `t` even outside their own span (pre/post-roll into the
    /// media handles), per `Conventions.transitionWindow`.
    private func transitionLayer(_ tr: STrack, _ tx: STransition, at t: Rational, space: CGSize) -> Layer? {
        let from = tx.left.flatMap { layer(tr.clips[$0], at: t, roll: true) }
        let to = tx.right.flatMap { layer(tr.clips[$0], at: t, roll: true) }
        guard from != nil || to != nil else { return nil }
        let kt = Q.sub(t, tx.lo).double
        let inst = TransitionInstance(name: tx.name, progress: tx.progress(t), duration: tx.duration,
                                      reverse: tx.reverse, parameters: tx.parameters.evaluated(at: kt))
        return Layer(clipID: to?.clipID ?? from?.clipID ?? 0, content: .transition(inst, from: from, to: to),
                     size: space)
    }

    /// The cursor over a recording clip at recording time `rt` seconds: clip-level `cursorScale`/`cursorOpacity`
    /// (missing → 1, 1), click scaling, cursor effects and motion samples [cursor-effects.md §1–§2].
    func cursorOverlay(_ n: SNode, _ track: CursorTrack, _ c: (position: CGPoint, image: CursorTrack.Image),
                       at rt: Double, kt: Double) -> CursorOverlay {
        let fx = n.effects.filter { $0.isActive(at: kt) && CursorEffects.isCursorEffect($0.name) && !$0.bypassed }
            .map { $0.instance(at: kt) }
        let click = CursorEffects.clickScale(fx.first { $0.name == "LeftClickScaling" }, leftDowns: track.leftDowns, at: rt)
        var motion: [CGPoint] = []
        if let mb = fx.first(where: { $0.name == "CursorMotionBlur" }), mb.value("intensity", 1) > 0 {
            let shutter = mb.value("intensity", 1) * CursorEffects.Spec.motionShutterFrames / max(frameRate.double, 1)
            if let a = track.position(at: rt - shutter / 2), let b = track.position(at: rt + shutter / 2) {
                let d = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
                if d >= 1 {
                    let count = min(max(Int((d / 2).rounded(.up)), 2), 32)
                    motion = (0..<count).compactMap { k in
                        track.position(at: rt + (Double(k) / Double(count - 1) - 0.5) * shutter)
                    }
                }
            }
        }
        return CursorOverlay(image: c.image.url, imageSize: c.image.size, hotspot: c.image.hotspot,
                             position: c.position, sourceSize: track.videoSize,
                             scale: max(n.params.value("cursorScale", at: kt, default: 1), 0) * click,
                             opacity: Conventions.clamp01(n.params.value("cursorOpacity", at: kt, default: 1)),
                             effects: CursorEffects.layerEffects(fx), motion: motion)
    }

    /// Motion-blur transforms for `n` at keyframe time `kt` (`docs/specs/effects/MotionBlur.md`): the
    /// clip's own transform sampled over a shutter of `intensity` output frames centred on `kt` [inf].
    /// Only transform motion blurs; a static transform gives none.
    func motionSamples(_ n: SNode, effects: [EffectInstance], at kt: Double, size: CGSize) -> [CGAffineTransform] {
        guard let mb = effects.first(where: { $0.name == "MotionBlur" && !$0.bypassed }) else { return [] }
        let intensity = mb.value("intensity", 1)
        guard intensity > 0,
              ["translation0", "translation1", "rotation2", "scale0", "scale1"].contains(where: { n.params[$0]?.isAnimated == true })
        else { return [] }
        let fps = max(frameRate.double, 1)
        let shutter = Double(editRate) / fps * intensity * Conventions.motionBlurShutterFrames
        let a = Conventions.transform(n.params, at: kt - shutter / 2)
        let b = Conventions.transform(n.params, at: kt + shutter / 2)
        // Samples from the largest corner displacement across the shutter (≈ 2 px per sample).
        let corners = [CGPoint(x: -size.width / 2, y: -size.height / 2), CGPoint(x: size.width / 2, y: -size.height / 2),
                       CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: -size.width / 2, y: size.height / 2)]
        let disp = corners.map { p -> Double in
            let u = p.applying(a), v = p.applying(b)
            return ((u.x - v.x) * (u.x - v.x) + (u.y - v.y) * (u.y - v.y)).squareRoot()
        }.max() ?? 0
        guard disp >= 0.5 else { return [] }
        let count = min(max(Int((disp / 2).rounded(.up)), 2), 32)
        return (0..<count).map { k in
            Conventions.transform(n.params, at: kt + (Double(k) / Double(count - 1) - 0.5) * shutter)
        }
    }

    /// `roll`: evaluate even when `t` lies outside the clip (transition handles); media
    /// times then extend the clip's mapping and MediaEngine clamps to the stream.
    func layer(_ n: SNode, at t: Rational, roll: Bool = false) -> Layer? {
        guard roll || n.contains(t) else { return nil }
        let kt = n.keyframeTime(t)
        let span = (lo: n.keyframeTime(Rational(n.start)), hi: n.keyframeTime(Rational(n.end)))
        func make(_ content: LayerContent, _ size: CGSize) -> Layer {
            let phase = Conventions.behaviorPhaseSeconds * Double(editRate)
            let behave = n.behaviors.reduce(1.0) { $0 * $1.opacity(at: kt, span: span, phase: phase) }
            // Cursor and click effects never touch the clip's pixels [cursor-effects.md].
            let effects = n.effects.filter { $0.isActive(at: kt) && !CursorEffects.isCursorEffect($0.name) }
                .map { $0.instance(at: kt, span: span) }
            return Layer(clipID: n.id, content: content, size: size,
                         transform: Conventions.transform(n.params, at: kt),
                         sourceCrop: Conventions.sourceCrop(n.params, at: kt),
                         geometryCrop: Conventions.geometryCrop(n.params, at: kt),
                         opacity: Conventions.opacity(n.params, at: kt) * behave,
                         effects: effects, motion: motionSamples(n, effects: effects, at: kt, size: size))
        }
        switch n.body {
        case .video(let url, let stream, let size, let cursor):
            let req = FrameRequest(url: url, stream: stream,
                                   time: Conventions.streamTime(ticks: n.mediaTime(t), editRate: editRate))
            var l = make(.video(req), size)
            if let cursor, let c = cursor.sample(at: req.time.seconds) {
                l.cursor = cursorOverlay(n, cursor, c, at: req.time.seconds, kt: kt)
            }
            return l
        case .image(let url, let size):
            return make(.image(url), size)
        case .shader(let url, let p, let size):
            let seconds = Conventions.shaderTime(media: n.mediaTime(t), editRate: editRate)
            return make(.shader(url, parameters: p.evaluated(at: kt), time: seconds), size)
        case .audio:
            return nil
        case .group(let tracks, let size):
            return make(.group(layers(tracks, at: n.mediaTime(t), space: size)), size)
        case .unified(let video, _):
            // The halves repeat the parent's start/duration/mediaStart [obs], so they
            // are evaluated at the parent's time. The video half carries the transform.
            return video.flatMap { layer($0, at: t, roll: roll) }
        case .stitched(let segments):
            let m = n.mediaTime(t)
            let hit = segments.first(where: { $0.contains(m) })
                ?? (roll ? (Q.lt(m, Rational(segments.first?.start ?? 0)) ? segments.first : segments.last) : nil)
            guard let seg = hit, let inner = layer(seg, at: m, roll: roll) else { return nil }
            // Geometry comes from the stitched clip [obs: segments carry only zero crops];
            // a segment's own transform is composed inside it [inf].
            var l = make(inner.content, inner.size)
            l.transform = inner.transform.concatenating(l.transform)
            if l.geometryCrop == .zero { l.geometryCrop = inner.geometryCrop }
            if l.sourceCrop == .zero { l.sourceCrop = inner.sourceCrop }
            l.opacity *= inner.opacity
            l.effects += inner.effects
            return l
        case .callout(let c, let size):
            var content = c.content(at: kt, size: size)
            if let dc = c.caption {
                let frame = dc.frame(at: t, editRate: editRate)
                content.dynamicCaption = DynamicCaptionRender(frame: frame, style: dc.style)
                content.text = frame?.text ?? ""
                content.runs = SDynamicCaption.textRun(content.runs, length: content.text.utf16.count)
            }
            return make(.callout(content), size)
        case .unsupported(let type, let size):
            return make(.unsupported(type: type), size)
        }
    }
}

// MARK: - Audio evaluation

struct AudioEvaluator {
    let editRate: Int64

    /// Affine map from a nested timeline to top-level ticks: `top = base + (x − origin) × k`.
    struct Mapping {
        var origin: Rational
        var base: Rational
        /// Top-level ticks per local tick (product of enclosing scalars).
        var k: Rational
        static let identity = Mapping(origin: Q.zero, base: Q.zero, k: Q.one)
        func top(_ x: Rational) -> Rational { Q.add(base, Q.mul(Q.sub(x, origin), k)) }
    }

    func segments(_ tracks: [STrack], in range: Range<Int64>) -> [AudioSegment] {
        var out: [AudioSegment] = []
        walk(tracks, map: .identity, lo: Rational(range.lowerBound), hi: Rational(range.upperBound),
             gain: 1, into: &out)
        return out
    }

    private func walk(_ tracks: [STrack], map: Mapping, lo: Rational, hi: Rational, gain: Double,
                      into out: inout [AudioSegment]) {
        for tr in tracks where !tr.audioMuted {
            for c in tr.clips where Q.lt(Rational(c.start), hi) && Q.lt(lo, Rational(c.end)) {
                node(c, map: map, lo: lo, hi: hi, gain: gain, into: &out)
            }
        }
    }

    private func node(_ n: SNode, map: Mapping, lo wLo: Rational, hi wHi: Rational, gain: Double,
                      into out: inout [AudioSegment]) {
        let lo = Q.max(wLo, Rational(n.start)), hi = Q.min(wHi, Rational(n.end))
        guard Q.lt(lo, hi) else { return }
        let g = gain * n.constantGain
        switch n.body {
        case .audio(let url, let stream):
            let a = Q.round(map.top(lo)), b = Q.round(map.top(hi))
            guard a < b else { return }
            let rate = 1 / Q.mul(map.k, n.scalar).double
            out.append(AudioSegment(clipID: n.id, url: url, stream: stream, timelineRange: a..<b,
                                    mediaStart: Conventions.streamTime(ticks: n.mediaTime(lo), editRate: editRate),
                                    rate: rate.isFinite ? rate : 1, gain: g))
        case .unified(_, let audio):
            if let audio { node(audio, map: map, lo: lo, hi: hi, gain: g, into: &out) }
        case .group(let tracks, _):
            walk(tracks, map: inner(n, map), lo: n.mediaTime(lo), hi: n.mediaTime(hi), gain: g, into: &out)
        case .stitched(let segments):
            let m = inner(n, map), mlo = n.mediaTime(lo), mhi = n.mediaTime(hi)
            for s in segments where Q.lt(Rational(s.start), mhi) && Q.lt(mlo, Rational(s.end)) {
                node(s, map: m, lo: mlo, hi: mhi, gain: g, into: &out)
            }
        case .video, .image, .shader, .callout, .unsupported:
            return
        }
    }

    /// Map for a container's inner timeline: inner `x` sits at parent
    /// `start + (x − mediaStart) × scalar`.
    private func inner(_ n: SNode, _ map: Mapping) -> Mapping {
        Mapping(origin: n.mediaStart, base: map.top(Rational(n.start)), k: Q.mul(map.k, n.scalar))
    }
}
