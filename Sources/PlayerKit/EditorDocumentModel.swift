import AudioEngine
import Foundation
import MediaEngine
import Observation
import RenderEngine
import TimelineEngine
import TSCProjKit
import WizRecAssets

/// A source-bin entry whose file is not on this machine.
public struct MissingMedia: Sendable, Equatable, Identifiable {
    /// Source-bin id.
    public var id: Int64
    /// `src` as written in the project.
    public var src: String
    /// Where we looked for it.
    public var path: String
}

/// Errors of the editor document that the UI shows as text.
public enum DocumentError: Error, Equatable, CustomStringConvertible {
    case unsupportedMedia(String)
    case noRoom(String)
    case noSuchSource(Int64)

    public var description: String {
        switch self {
        case .unsupportedMedia(let s):
            String(localized: "WizRec can’t read “\(s)”. The file may be damaged, or its format isn’t supported.")
        case .noRoom(let s): s
        case .noSuchSource(let id): "Source \(id) is not in the project."
        }
    }
}

/// One open project in the editor: bundle, undo history, dirty state, render scene and
/// media pools. Lives on the main actor (TSCProjKit types are not `Sendable`).
///
/// Every change to the project goes through TimelineEngine commands on `undo`; after
/// each change `scene` and `missing` are rebuilt and `onChange` fires. The bundle is
/// written only by `save()` / `saveAs(to:)`.
@MainActor @Observable
public final class EditorDocumentModel {
    public private(set) var bundle: ProjectBundle
    public var project: Project { bundle.project }
    public let undo: UndoStack
    /// Immutable projection of the project for rendering; rebuilt after every change.
    public private(set) var scene: SceneModel
    /// The project's audio for the player's `AudioMixer`; rebuilt with `scene`.
    public private(set) var audioScene: AudioScene
    public private(set) var missing: [MissingMedia]
    /// Dirty state relative to the last save.
    public private(set) var tracker = ChangeTracker()
    /// Bumps on every project change (edit, preview step, save-as reload).
    public private(set) var revision = 0
    /// Decoded-frame pool for playback. One per document. HDR sources are tone-mapped on the
    /// GPU (`.gpu`, for 4K60 HDR); export uses its own `.cpu` pool (the reference).
    @ObservationIgnored public let pool: MediaPool
    /// Separate pool for bin and filmstrip thumbnails, so they never move playback decoders.
    @ObservationIgnored public let thumbnailPool: MediaPool
    /// Called after every project change (scene already rebuilt) — e.g. to swap the
    /// player's scene and refresh the window's edited state.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// True for a new project living in a temporary folder until its first Save As.
    public private(set) var isUntitled: Bool

    @ObservationIgnored private var seenChangeCount = 0
    @ObservationIgnored private var pending: (command: any EditCommand, changes: [ParameterChange])?

    public init(url: URL, cacheLimitBytes: Int = 768 << 20) throws {
        let bundle = try ProjectBundle(url: url)
        self.bundle = bundle
        undo = UndoStack(project: bundle.project)
        scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        audioScene = AudioScene(project: bundle.project, resolve: bundle.resolve)
        missing = Self.findMissing(bundle)
        pool = MediaPool(cacheLimitBytes: cacheLimitBytes, hdrToneMapping: .gpu)
        thumbnailPool = MediaPool(cacheLimitBytes: 64 << 20)
        isUntitled = false
        observeUndo()
    }

    /// A new, empty project (format 10.0, `width`×`height` at `fps`) in a temporary folder.
    /// It becomes a real file on its first `saveAs(to:)`; `discardUntitled()` deletes it.
    public static func untitled(width: Int = 1920, height: Int = 1080, fps: Int = 30,
                                in parent: URL = FileManager.default.temporaryDirectory) throws -> EditorDocumentModel {
        let dir = parent.appendingPathComponent("WizRec-Untitled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Untitled.cmproj", isDirectory: true)
        do {
            _ = try ProjectBundle.create(at: url, width: width, height: height, fps: fps)
            let m = try EditorDocumentModel(url: url)
            m.isUntitled = true
            return m
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Deletes the temporary folder of an untitled project (on close without saving).
    public func discardUntitled() {
        guard isUntitled else { return }
        let dir = bundle.directory.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix("WizRec-Untitled-") { try? FileManager.default.removeItem(at: dir) }
    }

    /// Output sample rate for playback, Hz: the project's `audioFormatSampleRate`, or, when the
    /// project has no usable rate, the rate export mixes it at (`MixFormat`'s 48 kHz), so playback
    /// and export mix (and measure unmeasured sources) at the same rate.
    public var audioSampleRate: Double {
        audioScene.sampleRate.map { $0.rounded() } ?? MixFormat().sampleRate
    }

    /// A playback engine for this document; `audio` false plays silently on the host clock.
    /// Swap its scene with `engine.replaceScene(model.scene, audioScene: model.audioScene)` from `onChange`.
    public func makeEngine(audio: Bool = true) -> PlaybackEngine {
        let player = audio ? AudioPlayback(scene: scene, audioScene: audioScene, pool: pool, sampleRate: audioSampleRate) : nil
        return PlaybackEngine(scene: scene, pool: pool, audio: player)
    }

    public var isDirty: Bool { tracker.isDirty }

    /// Absolute URL of a source.
    public func url(of source: SourceMedia) -> URL { bundle.resolve(source) }

    // MARK: Edits

    /// Performs `command` as one undo step.
    public func perform(_ command: any EditCommand) throws {
        endPreview()
        try undo.perform(command)
        tracker.performed()
        seenChangeCount = undo.changeCount
        projectChanged()
    }

    public func undoLast() throws {
        endPreview()
        guard undo.canUndo else { return }
        try undo.undo()
        tracker.undid()
        seenChangeCount = undo.changeCount
        projectChanged()
    }

    public func redoLast() throws {
        endPreview()
        guard undo.canRedo else { return }
        try undo.redo()
        tracker.redid()
        seenChangeCount = undo.changeCount
        projectChanged()
    }

    /// Picks up commands performed directly on `undo` (the timeline view performs its
    /// gestures there). Runs automatically via observation; safe to call any time.
    public func syncWithUndoStack() {
        let delta = undo.changeCount - seenChangeCount
        guard delta > 0 else { return }
        seenChangeCount = undo.changeCount
        tracker.performed(count: delta)
        projectChanged()
    }

    private func observeUndo() {
        let stack = undo
        withObservationTracking { _ = stack.changeCount } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncWithUndoStack()
                self.observeUndo()
            }
        }
    }

    // MARK: Live parameter preview

    /// One parameter assignment of an inspector edit.
    public struct ParameterChange: Equatable, Sendable {
        public var clipID: Int64
        public var name: String
        public var value: Double
        /// Clip media time (ticks) of the keyframe to set, or nil for a constant.
        public var keyframeAt: Int64?
        /// True for a shader background's `sourceEffect` parameter (`SetSourceEffectParameters`)
        /// rather than the clip's own `parameters`.
        public var isSourceEffect = false
        public init(clipID: Int64, _ name: String, _ value: Double, keyframeAt: Int64? = nil) {
            self.clipID = clipID; self.name = name; self.value = value; self.keyframeAt = keyframeAt
        }

        /// A shader background `sourceEffect` change (`ShaderInspection.changes`).
        public static func sourceEffect(clipID: Int64, _ change: SourceEffectChange) -> ParameterChange {
            var c = ParameterChange(clipID: clipID, change.name, change.value, keyframeAt: change.keyframeAt)
            c.isSourceEffect = true
            return c
        }
    }

    /// Shows `changes` without an undo step (inspector drag in progress). Each call
    /// replaces the previous preview; `commitPreview` makes the last one one undo step.
    public func preview(_ changes: [ParameterChange]) throws {
        endPreview()
        let c = Self.command(for: changes)
        try c.apply(to: project)
        pending = (c, changes)
        projectChanged(light: true)
    }

    /// Turns the current preview into one undo step ("Change Property").
    public func commitPreview() throws {
        guard let p = pending else { return }
        try p.command.revert(on: project)
        pending = nil
        try perform(Self.command(for: p.changes))
    }

    /// Applies `changes` at once as one undo step (typed values, steppers).
    public func set(_ changes: [ParameterChange]) throws {
        try perform(Self.command(for: changes))
    }

    /// Drops the current preview, restoring the project.
    public func cancelPreview() {
        guard pending != nil else { return }
        endPreview()
        projectChanged(light: true)
    }

    public var isPreviewing: Bool { pending != nil }

    private func endPreview() {
        guard let p = pending else { return }
        try? p.command.revert(on: project)
        pending = nil
    }

    private static func command(for changes: [ParameterChange]) -> any EditCommand {
        // Volume keyframes are audio points: Camtasia's point shape, not eased windows.
        var steps: [any EditCommand] = []
        // Background parameters of one clip go in one SetSourceEffectParameters (e.g. a colour's 4 channels).
        var clips: [Int64] = []
        for ch in changes where ch.isSourceEffect && !clips.contains(ch.clipID) { clips.append(ch.clipID) }
        for id in clips {
            let mine: [SourceEffectChange] = changes.filter { $0.isSourceEffect && $0.clipID == id }.map {
                SourceEffectChange($0.name, $0.value, keyframeAt: $0.keyframeAt)
            }
            steps.append(SetSourceEffectParameters(clipID: id, changes: mine))
        }
        steps += changes.filter { !$0.isSourceEffect }.map { (ch: ParameterChange) -> any EditCommand in
            if ch.name == "volume", let at = ch.keyframeAt {
                return SetVolumePoint(clipID: ch.clipID, at: at, value: ch.value)
            }
            return SetParameter(clipID: ch.clipID, parameter: ch.name, value: ch.value, keyframeAt: ch.keyframeAt)
        }
        if steps.count == 1, let only = steps.first { return only }
        return CompoundCommand(name: "Change Property", steps.map { s in { _, _ in s } })
    }

    private func projectChanged(light: Bool = false) {
        scene = SceneModel(project: project, resolve: bundle.resolve)
        audioScene = AudioScene(project: project, resolve: bundle.resolve)
        if !light { missing = Self.findMissing(bundle) }
        revision += 1
        onChange?()
    }

    private static func findMissing(_ bundle: ProjectBundle) -> [MissingMedia] {
        bundle.missingMedia().map { MissingMedia(id: $0.id, src: $0.src, path: bundle.resolve($0).path) }
    }

    // MARK: Saving

    /// Saves in place with a backup of the previous `project.tscproj`.
    public func save() throws {
        endPreview()
        try bundle.saveWithBackup()
        tracker.saved()
    }

    /// Writes the project to `url` and continues editing there (`ProjectBundle.saveAs`).
    ///
    /// `.cmproj`: the package (media included) is copied to `url`. A bare `.tscproj`
    /// writes only the file, so relative media paths may stop resolving: the result is
    /// the sources missing after the move that were present before (warn the user).
    /// `url` must not exist (the caller removes a file the user chose to replace).
    /// Undo history is kept.
    @discardableResult
    public func saveAs(to url: URL) throws -> [MissingMedia] {
        endPreview()
        let before = Set(missing.map(\.id))
        let wasUntitled = isUntitled
        let oldTemp = bundle.directory.deletingLastPathComponent()
        bundle = try bundle.saveAs(to: url)
        tracker.saved()
        isUntitled = false
        projectChanged()
        if wasUntitled, oldTemp.lastPathComponent.hasPrefix("WizRec-Untitled-") {
            try? FileManager.default.removeItem(at: oldTemp)
        }
        return missing.filter { !before.contains($0.id) }
    }

    // MARK: Import

    /// Copies `file` into the bundle (`media/<ts>/`), probes it and adds it to the source
    /// bin as one undo step. Returns the new source id. Unsupported files are not copied.
    @discardableResult
    public func importMedia(_ file: URL) async throws -> Int64 {
        let info: MediaInfo
        do { info = try await thumbnailPool.probe(file) } catch {
            throw DocumentError.unsupportedMedia(file.lastPathComponent)
        }
        guard info.kind != .unknown, info.kind == .image || info.kind == .shader || !info.streams.isEmpty else {
            throw DocumentError.unsupportedMedia(file.lastPathComponent)
        }
        let src = try bundle.importFile(file)
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let loudness = await measureLoudness(info: info, src: src)
        let d = SourceDescriptor(info: info, src: src, lastModified: date)
        let shader = ShaderSourceImport.entries(info: info, url: file)
        let c = CompoundCommand(name: "Import Media", [{ _, _ in AddSource(d) }] + Self.loudnessSteps(addIndex: 0, loudness)
                                + ShaderSourceImport.steps(addIndex: 0, shader))
        try perform(c)
        guard let id = (c.steps.first as? AddSource)?.sourceID else { throw EditError.invalid("AddSource returned no id") }
        return id
    }

    /// Loudness of each audio stream of an imported file (`src` in the bundle), measured the way
    /// Camtasia fills `sourceTracks[i].integratedLUFS` / `peakLevel` (`SourceLoudness`), with the
    /// stream index (= source track). Streams that cannot be measured are left out; their tracks
    /// keep `AddSource`'s placeholders (100 / -1), which mean "not measured".
    func measureLoudness(info: MediaInfo, src: String) async -> [(track: Int, loudness: SourceLoudness)] {
        let url = bundle.directory.appendingPathComponent(src).standardizedFileURL
        let rate = Self.loudnessRate(projectRate: audioScene.sampleRate)
        var out: [(track: Int, loudness: SourceLoudness)] = []
        for s in info.streams where s.kind == .audio {
            if let m = try? await SourceLoudness.measure(pool: thumbnailPool, url: url, stream: s.index, mixRate: rate) {
                out.append((s.index, m))
            }
        }
        return out
    }

    /// Rate (Hz) import measures loudness at: the project's `audioFormatSampleRate`, or, when the
    /// project has no usable rate, the rate such a project is mixed at (`MixFormat`'s 48 kHz, the
    /// export fallback), which is the rate `AudioMixer` measures unmeasured sources at then
    /// [WizRec, audio.md §2.1]. Stored and on-the-fly values thus match.
    static func loudnessRate(projectRate: Double?) -> Double {
        projectRate ?? MixFormat().sampleRate
    }

    /// `SetSourceLoudness` steps for the source added by step `addIndex` of the same compound.
    static func loudnessSteps(addIndex: Int, _ loudness: [(track: Int, loudness: SourceLoudness)]) -> [CompoundCommand.Builder] {
        loudness.map { m in
            { _, done in
                guard let id = (done[addIndex] as? AddSource)?.sourceID else { throw EditError.invalid("no source id") }
                return SetSourceLoudness(sourceID: id, track: m.track, integratedLUFS: m.loudness.integratedLUFS,
                                         peakLevel: m.loudness.peakLevel)
            }
        }
    }

    /// Imports `file` and places it at `ticks` (track preference as in `insertSource`), as one undo step.
    @discardableResult
    public func importAndInsert(_ file: URL, at ticks: Int64, track: Int? = nil) async throws -> Int64 {
        guard let id = try await importAndPlace([file], at: ticks, track: track, name: "Add to Timeline").first else {
            throw EditError.invalid("no clip id")
        }
        return id
    }

    /// What `importInSequence` did: the clips placed (id and track index, in file order) and the
    /// files that failed with their errors.
    public struct SequencedImport {
        public var placed: [(clip: Int64, track: Int)] = []
        public var failures: [(file: URL, error: any Error)] = []
    }

    /// Imports `files` one after another. With `place`, each goes onto the timeline back to back
    /// from `ticks` (the next one starts where the previous clip ends; track preference as in
    /// `insertSource`), one undo step per file; without, into the media bin only. A file that
    /// fails is skipped and the rest continue.
    public func importInSequence(_ files: [URL], place: Bool, from ticks: Int64, track: Int? = nil) async -> SequencedImport {
        var out = SequencedImport()
        var t = ticks
        for file in files {
            do {
                guard place else { _ = try await importMedia(file); continue }
                let clip = try await importAndInsert(file, at: t, track: track)
                for (i, tr) in project.tracks.enumerated() {
                    guard let c = tr.clips.first(where: { $0.id == clip }) else { continue }
                    t = c.end
                    out.placed.append((clip, i))
                    break
                }
            } catch {
                out.failures.append((file, error))
            }
        }
        return out
    }

    /// Imports `files` and places them all at `ticks`, each on the next free track (the first
    /// on `track` when free), stacking upward: e.g. a recording's screen, camera and audio.
    /// One undo step named `name`. Returns the clip ids in `files` order. Files already inside
    /// the bundle (a recording written to `recordings/<ts>/`) are referenced, not copied.
    @discardableResult
    public func importAndPlace(_ files: [URL], at ticks: Int64, track: Int? = nil,
                               name: String) async throws -> [Int64] {
        var descriptors: [SourceDescriptor] = []
        var measured: [[(track: Int, loudness: SourceLoudness)]] = []
        var shaders: [[ShaderEffectDefEntry]?] = []
        for file in files {
            let info: MediaInfo
            do { info = try await thumbnailPool.probe(file) } catch {
                throw DocumentError.unsupportedMedia(file.lastPathComponent)
            }
            // As in importMedia: a file with nothing to show or play is no media.
            guard info.kind != .unknown, info.kind == .image || info.kind == .shader || !info.streams.isEmpty else {
                throw DocumentError.unsupportedMedia(file.lastPathComponent)
            }
            let src = try bundle.importFile(file)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            descriptors.append(SourceDescriptor(info: info, src: src, lastModified: date))
            measured.append(await measureLoudness(info: info, src: src))
            shaders.append(ShaderSourceImport.entries(info: info, url: file))
        }
        let editRate = project.timebase.editRate
        var builders: [CompoundCommand.Builder] = []
        for (i, d) in descriptors.enumerated() {
            let addIndex = builders.count
            builders.append { _, _ in AddSource(d) }
            builders += Self.loudnessSteps(addIndex: addIndex, measured[i])
            builders += ShaderSourceImport.steps(addIndex: addIndex, shaders[i])
            builders.append { project, done in
                guard let id = (done[addIndex] as? AddSource)?.sourceID else { throw EditError.invalid("no source id") }
                // Placement is decided when the step is first applied, after earlier files took their tracks.
                let place = Placement.find(in: project, start: ticks, duration: d.naturalDuration(editRate: editRate),
                                           preferred: i == 0 ? track : nil)
                var steps: [CompoundCommand.Builder] = []
                if place.needsNewTrack { steps.append { _, _ in AddTrack(at: place.track) } }
                steps.append { _, _ in InsertClip(sourceID: id, track: place.track, start: ticks) }
                return CompoundCommand(name: name, steps)
            }
        }
        let c = CompoundCommand(name: name, builders)
        try perform(c)
        return try c.steps.compactMap { $0 as? CompoundCommand }.map { place in
            guard let id = (place.steps.last as? InsertClip)?.clipID else { throw EditError.invalid("no clip id") }
            return id
        }
    }

    /// Places one of WizRec's own backgrounds (`AssetCatalog.backgrounds`) at `ticks`: its
    /// `.tscshadervid` is written into the bundle (`media/<ts>/<id>.tscshadervid`) and placed like
    /// an imported file, with the source's `effectDef` and the clip's `sourceEffect` at the
    /// background's defaults (60 s, `shader-backgrounds.md` §6, SH2). One undo step; returns the clip id.
    @discardableResult
    public func placeBackground(_ background: BackgroundAsset, at ticks: Int64, track: Int? = nil) async throws -> Int64 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent(background.fileName)
        try background.shaderVidData().write(to: file, options: .atomic)
        guard let id = try await importAndPlace([file], at: ticks, track: track,
                                                name: String(localized: "Add Background")).first else {
            throw EditError.invalid("no clip id")
        }
        return id
    }

    /// Root of WizRec's background library on disk (default `~/Library/Application Support/WizRec`).
    /// A library background placed into a Rev group is written to `<root>/backgrounds/<id>.tscshadervid`
    /// first, so the clip's `metadata.ShaderVidSource` names a lasting file, as Camtasia's names its
    /// own library file (`shader-backgrounds.md` §1).
    @ObservationIgnored public var backgroundLibraryRoot = EditorDocumentModel.defaultBackgroundLibraryRoot

    /// `~/Library/Application Support/WizRec`.
    public nonisolated static var defaultBackgroundLibraryRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WizRec", isDirectory: true)
    }

    /// The library file of `background` under `backgroundLibraryRoot`, (re)written when missing or stale.
    func libraryFile(for background: BackgroundAsset) throws -> URL {
        let dir = backgroundLibraryRoot.appendingPathComponent("backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(background.fileName)
        let data = try background.shaderVidData()
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        return file
    }

    /// Places one of WizRec's backgrounds on inner track `track` of group `groupID` at `innerTicks`
    /// (the group's inner timeline), imported like a dropped file. On inner track 0 of a Rev group
    /// (`metadata.groupType` "revMedia") the clip also gets `metadata.ShaderVidSource` (the library
    /// file's path) and the group `metadata.RevBackground` (`backgrounds/<file>`), as in Camtasia's
    /// demo save; anywhere else neither is written [WizRec, DECISIONS 2026-10-20]. One undo step
    /// ("Add Background"); returns the clip id.
    @discardableResult
    public func placeBackground(_ background: BackgroundAsset, inGroup groupID: Int64, track: Int = 0,
                                at innerTicks: Int64) async throws -> Int64 {
        let file = try libraryFile(for: background)
        let origin: (path: String, rev: String)? = track == 0 && Self.isRevGroup(groupID, in: project)
            ? (path: file.path, rev: "backgrounds/" + background.fileName) : nil
        let ids = try await placeInGroup(.files([file]), group: groupID, track: track, at: innerTicks,
                                         name: String(localized: "Add Background"), origin: origin)
        guard let id = ids.first else { throw EditError.invalid("no clip id") }
        return id
    }

    /// Library double-click with group `groupID` open: the background at project time `playhead`
    /// mapped onto the group's inner timeline (floored to a tick, not clamped: outside the group's
    /// window the clip is kept there, hidden), on a new top inner track. The group never grows
    /// (group-edits §8.6; like a drop above the inner tracks and Camtasia's "new top track at the
    /// playhead" placement). Being on a new top track, it gets no Rev keys. One undo step; returns
    /// the clip id.
    @discardableResult
    public func placeBackground(_ background: BackgroundAsset, inGroup groupID: Int64,
                                atPlayhead playhead: Int64) async throws -> Int64 {
        let inner = try GroupTiming.innerTime(group: groupID, timeline: playhead, in: project)
        let num: Int64 = inner.num, den: Int64 = max(inner.den, 1)
        let ticks: Int64 = num >= 0 ? num / den : (num - den + 1) / den   // floor
        guard let count = Self.innerTrackCount(groupID, in: project) else { throw EditError.invalid("no group \(groupID)") }
        return try await placeBackground(background, inGroup: groupID, track: count, at: ticks)
    }

    /// Number of inner tracks of group `groupID` (anywhere); nil when there is no such group.
    static func innerTrackCount(_ groupID: Int64, in project: Project) -> Int? {
        var count: Int?
        for t in project.tracks {
            for c in t.clips {
                c.walk { inner, _ in
                    if count == nil, inner.id == groupID, inner.kind.typeName == "Group" { count = inner.tracks.count }
                }
            }
        }
        return count
    }

    /// True when clip `groupID` (anywhere) is a group with `metadata.groupType` "revMedia".
    static func isRevGroup(_ groupID: Int64, in project: Project) -> Bool {
        var rev = false
        for t in project.tracks {
            for c in t.clips {
                c.walk { inner, _ in
                    if inner.id == groupID, inner.kind.typeName == "Group",
                       inner.metadata?["groupType"]?.string == "revMedia" { rev = true }
                }
            }
        }
        return rev
    }

    /// Places source `sourceID` at `ticks`: on `track` when free there, else the lowest free
    /// track, else a new track on top. One undo step. Returns the clip id.
    @discardableResult
    public func insertSource(_ sourceID: Int64, at ticks: Int64, track: Int? = nil) throws -> Int64 {
        guard let source = project.source(id: sourceID) else { throw DocumentError.noSuchSource(sourceID) }
        let duration = Placement.naturalDuration(of: source, editRate: project.timebase.editRate)
        let place = Placement.find(in: project, start: ticks, duration: duration, preferred: track)
        var builders: [CompoundCommand.Builder] = []
        if place.needsNewTrack { builders.append { _, _ in AddTrack(at: place.track) } }
        builders.append { _, _ in InsertClip(sourceID: sourceID, track: place.track, start: ticks) }
        let c = CompoundCommand(name: "Add to Timeline", builders)
        try perform(c)
        guard let clip = c.steps.last as? InsertClip, let id = clip.clipID else { throw EditError.invalid("no clip id") }
        return id
    }

    // MARK: Placing inside an open group

    /// What goes into a group: bin sources, or files to import first.
    public enum GroupPlacement: Sendable, Equatable {
        case sources([Int64])
        case files([URL])
    }

    /// Places `items` on inner track `track` of group `groupID`, the first at `innerTicks`
    /// (ticks on the group's inner timeline), each next one where the previous ends. Files are
    /// imported into the bin in the same step. One undo step; returns the new clip ids in order.
    @discardableResult
    public func placeInGroup(_ items: GroupPlacement, group groupID: Int64, track: Int,
                             at innerTicks: Int64) async throws -> [Int64] {
        try await placeInGroup(items, group: groupID, track: track, at: innerTicks, name: "Add to Group", origin: nil)
    }

    /// `placeInGroup` named `name`; `origin` adds `SetShaderVidSource` for the first clip (Rev backgrounds).
    private func placeInGroup(_ items: GroupPlacement, group groupID: Int64, track: Int, at innerTicks: Int64,
                              name: String, origin: (path: String, rev: String)?) async throws -> [Int64] {
        var builders: [CompoundCommand.Builder] = []
        var inserts: [Int] = []
        switch items {
        case .sources(let ids):
            for id in ids {
                guard project.source(id: id) != nil else { throw DocumentError.noSuchSource(id) }
                inserts.append(builders.count)
                builders.append(Self.groupInsert(group: groupID, track: track, first: innerTicks,
                                                 previous: inserts.dropLast().last) { _ in id })
            }
        case .files(let files):
            for file in files {
                let info: MediaInfo
                do { info = try await thumbnailPool.probe(file) } catch {
                    throw DocumentError.unsupportedMedia(file.lastPathComponent)
                }
                guard info.kind != .unknown, info.kind == .image || info.kind == .shader || !info.streams.isEmpty else {
                    throw DocumentError.unsupportedMedia(file.lastPathComponent)
                }
                let src = try bundle.importFile(file)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                let d = SourceDescriptor(info: info, src: src, lastModified: date)
                let loudness = await measureLoudness(info: info, src: src)
                let addIndex = builders.count
                builders.append { _, _ in AddSource(d) }
                builders += Self.loudnessSteps(addIndex: addIndex, loudness)
                builders += ShaderSourceImport.steps(
                    addIndex: addIndex, ShaderSourceImport.entries(info: info, url: file))
                inserts.append(builders.count)
                builders.append(Self.groupInsert(group: groupID, track: track, first: innerTicks,
                                                 previous: inserts.dropLast().last) { done in
                    guard let id = (done[addIndex] as? AddSource)?.sourceID else { throw EditError.invalid("no source id") }
                    return id
                })
            }
        }
        guard !builders.isEmpty else { return [] }
        if let origin, let first = inserts.first {
            builders.append { _, done in
                guard let id = (done[first] as? InsertClipInGroup)?.clipID else { throw EditError.invalid("no clip id") }
                return SetShaderVidSource(clipID: id, path: origin.path, revBackground: origin.rev)
            }
        }
        let c = CompoundCommand(name: name, builders)
        try perform(c)
        return try inserts.map { i in
            guard let id = (c.steps[i] as? InsertClipInGroup)?.clipID else { throw EditError.invalid("no clip id") }
            return id
        }
    }

    /// One `InsertClipInGroup` step: at `first`, or at the end of the clip inserted by step `previous`.
    private static func groupInsert(group: Int64, track: Int, first: Int64, previous: Int?,
                                    source: @escaping @MainActor ([any EditCommand]) throws -> Int64)
        -> CompoundCommand.Builder {
        { project, done in
            var start = first
            if let p = previous, let prev = (done[p] as? InsertClipInGroup)?.clipID,
               let end = innerClipEnd(prev, in: project) {
                start = end
            }
            return InsertClipInGroup(sourceID: try source(done), group: group, track: track, at: .inner(start))
        }
    }

    /// End (inner ticks) of clip `id` nested anywhere in a group.
    static func innerClipEnd(_ id: Int64, in project: Project) -> Int64? {
        var end: Int64?
        for t in project.tracks {
            for c in t.clips {
                c.walk { inner, depth in if depth > 0, inner.id == id, end == nil { end = inner.end } }
            }
        }
        return end
    }

    // MARK: Relink

    /// Points source `sourceID` at `file` (no copy). `src` becomes bundle-relative
    /// (`./…`) when `file` is inside the bundle folder, else an absolute path.
    public func relink(_ sourceID: Int64, to file: URL) async throws {
        try perform(try await relinkCommand(sourceID, to: file))
    }

    /// Relinks every missing source that has a same-named file under `folder` (one undo
    /// step). Returns the ids relinked.
    @discardableResult
    public func relinkAll(in folder: URL) async throws -> [Int64] {
        let matches = RelinkMatcher.matches(for: missing, in: folder)
        var commands: [RelinkSource] = []
        for m in missing { if let file = matches[m.id] { commands.append(try await relinkCommand(m.id, to: file)) } }
        guard !commands.isEmpty else { return [] }
        try perform(CompoundCommand(name: "Relink Media", commands.map { c in { _, _ in c } }))
        return commands.map(\.sourceID)
    }

    private func relinkCommand(_ sourceID: Int64, to file: URL) async throws -> RelinkSource {
        guard project.source(id: sourceID) != nil else { throw DocumentError.noSuchSource(sourceID) }
        let info: MediaInfo
        do { info = try await thumbnailPool.probe(file) } catch {
            throw DocumentError.unsupportedMedia(file.lastPathComponent)
        }
        let src = Self.projectPath(for: file, bundleDirectory: bundle.directory)
        return RelinkSource(sourceID: sourceID, to: SourceDescriptor(info: info, src: src))
    }

    /// `./relative/path` inside `bundleDirectory`, else the absolute path.
    nonisolated public static func projectPath(for file: URL, bundleDirectory: URL) -> String {
        let f = file.standardizedFileURL.resolvingSymlinksInPath().path
        let d = bundleDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = d.hasSuffix("/") ? d : d + "/"
        return f.hasPrefix(prefix) ? "./" + f.dropFirst(prefix.count) : f
    }
}

/// Where a new clip goes on the timeline.
public struct Placement: Equatable, Sendable {
    /// Index into the scene's tracks (0 = bottom).
    public var track: Int
    /// True when `track` does not exist yet (add it first).
    public var needsNewTrack: Bool

    /// `preferred` when [start, start+duration) is free there, else the lowest free track,
    /// else a new track above the others.
    @MainActor
    public static func find(in project: Project, start: Int64, duration: Int64, preferred: Int?) -> Placement {
        let tracks = project.tracks
        func free(_ i: Int) -> Bool {
            let end = start + max(1, duration)
            return !tracks[i].clips.contains { $0.start < end && start < $0.end }
        }
        if let p = preferred, tracks.indices.contains(p), free(p) { return Placement(track: p, needsNewTrack: false) }
        if let i = tracks.indices.first(where: free) { return Placement(track: i, needsNewTrack: false) }
        return Placement(track: tracks.count, needsNewTrack: true)
    }

    /// Length of a source placed at speed 1, ticks: its longest audio/video track; images 5 s [?];
    /// shader backgrounds (an endless video track) 60 s [obs, shader-backgrounds.md SH2].
    @MainActor
    public static func naturalDuration(of source: SourceMedia, editRate: Int64, stillSeconds: Double = 5,
                                       shaderSeconds: Double = 60) -> Int64 {
        let seconds = source.tracks.compactMap { t -> Double? in
            guard t.type != 1, let r = t.range.last, r < Int64.max / 2, t.editRate > 0, r > 0 else { return nil }
            return t.durationSeconds
        }.max()
        let endless = source.tracks.contains { t in t.type == 0 && (t.range.last ?? 0) >= Int64.max / 2 }
        return Int64(((seconds ?? (endless ? shaderSeconds : stillSeconds)) * Double(editRate)).rounded())
    }
}

/// Finds replacement files for missing media in a folder (projects from another Mac or PC).
public enum RelinkMatcher {
    /// For each missing source, the file under `folder` (recursive, up to `limit` files) with
    /// the same name, case-insensitive. Among several, the one sharing the most trailing
    /// path components with `src` wins (Windows `\` separators understood).
    public static func matches(for missing: [MissingMedia], in folder: URL, limit: Int = 50_000) -> [Int64: URL] {
        var byName: [String: [URL]] = [:]
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles])
        var n = 0
        while let u = e?.nextObject() as? URL, n < limit {
            n += 1
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            byName[u.lastPathComponent.lowercased(), default: []].append(u)
        }
        var out: [Int64: URL] = [:]
        for m in missing {
            let parts = components(m.src)
            guard let name = parts.last, let candidates = byName[name] else { continue }
            out[m.id] = candidates.max { score($0, parts) < score($1, parts) }
        }
        return out
    }

    static func components(_ src: String) -> [String] {
        src.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .map { $0.lowercased() }.filter { $0 != "." && !$0.isEmpty }
    }

    private static func score(_ u: URL, _ parts: [String]) -> Int {
        let c = u.pathComponents.map { $0.lowercased() }
        var k = 0
        while k < min(c.count, parts.count), c[c.count - 1 - k] == parts[parts.count - 1 - k] { k += 1 }
        return k
    }
}
