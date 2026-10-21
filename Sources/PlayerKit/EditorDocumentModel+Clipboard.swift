import Foundation
import MediaEngine
import TimelineEngine
import TSCProjKit

extension EditorDocumentModel {
    /// Copies clips for the pasteboard: top-level clips, or clips on the inner tracks of one
    /// group (`ClipboardPayload.copy`).
    public func copyClips(_ ids: [Int64]) throws -> ClipboardPayload {
        try ClipboardPayload.copy(clipIDs: ids, from: project)
    }

    /// The clips Copy/Cut take from `selection`: with group `openGroup` open, the selected
    /// clips directly on its inner tracks when there are any [WizRec]; otherwise the selected
    /// top-level clips. In track, then timeline order.
    public func clipboardSelection(_ selection: Set<Int64>, openGroup: Int64?) -> [Int64] {
        if let openGroup, let tracks = innerTracks(of: openGroup) {
            let ids = tracks.flatMap(\.clips).map(\.id).filter { selection.contains($0) }
            if !ids.isEmpty { return ids }
        }
        return project.tracks.flatMap(\.clips).map(\.id).filter { selection.contains($0) }
    }

    /// Track Paste targets: the track (inner track of `openGroup` when one is open) of the
    /// first selected clip on it; nil when no selected clip is there.
    public func pasteTrack(_ selection: Set<Int64>, openGroup: Int64?) -> Int? {
        let tracks = openGroup.flatMap { innerTracks(of: $0) } ?? project.tracks
        return tracks.firstIndex { $0.clips.contains { selection.contains($0.id) } }
    }

    /// Inner tracks of group `groupID` (any depth); nil when it is not a group.
    func innerTracks(of groupID: Int64) -> [Track]? {
        var found: [Track]?
        for t in project.tracks {
            for c in t.clips {
                c.walk { inner, _ in
                    if found == nil, inner.id == groupID, inner.kind.typeName == "Group" { found = inner.tracks }
                }
            }
        }
        return found
    }

    /// Cut = copy + delete (one undo step, "Cut").
    public func cutClips(_ ids: [Int64]) throws -> ClipboardPayload {
        let payload = try copyClips(ids)
        try perform(CompoundCommand(name: "Cut", [{ _, _ in DeleteClips(clipIDs: ids) }]))
        return payload
    }

    /// Ripple Cut = copy + ripple delete (later clips on each track close the gaps), one undo
    /// step ("Ripple Cut").
    public func rippleCutClips(_ ids: [Int64]) throws -> ClipboardPayload {
        let payload = try copyClips(ids)
        try perform(CompoundCommand(name: String(localized: "Ripple Cut"), [{ _, _ in DeleteClips(clipIDs: ids, ripple: true) }]))
        return payload
    }

    /// Duplicate: copies of `ids` placed right after them (the copy's first clip starts at
    /// `end`, the selection's end in project time) on the track of the first selected clip, else
    /// on a new top track; inside open group `group` by the group paste rule. The clipboard is not
    /// touched. One undo step ("Duplicate"); returns the new top-level (or inner) clip ids
    /// [WizRec: Camtasia's placement is unobserved].
    @discardableResult
    public func duplicateClips(_ ids: [Int64], end: Int64, track: Int?, group: Int64? = nil) async throws -> [Int64] {
        let payload = try copyClips(ids)
        return try await paste(payload, origin: nil, track: track, at: end, group: group,
                               name: String(localized: "Duplicate"))
    }

    /// Pastes `payload` at `ticks` on `track` (0 = bottom); if that overlaps, on a new top
    /// track. One undo step ("Paste"). Returns the pasted top-level clip ids.
    ///
    /// `origin` is the bundle folder the clips were copied from. When it differs from this
    /// bundle, sources whose relative `src` would not resolve here are imported from there
    /// (copied into `media/<ts>/`) and relinked in the same step.
    ///
    /// `group`: an open group to paste into. `track` is then ignored: `ticks` stays
    /// project-timeline time (mapped to the group's inner time and clamped to its window), and
    /// the paste takes the lowest free inner track or a new one on top; the group never grows
    /// (`PasteClips(_:group:at:)`, group-edits.md §8.3).
    @discardableResult
    public func paste(_ payload: ClipboardPayload, origin: URL?, track: Int?, at ticks: Int64,
                      group: Int64? = nil, name: String = "Paste") async throws -> [Int64] {
        let relinks = try await crossProjectRelinks(payload, origin: origin)
        func attempt(_ builders: [CompoundCommand.Builder]) throws -> [Int64] {
            let c = CompoundCommand(name: name, builders + relinks)
            try perform(c)
            return c.steps.compactMap { ($0 as? PasteClips)?.pastedIDs }.first ?? []
        }
        let t = track ?? 0
        if let group {
            return try attempt([{ _, _ in PasteClips(payload, group: group, at: .timeline(ticks)) }])
        }
        do {
            return try attempt([{ _, _ in PasteClips(payload, track: t, at: ticks) }])
        } catch {
            let top = project.tracks.count
            return try attempt([{ _, _ in AddTrack(at: top) }, { _, _ in PasteClips(payload, track: top, at: ticks) }])
        }
    }

    /// RelinkSource steps (built after the paste, by `src`) for payload sources that only
    /// resolve in `origin`. Files are imported before the command runs.
    private func crossProjectRelinks(_ payload: ClipboardPayload, origin: URL?) async throws -> [CompoundCommand.Builder] {
        guard let origin, origin.standardizedFileURL != bundle.directory.standardizedFileURL,
              let doc = try? JSON.parse(payload.data).object,
              let sources = doc["sources"]?.array?.items.compactMap(\.object) else { return [] }
        var builders: [CompoundCommand.Builder] = []
        for s in sources {
            let entry = SourceMedia(s)
            let src = entry.src
            guard !src.isEmpty, !src.hasPrefix("/"), URL(string: src)?.scheme != "file" else { continue }
            let here = bundle.resolve(entry)
            let there = origin.appendingPathComponent(src).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: here.path),
                  FileManager.default.fileExists(atPath: there.path) else { continue }
            let info: MediaInfo
            do { info = try await thumbnailPool.probe(there) } catch { continue }
            let newSrc = try bundle.importFile(there)
            let descriptor = SourceDescriptor(info: info, src: newSrc)
            builders.append { project, _ in
                guard let id = project.sourceBin.last(where: { $0.src == src })?.id else {
                    throw EditError.invalid("pasted source \(src) not found")
                }
                return RelinkSource(sourceID: id, to: descriptor)
            }
        }
        return builders
    }
}
