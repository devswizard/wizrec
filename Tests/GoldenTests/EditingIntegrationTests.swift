import Foundation
import Testing
import TestGenKit
import TSCProjKit
import TimelineEngine

// QA-8: M2/M3 editing integration tests. Chains of TimelineEngine commands on
// generated projects and on a temp copy of the user's demo project; save and
// reopen through TSCProjKit; byte-identical undo of whole chains; lossless
// round-trip. Never writes to ~/Documents.

@Suite(.serialized) @MainActor struct EditingIntegrationTests {

    /// A new bundle with one imported synthetic movie and three sources:
    /// A (video+audio → UnifiedMedia, 60 frames), B (video only, 90 frames), C (image).
    private func generatedBundle(in dir: URL) throws -> (ProjectBundle, a: AddSource, b: AddSource, c: AddSource,
                                                         chain: EditChain) {
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("gen.cmproj"), width: 320, height: 180)
        let movie = dir.appendingPathComponent("card.mp4")
        let card = TestCard(width: 160, height: 90, label: "Q")
        _ = try MediaWriter.writeH264(to: movie, width: 160, height: 90, fps: 30, frameCount: 30) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        let src = try bundle.importFile(movie)
        let chain = EditChain(bundle.project)
        let fixed = Date(timeIntervalSince1970: 1_792_376_869)
        let a = AddSource(movieDescriptor(src: src, frames: 60, audio: true)); a.addedAt = fixed
        let b = AddSource(movieDescriptor(src: src, frames: 90, audio: false)); b.addedAt = fixed
        let c = AddSource(imageDescriptor(src: "./media/still.png")); c.addedAt = fixed
        try chain.run(a); try chain.run(b); try chain.run(c)
        return (bundle, a, b, c, chain)
    }

    // MARK: - Scripted chain on a generated project

    /// Every M2/M3 command once, in a realistic order; then a full undo/redo
    /// walk, save with backup, reopen, and undo-all back to the new project.
    @Test func scriptedChainOnGeneratedProject() throws {
        let dir = try scratchDir("edit-chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, a, b, c, chain) = try generatedBundle(in: dir)
        let sa = try #require(a.sourceID), sb = try #require(b.sourceID), sc = try #require(c.sourceID)
        #expect(Set([sa, sb, sc]).count == 3)

        // Tracks: 0 = A clips, 1 = B clips, 2 = image.
        try chain.run(AddTrack(at: 1))
        try chain.run(AddTrack(at: 2))
        #expect(chain.project.tracks.count == 3)
        let a1 = try #require(try chain.run(InsertClip(sourceID: sa, track: 0, start: 0)).clipID)
        let a2 = try #require(try chain.run(InsertClip(sourceID: sa, track: 0, start: frames(60))).clipID)
        let b1 = try #require(try chain.run(InsertClip(sourceID: sb, track: 1, start: frames(10))).clipID)
        let img = try #require(try chain.run(InsertClip(sourceID: sc, track: 2, start: frames(5))).clipID)
        let kinds = chain.project.tracks.map { $0.clips.map(\.kind) }
        #expect(kinds[0] == [.unified, .unified] && kinds[1] == [.video] && kinds[2] == [.image])
        #expect(chain.project.tracks[0].clips.map(\.duration) == [frames(60), frames(60)])

        // M2 edits.
        let split = try chain.run(SplitClip(clipID: a1, at: frames(30)))
        let a1r = try #require(split.rightID)
        try chain.run(TrimClip(clipID: a2, edge: .end, to: frames(100)))
        try chain.run(MoveClip(clipID: b1, toTrack: 1, start: frames(130)))
        try chain.run(SetParameter(clipID: b1, parameter: "translation0", value: 40))
        try chain.run(SetParameter(clipID: b1, parameter: "opacity", value: 0.5, keyframeAt: frames(15)))
        try chain.run(SetTrackFlag(track: 2, .locked, true))
        try chain.run(SetTrackFlag(track: 2, .locked, false))

        // Effects, transitions, markers.
        try chain.run(AddEffect(clipID: b1, effectJSON: EffectJSON.string(EffectJSON.roundCorners(radius: 12))))
        try chain.run(AddEffect(clipID: b1, effectJSON: EffectJSON.string(
            EffectJSON.dropShadow(angle: 45, offset: 10, blur: 5))))
        try chain.run(MoveEffect(clipID: b1, from: 1, to: 0))
        try chain.run(SetEffectParameter(clipID: b1, effectIndex: 0, parameter: "opacity", value: 0.25))
        try chain.run(SetEffectBypassed(clipID: b1, effectIndex: 1, bypassed: true))
        try chain.run(RemoveEffect(clipID: b1, index: 1))
        try chain.run(AddTransition(name: "Fade", leftClipID: a1, rightClipID: a1r, duration: frames(10)))
        try chain.run(SetTransitionDuration(leftClipID: a1, rightClipID: a1r, duration: frames(6)))
        try chain.run(AddMarker(at: frames(15), name: "Intro"))
        try chain.run(MoveMarker(from: frames(15), to: frames(20)))
        try chain.run(RenameMarker(at: frames(20), to: "Start"))
        #expect(Markers.timeline(chain.project) == [Marker(time: frames(20), name: "Start")])

        // Copy/paste, speed, extend frame.
        let payload = try ClipboardPayload.copy(clipIDs: [b1], from: chain.project)
        let paste = try chain.run(PasteClips(payload, track: 1, at: frames(300)))
        let b2 = try #require(paste.pastedIDs.first)
        try chain.run(SetClipSpeed(clipID: b2, speed: Rational(2)))
        let b2clip = try #require(chain.project.tracks[1].clips.first { $0.id == b2 })
        #expect(b2clip.duration == frames(45))
        let freeze = try chain.run(ExtendFrame(clipID: b2, duration: frames(15)))
        #expect(freeze.freezeID != nil)
        let b2s = try #require(freeze.stitchedID)  // ED1: b2 is now a segment of this StitchedMedia

        // Structure: group (with an inner edit), ungroup, stitch, unstitch, detach audio.
        try chain.run(RemoveTransition(leftClipID: a1, rightClipID: a1r))
        let group = try chain.run(GroupClips(clipIDs: [a1, a1r]))
        let g = try #require(group.groupID)
        let inner = try chain.run(SplitClip(clipID: a1, at: frames(10)))  // inner timeline ticks
        let a1m = try #require(inner.rightID)
        try chain.run(UngroupClip(clipID: g))
        #expect(chain.project.tracks[0].clips.prefix(3).map(\.id) == [a1, a1m, a1r])
        let stitch = try chain.run(StitchClips(clipIDs: [a1, a1m, a1r]))
        let s = try #require(stitch.stitchedID)
        #expect(chain.project.tracks[0].clips.first?.kind == .stitched)
        try chain.run(UnstitchClip(clipID: s))
        let detach = try chain.run(DetachAudio(clipID: a2))
        #expect(detach.videoID != nil && detach.audioID != nil)

        // Ripple edits, delete, magnetic, track removal.
        try chain.run(RippleTrim(clipID: b1, edge: .end, to: frames(150)))
        try chain.run(RippleMove(clipID: b1, toTrack: 1, start: 0))
        try chain.run(DeleteClips(clipIDs: [b2s], ripple: true))
        try chain.run(SetTrackFlag(track: 1, .magnetic, true))
        #expect(chain.project.tracks[1].clips.first?.start == 0)
        try chain.run(DeleteClips(clipIDs: [img]))
        try chain.run(RemoveTrack(at: 2))
        try chain.run(RemoveMarker(at: frames(20)))

        #expect(chain.names.count >= 40)
        try chain.expectUndoRedoWalk()

        // Save with backup and reopen: the file holds exactly the in-memory bytes.
        let onDisk = try Data(contentsOf: bundle.projectFile)
        try bundle.saveWithBackup()
        let backup = URL(fileURLWithPath: bundle.projectFile.path + ProjectBundle.backupSuffix)
        #expect(try Data(contentsOf: backup) == onDisk)
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        #expect(reopened.missingMedia().map(\.src) == ["./media/still.png"])  // the movie was imported

        // The reopened project continues the chain: a further edit undoes cleanly.
        let next = EditChain(reopened.project)
        let v = try #require(reopened.project.tracks[0].clips.first?.id)
        try next.run(SplitClip(clipID: v, at: frames(5)))
        try next.expectUndoRedoWalk()
        try next.undoAll()

        // Undo the whole original chain; the project equals the freshly created one.
        try chain.undoAll()
    }

    // MARK: - Randomised chains

    /// Seeded random command sequences on a generated project. Rejected
    /// commands must leave the project byte-identical; every applied step must
    /// keep the invariants; the whole chain must undo/redo byte-identically
    /// and survive save/reopen.
    @Test(arguments: [UInt64(1), 2, 3, 42, 2026])
    func randomisedChain(seed: UInt64) throws {
        let dir = try scratchDir("edit-fuzz")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, a, b, c, chain) = try generatedBundle(in: dir)
        try chain.run(AddTrack(at: 1))
        try chain.run(AddTrack(at: 2))
        let steps = 150
        randomEdits(chain, sources: [a, b, c].compactMap(\.sourceID), seed: seed, steps: steps)
        #expect(chain.names.count > steps / 4, "too few commands applied (\(chain.names.count))")
        let kinds = Set(chain.names)
        print("randomisedChain seed \(seed): \(chain.names.count) applied, \(chain.rejected) rejected, kinds \(kinds.sorted())")
        #expect(kinds.count >= 10, "chain exercised only \(kinds.sorted())")
        try chain.expectUndoRedoWalk()

        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        try chain.undoAll()
    }

    // MARK: - The user's demo project (temp copy; skips when absent)

    /// Edits a copy of `~/Documents/demo project.cmproj` (project file only),
    /// saves, reopens, and undoes back to the original bytes. The original is
    /// checked to be untouched.
    @Test(.enabled(if: userDemoBundle != nil, "~/Documents/demo project.cmproj not present"))
    func chainOnDemoCopy() throws {
        let original = try #require(userDemoBundle)
        let originalBytes = try Data(contentsOf: original.appendingPathComponent("project.tscproj"))
        let dir = try scratchDir("edit-demo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = try copyProjectOnly(original, into: dir)
        let bundle = try ProjectBundle(url: copy)
        let baseline = bundle.project.serialized()
        #expect(ProjectInvariants.check(bundle.project).isEmpty)
        let chain = EditChain(bundle.project)

        let groupID = try #require(bundle.project.tracks.first?.clips.first { $0.kind == .group }?.id)
        let mid = bundle.project.duration / 2
        let split = try chain.run(SplitClip(clipID: groupID, at: mid))
        let right = try #require(split.rightID)
        try chain.run(TrimClip(clipID: right, edge: .end, to: bundle.project.duration - frames(30)))
        try chain.run(MoveClip(clipID: right, toTrack: 1, start: mid + frames(15)))
        try chain.run(SetParameter(clipID: right, parameter: "opacity", value: 0.75))
        try chain.run(AddMarker(at: frames(45), name: "Demo"))
        let payload = try ClipboardPayload.copy(clipIDs: [groupID], from: bundle.project)
        let paste = try chain.run(PasteClips(payload, track: 1, at: bundle.project.duration + frames(10)))
        #expect(paste.pastedIDs.count == 1)
        // Inner edits on the (effect-laden) nested group and its unified clip.
        try chain.run(SplitClip(clipID: 7, at: frames(60)))
        try chain.run(AddTrack(at: 2))
        try chain.run(RippleMove(clipID: right, toTrack: 2, start: 0))
        try chain.run(SetClipSpeed(clipID: right, speed: Rational(3, 2)))
        try chain.run(DeleteClips(clipIDs: paste.pastedIDs, ripple: true))
        try chain.run(SetTrackFlag(track: 0, .audioMuted, true))

        try chain.expectUndoRedoWalk()
        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: copy)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)

        // Undo all, save, and the copy is byte-identical to a plain round-trip of the original.
        try chain.undoAll()
        try bundle.saveWithBackup()
        #expect(try Data(contentsOf: bundle.projectFile) == baseline)
        #expect(baseline == (try Project(data: originalBytes)).serialized())
        #expect(try Data(contentsOf: original.appendingPathComponent("project.tscproj")) == originalBytes,
                "the user's demo project changed")
    }

    /// Every top-level clip of the demo copy survives split → undo, trim →
    /// undo and move → undo with byte-identical reverts (broad smoke over real
    /// effect-laden JSON).
    @Test(.enabled(if: userDemoBundle != nil, "~/Documents/demo project.cmproj not present"))
    func everyClipReversibleOnDemoCopy() throws {
        let original = try #require(userDemoBundle)
        let dir = try scratchDir("edit-demo-all")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle(url: try copyProjectOnly(original, into: dir))
        let p = bundle.project
        var ids: [Int64] = []
        for t in p.tracks { for c in t.clips { c.walk { clip, _ in ids.append(clip.id) } } }
        #expect(ids.count >= 6)
        let before = p.serialized()
        var applied = 0
        for id in ids {
            let chain = EditChain(p)
            // Each command is built from the clip's state after the previous one.
            let cmds: [(Clip) -> any EditCommand] = [
                { SplitClip(clipID: id, at: $0.start + $0.duration / 3) },
                { TrimClip(clipID: id, edge: .end, to: $0.end - frames(3)) },
                { TrimClip(clipID: id, edge: .start, to: $0.start + frames(3)) },
                { _ in SetParameter(clipID: id, parameter: "translation1", value: 12) },
            ]
            for make in cmds {
                let clip = try #require(locateClip(id, in: p))
                let before = p.serialized()
                if chain.attempt(make(clip)) {
                    applied += 1
                    #expect(p.serialized() != before, "edit \(applied) on clip \(id) changed nothing")
                }
            }
            try chain.expectUndoRedoWalk()
            try chain.undoAll()
        }
        #expect(applied >= ids.count, "only \(applied) edits applied over \(ids.count) clips")
        #expect(p.serialized() == before)
    }

    /// Seeded random edits on the demo copy (nested group, unified clip,
    /// effects, `.trec` source): invariants, byte-identical undo/redo, save/reopen.
    @Test(.enabled(if: userDemoBundle != nil, "~/Documents/demo project.cmproj not present"),
          arguments: [UInt64(7), 99])
    func randomisedChainOnDemoCopy(seed: UInt64) throws {
        let original = try #require(userDemoBundle)
        let dir = try scratchDir("edit-demo-fuzz")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle(url: try copyProjectOnly(original, into: dir))
        let chain = EditChain(bundle.project)
        randomEdits(chain, sources: bundle.project.sourceBin.map(\.id), seed: seed, steps: 40)
        #expect(chain.names.count >= 10, "too few commands applied (\(chain.names.count))")
        try chain.expectUndoRedoWalk()
        try bundle.saveWithBackup()
        #expect(try ProjectBundle(url: bundle.directory).project.serialized() == chain.project.serialized())
        try chain.undoAll()
    }

    // MARK: - Save As and losslessness of the save path

    /// Save As on a package copies the bundle (minus backups), the copy
    /// reopens byte-identically, and later edits go to the new location only.
    @Test func saveAsThenEditKeepsBothFilesConsistent() throws {
        let dir = try scratchDir("edit-saveas")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, a, _, _, chain) = try generatedBundle(in: dir)
        let sa = try #require(a.sourceID)
        try chain.run(InsertClip(sourceID: sa, track: 0, start: 0))
        try bundle.saveWithBackup()
        try bundle.saveWithBackup()  // creates the backup that Save As must skip
        let moved = try bundle.saveAs(to: dir.appendingPathComponent("moved.cmproj"))
        let names = try FileManager.default.contentsOfDirectory(atPath: moved.directory.path)
        #expect(!names.contains { $0.hasSuffix(ProjectBundle.backupSuffix) })
        #expect(moved.missingMedia().map(\.src) == ["./media/still.png"])
        let firstFile = try Data(contentsOf: bundle.projectFile)

        let clip = try #require(moved.project.tracks[0].clips.first?.id)
        try chain.run(SplitClip(clipID: clip, at: frames(20)))
        try moved.saveWithBackup()
        #expect(try Data(contentsOf: bundle.projectFile) == firstFile, "Save As left the old file live")
        #expect(try ProjectBundle(url: moved.directory).project.serialized() == chain.project.serialized())
        try chain.expectUndoRedoWalk()
        try chain.undoAll()
    }

    /// The first save of a new project writes no backup; a second keeps the previous bytes.
    @Test func backupHoldsPreviousSave() throws {
        let dir = try scratchDir("edit-backup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, a, _, _, chain) = try generatedBundle(in: dir)
        let backup = URL(fileURLWithPath: bundle.projectFile.path + ProjectBundle.backupSuffix)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        let created = try Data(contentsOf: bundle.projectFile)
        try bundle.saveWithBackup()
        #expect(try Data(contentsOf: backup) == created)
        let saved1 = try Data(contentsOf: bundle.projectFile)
        try chain.run(InsertClip(sourceID: try #require(a.sourceID), track: 0, start: frames(3)))
        try bundle.saveWithBackup()
        #expect(try Data(contentsOf: backup) == saved1)
        #expect(try Data(contentsOf: bundle.projectFile) == chain.project.serialized())
    }
}

/// Performs `steps` seeded random edits on `chain` (rejections allowed).
@MainActor
func randomEdits(_ chain: EditChain, sources: [Int64], seed: UInt64, steps: Int) {
    var rng = SeededRandom(seed: seed)
    func randomClip(topLevel: Bool = true) -> (id: Int64, clip: Clip, track: Int)? {
        var all: [(Int64, Clip, Int)] = []
        for (ti, t) in chain.project.tracks.enumerated() {
            for clip in t.clips { all.append((clip.id, clip, ti)) }
            if !topLevel {
                for g in t.clips where g.kind == .group {
                    for it in g.tracks { for inner in it.clips { all.append((inner.id, inner, ti)) } }
                }
            }
        }
        return all.randomElement(using: &rng)
    }
    func tick(upTo n: Int64) -> Int64 { Int64.random(in: 0...max(n, 1), using: &rng) }
    func trackCount() -> Int { chain.project.tracks.count }

    for _ in 0..<steps {
        let op = Int.random(in: 0..<20, using: &rng)
        var cmd: (any EditCommand)?
        switch op {
        case 0, 1:
            if let s = sources.randomElement(using: &rng) {
                cmd = InsertClip(sourceID: s, track: Int.random(in: 0..<trackCount(), using: &rng),
                                 start: frames(tick(upTo: 400)))
            }
        case 2, 3:
            if let r = randomClip(topLevel: false) {
                cmd = SplitClip(clipID: r.id, at: r.clip.start + tick(upTo: r.clip.duration))
            }
        case 4:
            if let r = randomClip(topLevel: false) {
                let edge: TrimEdge = Bool.random(using: &rng) ? .start : .end
                cmd = TrimClip(clipID: r.id, edge: edge, to: r.clip.start + tick(upTo: r.clip.duration * 2))
            }
        case 5:
            if let r = randomClip() {
                cmd = MoveClip(clipID: r.id, toTrack: Int.random(in: 0..<trackCount(), using: &rng),
                               start: frames(tick(upTo: 400)))
            }
        case 6:
            if let r = randomClip() { cmd = DeleteClips(clipIDs: [r.id], ripple: Bool.random(using: &rng)) }
        case 7:
            if let r = randomClip() {
                cmd = RippleTrim(clipID: r.id, edge: .end, to: r.clip.start + tick(upTo: r.clip.duration * 2))
            }
        case 8:
            if let r = randomClip() {
                cmd = RippleMove(clipID: r.id, toTrack: Int.random(in: 0..<trackCount(), using: &rng),
                                 start: frames(tick(upTo: 300)))
            }
        case 9:
            if let r = randomClip(), let r2 = randomClip(), r.id != r2.id {
                cmd = GroupClips(clipIDs: [r.id, r2.id])
            }
        case 10:
            if let g = chain.project.tracks.flatMap(\.clips).filter({ $0.kind == .group })
                .randomElement(using: &rng) { cmd = UngroupClip(clipID: g.id) }
        case 11:
            if let r = randomClip() {
                let speeds = [Rational(2), Rational(1, 2), Rational(3, 2), Rational(1)]
                cmd = SetClipSpeed(clipID: r.id, speed: speeds.randomElement(using: &rng) ?? Rational(1),
                                   ripple: Bool.random(using: &rng))
            }
        case 12:
            if let r = randomClip() {
                cmd = SetParameter(clipID: r.id, parameter: "scale0", value: Double(tick(upTo: 20)) / 10,
                                   keyframeAt: Bool.random(using: &rng) ? frames(tick(upTo: 30)) : nil)
            }
        case 13:
            cmd = AddMarker(at: frames(tick(upTo: 300)), name: "M\(Int.random(in: 0..<9, using: &rng))")
        case 14:
            if let m = Markers.timeline(chain.project).randomElement(using: &rng) {
                cmd = Bool.random(using: &rng) ? RemoveMarker(at: m.time)
                    : MoveMarker(from: m.time, to: frames(tick(upTo: 300)))
            }
        case 15:
            if let r = randomClip(), let payload = try? ClipboardPayload.copy(clipIDs: [r.id], from: chain.project) {
                cmd = PasteClips(payload, track: Int.random(in: 0..<trackCount(), using: &rng),
                                 at: frames(tick(upTo: 500)))
            }
        case 16:
            // Stitch two neighbours on one track.
            if let r = randomClip(), let t = chain.project.tracks[safe: r.track],
               let i = t.clips.firstIndex(where: { $0.id == r.id }), i + 1 < t.clips.count {
                cmd = StitchClips(clipIDs: [r.id, t.clips[i + 1].id])
            }
        case 17:
            if let r = randomClip() {
                switch r.clip.kind {
                case .stitched: cmd = UnstitchClip(clipID: r.id)
                case .unified: cmd = DetachAudio(clipID: r.id)
                default: cmd = ExtendFrame(clipID: r.id, duration: frames(tick(upTo: 20) + 1))
                }
            }
        case 18:
            if trackCount() < 6, Int.random(in: 0..<3, using: &rng) == 0 {
                cmd = AddTrack(at: Int.random(in: 0...trackCount(), using: &rng))
            } else {
                cmd = SetTrackFlag(track: Int.random(in: 0..<trackCount(), using: &rng),
                                   [TrackFlag.magnetic, .audioMuted, .videoHidden].randomElement(using: &rng)
                                       ?? .magnetic, Bool.random(using: &rng))
            }
        default:
            if let r = randomClip(), let l = chain.project.tracks[safe: r.track],
               let i = l.clips.firstIndex(where: { $0.id == r.id }), i + 1 < l.clips.count,
               l.clips[i].end == l.clips[i + 1].start {
                cmd = AddTransition(name: "Fade", leftClipID: r.id, rightClipID: l.clips[i + 1].id,
                                    duration: frames(tick(upTo: 5) + 1))
            }
        }
        if let cmd { chain.attempt(cmd) }
    }
}

/// Finds a clip anywhere in the tree (top level, groups, unified halves, stitched segments).
@MainActor
func locateClip(_ id: Int64, in project: Project) -> Clip? {
    var found: Clip?
    for t in project.tracks {
        for c in t.clips { c.walk { clip, _ in if clip.id == id, found == nil { found = clip } } }
    }
    return found
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
