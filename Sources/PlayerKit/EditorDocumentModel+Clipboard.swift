import Foundation
import MediaEngine
import TimelineEngine
import TSCProjKit

extension EditorDocumentModel {
    /// Copies top-level clips for the pasteboard.
    public func copyClips(_ ids: [Int64]) throws -> ClipboardPayload {
        try ClipboardPayload.copy(clipIDs: ids, from: project)
    }

    /// Cut = copy + delete (one undo step, "Cut").
    public func cutClips(_ ids: [Int64]) throws -> ClipboardPayload {
        let payload = try copyClips(ids)
        try perform(CompoundCommand(name: "Cut", [{ _, _ in DeleteClips(clipIDs: ids) }]))
        return payload
    }

    /// Pastes `payload` at `ticks` on `track` (0 = bottom); if that overlaps, on a new top
    /// track. One undo step ("Paste"). Returns the pasted top-level clip ids.
    ///
    /// `origin` is the bundle folder the clips were copied from. When it differs from this
    /// bundle, sources whose relative `src` would not resolve here are imported from there
    /// (copied into `media/<ts>/`) and relinked in the same step.
    @discardableResult
    public func paste(_ payload: ClipboardPayload, origin: URL?, track: Int?, at ticks: Int64) async throws -> [Int64] {
        let relinks = try await crossProjectRelinks(payload, origin: origin)
        func attempt(_ builders: [CompoundCommand.Builder]) throws -> [Int64] {
            let c = CompoundCommand(name: "Paste", builders + relinks)
            try perform(c)
            return c.steps.compactMap { ($0 as? PasteClips)?.pastedIDs }.first ?? []
        }
        let t = track ?? 0
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
