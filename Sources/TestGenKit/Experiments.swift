import Foundation
import TimelineEngine
import TSCProjKit

/// One clip of a research base project: `file` (index into the media list) on top-level
/// `track` at `start` (ticks), or right after the previous clip on that track when `start`
/// is nil (1 s gap), with constant transform `params`.
public struct ExperimentClip: Sendable {
    public var media: Int
    public var track: Int
    public var start: Int64?
    public var params: [String: Double]
    public var label: String
    public init(media: Int, track: Int, start: Int64? = nil, params: [String: Double] = [:], label: String = "") {
        self.media = media; self.track = track; self.start = start; self.params = params; self.label = label
    }
}

/// A base project for an automated Camtasia experiment: Camtasia opens it, applies one
/// menu-driven edit per clip, saves under a new name, and the two files are diffed.
public struct ExperimentBase: Sendable {
    /// Bundle and folder name, e.g. `ef0-base`.
    public var name: String
    /// Folder under the refs root, e.g. `research/effects`.
    public var group: String
    public var summary: String
    /// Media file names (looked up in the media directories given to `write`).
    public var media: [String]
    public var clips: [ExperimentClip]
    public init(name: String, group: String, summary: String, media: [String], clips: [ExperimentClip]) {
        self.name = name; self.group = group; self.summary = summary; self.media = media; self.clips = clips
    }
}

/// Where each clip landed (written as `<name>.clips.json` next to the bundle so the
/// automation can park the playhead mid-clip): seconds on the timeline.
public struct ExperimentClipPlacement: Codable, Sendable {
    public var label: String
    public var track: Int
    public var clipID: Int64
    public var start: Double
    public var end: Double
}

public enum Experiments {
    static let sec: Int64 = 705_600_000

    /// Research base projects (all synthetic media; see docs/testing/camtasia-automation.md).
    /// `speech` is the file name of a synthetic speech recording supplied by the caller.
    public static func bases(speech: String) -> [ExperimentBase] {
        let grey = "M-grey-400.png", card = "card-1600x900.png", clipA = "A-testcard-1080p30.mp4"
        func seq(_ n: Int, media: Int, track: Int = 0, params: [String: Double] = [:], labels: [String]) -> [ExperimentClip] {
            (0..<n).map { ExperimentClip(media: media, track: track, params: params, label: labels.indices.contains($0) ? labels[$0] : "\($0)") }
        }
        return [
            ExperimentBase(
                name: "x-group-base", group: "format", summary: "X3/X5: two card stills on tracks 0 and 1, the upper one shifted left.",
                media: [card], clips: [
                    ExperimentClip(media: 0, track: 0, start: 0, params: ["scale0": 0.5, "scale1": 0.5], label: "lower"),
                    ExperimentClip(media: 0, track: 1, start: 0, params: ["translation0": -300, "scale0": 0.5, "scale1": 0.5], label: "upper"),
                ]),
            ExperimentBase(
                name: "x-photo-base", group: "format", summary: "X1/X2/X6: one card still at 0 s.",
                media: [card], clips: [ExperimentClip(media: 0, track: 0, start: 0, label: "photo")]),
            ExperimentBase(
                name: "x7-base", group: "format",
                summary: "X7: A on track 0 (0–10 s), card on track 1 from 2 s, A + card on tracks 2/3 (0 s), A on track 4 (0–10 s).",
                media: [clipA, card], clips: [
                    ExperimentClip(media: 0, track: 0, start: 0, label: "t0-video"),
                    ExperimentClip(media: 1, track: 1, start: 2 * sec, label: "t1-photo"),
                    ExperimentClip(media: 0, track: 2, start: 0, label: "t2-video"),
                    ExperimentClip(media: 1, track: 3, start: 0, label: "t3-photo"),
                    ExperimentClip(media: 0, track: 4, start: 0, label: "t4-video"),
                ]),
            ExperimentBase(
                name: "one-video-base", group: "format", summary: "X7/X8/ED: clip A alone on track 0 at 0 s.",
                media: [clipA], clips: [ExperimentClip(media: 0, track: 0, start: 0, label: "video")]),
            ExperimentBase(
                name: "video-photo-base", group: "format", summary: "X7 group track: clip A on track 0 and the card on track 1, both at 0 s.",
                media: [clipA, card], clips: [
                    ExperimentClip(media: 0, track: 0, start: 0, label: "video"),
                    ExperimentClip(media: 1, track: 1, start: 0, label: "photo"),
                ]),
            ExperimentBase(
                name: "ef0-base", group: "research/effects",
                summary: "EF0: 40 grey stills end to end on track 0 (one effect each, applied from the menu).",
                media: [grey], clips: seq(40, media: 0, labels: [])),
            ExperimentBase(
                name: "vid-base", group: "research/effects",
                summary: "Videos: 12 copies of clip A end to end on track 0 (behaviours, animations, speed, extend frame).",
                media: [clipA], clips: seq(12, media: 0, labels: [])),
            ExperimentBase(
                name: "au1-base", group: "research/audio",
                summary: "AU1: 10 copies of a synthetic speech clip end to end on track 0.",
                media: [speech], clips: seq(10, media: 0, labels: [])),
            ExperimentBase(
                name: "ca-base", group: "research/captions",
                summary: "CA1/CA2: synthetic speech on track 0 at 0 s and clip A on track 1.",
                media: [speech, clipA], clips: [
                    ExperimentClip(media: 0, track: 0, start: 0, label: "speech"),
                    ExperimentClip(media: 1, track: 1, start: 0, label: "video"),
                ]),
            ExperimentBase(
                name: "card-base", group: "research/callouts",
                summary: "CO3 / annotations: the 1920×1080 test card on track 0 at 0 s.",
                media: ["M-card-1920x1080.png"], clips: [ExperimentClip(media: 0, track: 0, start: 0, label: "card")]),
        ]
    }

    /// Writes `base` into `<root>/<group>/<name>/<name>.cmproj` (replacing it) plus
    /// `<name>.clips.json`. `find` maps a media file name to its URL; `describe` probes it.
    @MainActor @discardableResult
    public static func write(_ base: ExperimentBase, root: URL, find: (String) -> URL?,
                             describe: (URL, String) async throws -> SourceDescriptor) async throws -> URL {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(base.group, isDirectory: true).appendingPathComponent(base.name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundleURL = dir.appendingPathComponent("\(base.name).cmproj", isDirectory: true)
        try? fm.removeItem(at: bundleURL)
        let bundle = try ProjectBundle.create(at: bundleURL, width: 1920, height: 1080, fps: 30)
        let undo = UndoStack(project: bundle.project)
        var sourceIDs: [Int64] = []
        for name in base.media {
            guard let url = find(name) else { throw MediaWriterError.setup("missing media \(name)") }
            let src = try bundle.importFile(url)
            let copied = bundle.directory.appendingPathComponent(String(src.dropFirst(2)))
            let add = AddSource(try await describe(copied, src))
            try undo.perform(add)
            guard let id = add.sourceID else { throw MediaWriterError.setup("AddSource gave no id") }
            sourceIDs.append(id)
        }
        var trackEnd: [Int: Int64] = [:]
        var placements: [ExperimentClipPlacement] = []
        for c in base.clips {
            while bundle.project.tracks.count <= c.track { try undo.perform(AddTrack(at: bundle.project.tracks.count)) }
            let start = c.start ?? trackEnd[c.track].map { $0 + sec } ?? 0
            let insert = InsertClip(sourceID: sourceIDs[c.media], track: c.track, start: start)
            try undo.perform(insert)
            guard let id = insert.clipID,
                  let clip = bundle.project.tracks[c.track].clips.first(where: { $0.id == id }) else {
                throw MediaWriterError.setup("InsertClip gave no id")
            }
            for (k, v) in c.params.sorted(by: { $0.key < $1.key }) {
                try undo.perform(SetParameter(clipID: id, parameter: k, value: v))
            }
            trackEnd[c.track] = clip.end
            placements.append(.init(label: c.label, track: c.track, clipID: id,
                                    start: Double(clip.start) / Double(sec), end: Double(clip.end) / Double(sec)))
        }
        try bundle.saveWithBackup()
        try? fm.removeItem(at: bundleURL.appendingPathComponent("project.tscproj" + ProjectBundle.backupSuffix))
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(placements).write(to: dir.appendingPathComponent("\(base.name).clips.json"), options: .atomic)
        return bundleURL
    }
}
