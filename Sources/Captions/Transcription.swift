import Foundation
import TSCProjKit
import TimelineEngine

/// Writes recognised words onto a source's audio track (`docs/specs/captions.md` §2):
/// `sourceBin[id].sourceTracks[track].parameters.transcription` = `{type: "string", keyframes}`
/// with one `{endTime, time, value, duration: 0}` keyframe per word (that key order [obs]), and
/// `transcriptionSet: true` (inserted before `parameters` when new [obs position]).
///
/// - Times: word `start` (seconds of source media time) → project ticks, **not** frame-rounded
///   (Camtasia 2026 writes e.g. 2776800600 [obs CA2]). A time at or before the previous keyframe
///   is pushed one tick later so times stay strictly increasing.
/// - Closing marks: a `value: "%GAP"` keyframe where speech stops: at the last word's `end`
///   (always [obs CA2]), and after any word followed by at least `closeGap` seconds of silence
///   [WizRec; CA2 shows only the final one]. Readers also accept CP1's `""` (`Transcript.endMarkers`).
/// - Words are trimmed; empty words are skipped. An empty list writes an empty `keyframes` array.
/// - Replaces any existing transcription of that track. Revert is byte-identical.
@MainActor public final class ApplyTranscription: EditCommand {
    public let name = "Transcribe"
    public let sourceID: Int64
    /// Index into the source's `sourceTracks`; must be an audio track (`type` 2).
    public let track: Int
    public let words: [TranscriptWord]
    /// Seconds of silence after a word that close it with a `""` keyframe.
    public let closeGap: Double
    private var swap = Swap()

    public init(sourceID: Int64, track: Int, words: [TranscriptWord], closeGap: Double = 0.5) {
        self.sourceID = sourceID; self.track = track; self.words = words; self.closeGap = closeGap
    }

    public func apply(to project: Project) throws {
        guard let si = Tree.sourceIndex(project, id: sourceID) else { throw EditError.invalid("no source \(sourceID)") }
        let path = TreePath.sourceBin.appending(.index(si), .key("sourceTracks"), .index(track))
        guard let old = path.resolve(in: project.root)?.object else {
            throw EditError.invalid("source \(sourceID) has no track \(track)")
        }
        guard SourceTrack(old).isAudio else { throw EditError.invalid("source \(sourceID) track \(track) is not audio") }
        let transcription = J.obj([("type", J.str("string")), ("keyframes", J.arr(Self.keyframes(words, project, closeGap)))])
        var new = withKey(old, setting: "transcriptionSet", to: .bool(true), before: "parameters")
        let params = new["parameters"]?.object?.copy() ?? JSONObject()
        params["transcription"] = transcription
        new = withKey(new, setting: "parameters", to: .object(params))
        try swap.commit([(path, .object(new))], in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }

    static func keyframes(_ words: [TranscriptWord], _ project: Project, _ closeGap: Double) -> [JSON] {
        let step: Int64 = 1
        func ticks(_ seconds: Double) -> Int64 { project.timebase.ticks(seconds: max(0, seconds)) }
        let gap = "%GAP"
        let clean = words.map { w in
            var w = w; w.text = w.text.trimmingCharacters(in: .whitespacesAndNewlines); return w
        }.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
        var out: [JSON] = []
        var last: Int64?
        func mark(_ t: Int64, _ text: String) {
            let t = last.map { max(t, $0 + step) } ?? t
            out.append(J.obj([("endTime", J.int(t)), ("time", J.int(t)), ("value", J.str(text)), ("duration", J.int(0))]))
            last = t
        }
        for (i, w) in clean.enumerated() {
            mark(ticks(w.start), w.text)
            let end = ticks(w.end)
            if i + 1 == clean.count {
                mark(end, gap)  // always closed, at least one tick after its start
            } else if clean[i + 1].start - w.end >= closeGap, let l = last, end > l {
                mark(end, gap)
            }
        }
        return out
    }
}

/// Removes a source track's transcription (`parameters.transcription` and `transcriptionSet`).
/// Revert is byte-identical. Throws when the track has neither.
@MainActor public final class RemoveTranscription: EditCommand {
    public let name = "Remove Transcription"
    public let sourceID: Int64
    public let track: Int
    private var swap = Swap()

    public init(sourceID: Int64, track: Int) { self.sourceID = sourceID; self.track = track }

    public func apply(to project: Project) throws {
        guard let si = Tree.sourceIndex(project, id: sourceID) else { throw EditError.invalid("no source \(sourceID)") }
        let path = TreePath.sourceBin.appending(.index(si), .key("sourceTracks"), .index(track))
        guard let old = path.resolve(in: project.root)?.object else { throw EditError.invalid("no track \(track)") }
        guard old["transcriptionSet"] != nil || old["parameters"]?.object?["transcription"] != nil else {
            throw EditError.invalid("no transcription")
        }
        let new = old.copy()
        new["transcriptionSet"] = nil
        new["parameters"]?.object?["transcription"] = nil
        try swap.commit([(path, .object(new))], in: project)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}

extension Transcript {
    /// Words of `sourceBin[id].sourceTracks[track]` in `project` (seconds of source media time).
    @MainActor public static func words(in project: Project, sourceID: Int64, track: Int) -> [TranscriptWord] {
        guard let t = project.source(id: sourceID)?.tracks, t.indices.contains(track) else { return [] }
        return words(t[track], editRate: project.timebase.editRate)
    }
}
