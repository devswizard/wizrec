import Foundation
import TimelineEngine
import TSCProjKit

/// Visual category of a clip on the timeline (decides colour and contents).
public enum TimelineClipStyle: String, Sendable, Equatable, CaseIterable {
    case video, screen, audio, image, unified, stitched, group, callout, shader, other
}

/// A media stream a clip shows, as the timeline's media provider sees it.
public struct TimelineMediaRef: Hashable, Sendable {
    /// `sourceBin` id.
    public var sourceID: Int64
    /// `sourceBin[].src` as written in the project (usually `./media/…`, bundle-relative).
    public var src: String
    /// Stream index (a clip's `trackNumber`; MediaEngine's audio/video stream index).
    public var stream: Int

    public init(sourceID: Int64, src: String, stream: Int) {
        self.sourceID = sourceID; self.src = src; self.stream = stream
    }
}

/// A stretch of a clip that shows one media stream linearly.
/// Timeline `start`/`end` are track ticks; `mediaStart` is stream **seconds** at `start`;
/// `rate` is stream seconds per timeline second (the clip speed).
public struct TimelineMediaSpan: Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    public var media: TimelineMediaRef
    public var mediaStart: Double
    public var rate: Double

    /// Stream seconds at track tick `t`.
    public func mediaSeconds(at t: Int64, editRate: Int64) -> Double {
        mediaStart + Double(t - start) / Double(editRate) * rate
    }
}

/// One clip inside a collapsed group, mapped to the parent track's time (ticks).
public struct TimelineLaneSpan: Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    public var style: TimelineClipStyle
}

/// Immutable projection of one top-level clip for drawing and hit testing. Times in ticks.
public struct TimelineClipItem: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var style: TimelineClipStyle
    /// Display name: `attributes.ident`, else the source file name, else the callout text.
    public var name: String
    public var start: Int64
    public var duration: Int64
    public var end: Int64 { start + duration }
    /// Playback speed (1 / `scalar`); 1 for normal clips.
    public var speed: Double
    /// Number of non-placeholder effects on the clip itself.
    public var effectCount: Int
    /// Spans that feed the filmstrip (empty when the clip has no video).
    public var videoSpans: [TimelineMediaSpan]
    /// Spans that feed the waveform (empty when the clip has no audio).
    public var audioSpans: [TimelineMediaSpan]
    /// Stitched clips: track ticks where one segment ends and the next starts.
    public var cuts: [Int64]
    /// Groups: inner tracks (bottom first), each a list of child spans in track ticks.
    public var lanes: [[TimelineLaneSpan]]
    /// Earliest start edge the available media allows (track ticks, frame-rounded inward);
    /// nil when unbounded (images, callouts, shaders, unknown length).
    public var minStart: Int64? = nil
    /// Latest end edge the available media allows; nil when unbounded.
    public var maxEnd: Int64? = nil
}

/// A transition drawn as an overlay. `start`/`end` in track ticks.
public struct TimelineTransitionItem: Sendable, Equatable {
    public var name: String
    public var start: Int64
    public var end: Int64
    public var leftClipID: Int64?
    public var rightClipID: Int64?
}

/// Immutable projection of one top-level track.
public struct TimelineTrackItem: Sendable, Equatable {
    /// Index in the scene's `tracks` (0 = bottom of the canvas stack).
    public var index: Int
    /// `trackAttributes[].ident`, or `"Track N"` (1-based) when empty.
    public var name: String
    public var audioMuted: Bool
    public var videoHidden: Bool
    public var magnetic: Bool
    public var solo: Bool
    public var locked: Bool
    /// `metadata.trackHeight`, points, when the project stores one.
    public var storedHeight: Double?
    /// Clips sorted by start.
    public var clips: [TimelineClipItem]
    public var transitions: [TimelineTransitionItem]
}

/// Value-type view of a project's timeline, rebuilt after every edit. All times in ticks.
public struct TimelineSnapshot: Sendable, Equatable {
    public var editRate: Int64
    /// Output frame rate (frame grid for snapping and the ruler).
    public var frameRate: Rational
    public var tracks: [TimelineTrackItem]
    /// Latest clip end.
    public var duration: Int64
    /// Timeline markers, sorted by time (ticks).
    public var markers: [Marker] = []
    /// Ids of the open groups, outermost first (empty: the top-level timeline is shown).
    public var groupPath: [Int64] = []
    /// Names of the open groups (breadcrumb), same order.
    public var groupNames: [String] = []
    /// Inner ↔ root time map of the innermost open group; all times above are root ticks.
    public var timeMap: TimelineTimeMap = .identity
    /// Root-timeline span where the innermost open group is visible.
    public var groupWindow: ClosedRange<Int64>?

    public static let empty = TimelineSnapshot(editRate: 705_600_000, frameRate: Rational(30), tracks: [], duration: 0)

    /// Earliest tick a clip of the shown timeline can start at: 0 at the top level, the root
    /// tick of the open group's inner time 0 otherwise.
    public var timeOrigin: Int64 { timeMap.display(0) }

    /// Ticks per output frame (≥ 1).
    public var frameTicks: Int64 {
        guard frameRate.num > 0 else { return 1 }
        return max(1, (editRate * frameRate.den) / frameRate.num)
    }

    public func track(_ index: Int) -> TimelineTrackItem? {
        tracks.indices.contains(index) ? tracks[index] : nil
    }

    /// The clip with `id` and the index of its track.
    public func clip(_ id: Int64) -> (track: Int, clip: TimelineClipItem)? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return (t.index, c) } }
        return nil
    }

    public var allClips: [TimelineClipItem] { tracks.flatMap(\.clips) }
}

// MARK: - Building

extension TimelineSnapshot {
    /// Projects `project`'s top-level timeline, or the inner tracks of the group at the end of
    /// `openGroups` (ids, outermost first). Never mutates the project. A path that no longer
    /// resolves is cut at the first missing group (`groupPath` says what was opened).
    @MainActor
    public init(project: Project, openGroups: [Int64] = []) {
        let rate = project.timebase.editRate > 0 ? project.timebase.editRate : 30
        var sources: [Int64: SourceMedia] = [:]
        for s in project.sourceBin { sources[s.id] = s }
        let fr = project.frameRate
        let frame = fr.num > 0 ? max(1, (rate * fr.den) / fr.num) : 1
        let builder = SnapshotBuilder(editRate: rate, sources: sources, frameTicks: frame)

        var sceneTracks = project.tracks
        var attrs: [JSONObject?] = (project.timeline?.trackAttributes ?? []).map { $0 }
        var map = TimelineTimeMap.identity
        var path: [Int64] = [], names: [String] = []
        var window: ClosedRange<Int64>?
        for gid in openGroups {
            guard let g = sceneTracks.flatMap(\.clips).first(where: { $0.id == gid && $0.kind == .group }) else { break }
            let s = g.scalar.double > 0 ? g.scalar.double : 1
            window = map.display(g.start)...map.display(g.end)
            // inner i → parent g.start + (i − mediaStart) × scalar → display.
            map = TimelineTimeMap(origin: map.origin + map.scale * (Double(g.start) - g.mediaStart.double * s),
                                  scale: map.scale * s)
            path.append(gid)
            names.append(g.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Group")
            sceneTracks = g.tracks
            attrs = g.tracks.map { $0.object }  // inner tracks carry their flags inline
        }
        var tracks: [TimelineTrackItem] = []
        for (i, t) in sceneTracks.enumerated() {
            let item = builder.track(t, index: i, attributes: attrs.indices.contains(i) ? attrs[i] : nil)
            tracks.append(map.isIdentity ? item : item.mapped(map))
        }
        self.init(editRate: rate, frameRate: project.frameRate, tracks: tracks,
                  duration: max(tracks.flatMap(\.clips).map(\.end).max() ?? 0, window?.upperBound ?? 0),
                  markers: Markers.timeline(project), groupPath: path, groupNames: names, timeMap: map,
                  groupWindow: window)
    }
}

/// Affine map between a group's inner timeline and the root timeline the view draws:
/// `display = origin + scale × inner` (ticks). Identity at the top level.
public struct TimelineTimeMap: Sendable, Equatable {
    public var origin: Double
    public var scale: Double
    public static let identity = TimelineTimeMap(origin: 0, scale: 1)
    public var isIdentity: Bool { origin == 0 && scale == 1 }

    public init(origin: Double, scale: Double) { self.origin = origin; self.scale = scale }

    /// Root-timeline tick of inner tick `t`.
    public func display(_ t: Int64) -> Int64 { isIdentity ? t : Int64((origin + scale * Double(t)).rounded()) }
    /// Inner tick of root-timeline tick `t` (what nested commands take).
    public func inner(_ t: Int64) -> Int64 { isIdentity ? t : Int64(((Double(t) - origin) / scale).rounded()) }
    /// Root-timeline length of `ticks` inner ticks.
    public func length(_ ticks: Int64) -> Int64 { isIdentity ? ticks : Int64((Double(ticks) * scale).rounded()) }
}

extension TimelineTrackItem {
    func mapped(_ m: TimelineTimeMap) -> TimelineTrackItem {
        var t = self
        t.clips = clips.map { $0.mapped(m) }
        t.transitions = transitions.map { tr in
            var x = tr; x.start = m.display(tr.start); x.end = m.display(tr.end); return x
        }
        return t
    }
}

extension TimelineClipItem {
    func mapped(_ m: TimelineTimeMap) -> TimelineClipItem {
        var c = self
        c.start = m.display(start)
        c.duration = m.display(start + duration) - c.start
        c.videoSpans = videoSpans.map { $0.mapped(m) }
        c.audioSpans = audioSpans.map { $0.mapped(m) }
        c.cuts = cuts.map(m.display)
        c.lanes = lanes.map { $0.map { s in TimelineLaneSpan(start: m.display(s.start), end: m.display(s.end), style: s.style) } }
        c.minStart = minStart.map(m.display)
        c.maxEnd = maxEnd.map(m.display)
        return c
    }
}

extension TimelineMediaSpan {
    func mapped(_ m: TimelineTimeMap) -> TimelineMediaSpan {
        var s = self
        s.start = m.display(start); s.end = m.display(end)
        s.rate = rate / m.scale
        return s
    }
}

private struct SnapshotBuilder {
    let editRate: Int64
    let sources: [Int64: SourceMedia]
    let frameTicks: Int64

    func track(_ t: Track, index: Int, attributes a: JSONObject?) -> TimelineTrackItem {
        let ident = a?["ident"]?.string ?? ""
        let meta = a?["metadata"]?.object
        let lockedText = meta?["IsLocked"]?.string?.lowercased()
        let locked = a?["locked"]?.bool ?? (lockedText == "true")
        let height = meta?["trackHeight"]?.string.flatMap(Double.init) ?? meta?["trackHeight"]?.double
        let clips = t.clips.map { item($0) }.sorted { $0.start < $1.start }
        var byID: [Int64: TimelineClipItem] = [:]
        for c in clips { byID[c.id] = c }
        let transitions = t.transitions.compactMap { transition($0, clips: byID) }
        return TimelineTrackItem(
            index: index, name: ident.isEmpty ? "Track \(index + 1)" : ident,
            audioMuted: a?["audioMuted"]?.bool ?? false, videoHidden: a?["videoHidden"]?.bool ?? false,
            magnetic: a?["magnetic"]?.bool ?? false, solo: a?["solo"]?.bool ?? false, locked: locked,
            storedHeight: height, clips: clips, transitions: transitions)
    }

    /// Transition window: both sides → centred on the cut; left only → end of the left
    /// clip (fade out); right only → start of the right clip (fade in). [inf, FORMAT.md]
    func transition(_ tr: Transition, clips: [Int64: TimelineClipItem]) -> TimelineTransitionItem? {
        let d = max(0, tr.duration)
        let l = tr.leftMediaID.flatMap { clips[$0] }
        let r = tr.rightMediaID.flatMap { clips[$0] }
        let start: Int64, end: Int64
        switch (l, r) {
        case let (l?, r?):
            let cut = (l.end + r.start) / 2
            start = cut - d / 2; end = start + d
        case let (l?, nil): start = l.end - d; end = l.end
        case let (nil, r?): start = r.start; end = r.start + d
        default: return nil
        }
        return TimelineTransitionItem(name: tr.name, start: start, end: end,
                                      leftClipID: l?.id, rightClipID: r?.id)
    }

    func item(_ c: Clip) -> TimelineClipItem {
        let style = style(of: c)
        let scalar = c.scalar.double > 0 ? c.scalar.double : 1
        var video: [TimelineMediaSpan] = []
        var audio: [TimelineMediaSpan] = []
        var cuts: [Int64] = []
        var lanes: [[TimelineLaneSpan]] = []
        let window = Window(start: c.start, end: c.end, mediaStart: c.mediaStart.double, scalar: scalar)
        switch c.kind {
        case .stitched:
            stitched(c, window: window, video: &video, audio: &audio, cuts: &cuts)
        case .group:
            lanes = groupLanes(c, window: window)
        default:
            leafOrUnified(c, window: window, video: &video, audio: &audio)
        }
        let (lo, hi) = limits(c)
        return TimelineClipItem(
            id: c.id, style: style, name: name(of: c), start: c.start, duration: c.duration,
            speed: 1 / scalar, effectCount: c.effects.filter { !$0.isPlaceholder }.count,
            videoSpans: video, audioSpans: audio, cuts: cuts, lanes: lanes, minStart: lo, maxEnd: hi)
    }

    /// Edge limits from the available media, like `TrimClip`: for each timed part,
    /// `start − (mediaStart − lower) × scalar` (ceil to a frame) and
    /// `start + (length − mediaStart) × scalar` (floor to a frame). Display only; the
    /// command does the exact clamp.
    func limits(_ c: Clip) -> (Int64?, Int64?) {
        let parts = c.kind == .unified ? [c.video, c.audio].compactMap { $0 } : [c]
        var lo: Int64?, hi: Int64?
        for p in parts {
            guard let len = mediaLength(p) else { continue }
            let s = p.scalar.double > 0 ? p.scalar.double : 1
            let lower = c.kind == .stitched ? max(0, p.object["minMediaStart"]?.double ?? 0) : 0
            let a = Double(p.start) - (p.mediaStart.double - lower) * s
            let b = Double(p.start) + (len - p.mediaStart.double) * s
            let fa = Int64((a / Double(frameTicks)).rounded(.up)) * frameTicks
            let fb = Int64((b / Double(frameTicks)).rounded(.down)) * frameTicks
            lo = max(lo ?? fa, fa); hi = min(hi ?? fb, fb)
        }
        return (lo, hi)
    }

    /// Media length in the clip's media-time ticks; nil when unbounded or unknown.
    func mediaLength(_ p: Clip) -> Double? {
        switch p.kind {
        case .video, .screenVideo, .audio:
            guard let sid = p.sourceID, let src = sources[sid] else { return nil }
            let tracks = src.tracks, n = Int(p.sourceTrackNumber ?? 0)
            guard tracks.indices.contains(n), tracks[n].editRate > 0, tracks[n].range.count == 2 else { return nil }
            let len = Double(tracks[n].range[1] - tracks[n].range[0]) * Double(editRate) / Double(tracks[n].editRate)
            return len.isFinite && len >= 0 && len < 1e17 ? len : nil
        case .group:
            return p.tracks.flatMap(\.clips).map { Double($0.end) }.max()
        case .stitched:
            return p.segments.map { Double($0.end) }.max()
        default:
            return nil
        }
    }

    /// Mapping of a clip's window: track ticks [start, end) ↔ inner ticks from `mediaStart`,
    /// `inner = mediaStart + (t − start) / scalar` (time-mapping.md §4).
    struct Window {
        var start: Int64, end: Int64, mediaStart: Double, scalar: Double
        func track(atInner s: Double) -> Double { Double(start) + (s - mediaStart) * scalar }
        var innerEnd: Double { mediaStart + Double(end - start) / scalar }
    }

    func leafOrUnified(_ c: Clip, window w: Window, video: inout [TimelineMediaSpan], audio: inout [TimelineMediaSpan]) {
        // `inner` of this clip, as stream seconds at `w.start`, at `rate` stream s per track s.
        func span(_ leaf: Clip, innerAtStart: Double, rate: Double, start: Int64, end: Int64) -> (TimelineMediaSpan?, Bool) {
            guard let sid = leaf.sourceID, let src = sources[sid] else { return (nil, false) }
            if src.src.lowercased().hasSuffix(".tscshadervid") { return (nil, false) }
            let stream = Int(leaf.sourceTrackNumber ?? 0)
            let ref = TimelineMediaRef(sourceID: sid, src: src.src, stream: stream)
            return (TimelineMediaSpan(start: start, end: end, media: ref,
                                      mediaStart: innerAtStart / Double(editRate), rate: rate), true)
        }
        switch c.kind {
        case .unified:
            // Children carry their own fields at the parent's track time (time-mapping.md §4).
            for child in [c.video, c.audio].compactMap({ $0 }) {
                let cs = child.scalar.double > 0 ? child.scalar.double : 1
                let inner = child.mediaStart.double + Double(w.start - child.start) / cs
                if let s = span(child, innerAtStart: inner, rate: 1 / cs, start: w.start, end: w.end).0 {
                    if child.kind == .audio { audio.append(s) } else { video.append(s) }
                }
            }
        case .video, .screenVideo, .image:
            let imageAt0 = c.kind == .image
            if let s = span(c, innerAtStart: imageAt0 ? 0 : w.mediaStart, rate: imageAt0 ? 0 : 1 / w.scalar,
                            start: w.start, end: w.end).0 { video.append(s) }
        case .audio:
            if let s = span(c, innerAtStart: w.mediaStart, rate: 1 / w.scalar, start: w.start, end: w.end).0 {
                audio.append(s)
            }
        default: break
        }
    }

    func stitched(_ c: Clip, window w: Window, video: inout [TimelineMediaSpan], audio: inout [TimelineMediaSpan],
                  cuts: inout [Int64]) {
        let segs = c.segments
        for (i, seg) in segs.enumerated() {
            let lo = max(Double(seg.start), w.mediaStart), hi = min(Double(seg.end), w.innerEnd)
            guard hi > lo else { continue }
            let ts = Int64(w.track(atInner: lo).rounded()), te = Int64(w.track(atInner: hi).rounded())
            if i > 0, Double(seg.start) > w.mediaStart { cuts.append(ts) }
            let segScalar = seg.scalar.double > 0 ? seg.scalar.double : 1
            for leaf in seg.kind == .unified ? [seg.video, seg.audio].compactMap({ $0 }) : [seg] {
                guard let sid = leaf.sourceID, let src = sources[sid] else { continue }
                let ls = leaf.scalar.double > 0 ? leaf.scalar.double : segScalar
                let innerSeg = leaf.mediaStart.double + (lo - Double(leaf.start)) / ls
                let ref = TimelineMediaRef(sourceID: sid, src: src.src, stream: Int(leaf.sourceTrackNumber ?? 0))
                let s = TimelineMediaSpan(start: ts, end: te, media: ref, mediaStart: innerSeg / Double(editRate),
                                          rate: 1 / (w.scalar * ls))
                if leaf.kind == .audio { audio.append(s) } else { video.append(s) }
            }
        }
    }

    func groupLanes(_ c: Clip, window w: Window) -> [[TimelineLaneSpan]] {
        c.tracks.map { inner in
            inner.clips.compactMap { child in
                let s = max(w.track(atInner: Double(child.start)), Double(w.start))
                let e = min(w.track(atInner: Double(child.end)), Double(w.end))
                guard e > s else { return nil }
                return TimelineLaneSpan(start: Int64(s.rounded()), end: Int64(e.rounded()), style: style(of: child))
            }
        }
    }

    func style(of c: Clip) -> TimelineClipStyle {
        switch c.kind {
        case .video:
            if let sid = c.sourceID, let s = sources[sid], s.src.lowercased().hasSuffix(".tscshadervid") { return .shader }
            return .video
        case .screenVideo: return .screen
        case .audio: return .audio
        case .image: return .image
        case .unified: return .unified
        case .stitched: return .stitched
        case .group: return .group
        case .callout: return .callout
        case .other: return .other
        }
    }

    func name(of c: Clip) -> String {
        if let n = c.name, !n.isEmpty { return n }
        if c.kind == .callout, let t = c.callout?.text, !t.isEmpty {
            return t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        }
        var sid = c.sourceID
        if sid == nil { sid = (c.video ?? c.audio ?? c.segments.first?.video ?? c.segments.first)?.sourceID }
        if let sid, let s = sources[sid] {
            let file = (s.src as NSString).lastPathComponent
            if !file.isEmpty { return file }
        }
        switch c.kind {
        case .group: return "Group"
        case .callout: return "Annotation"
        default: return c.kind.typeName
        }
    }
}
