import AudioEngine
import Foundation
import MediaEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// Wave B integration: TimelineEngine edits ↔ AudioMixer output, loudness
// normalisation of a WizRec-made project, determinism across save/reopen.
// Synthetic media only (TestGenKit pink noise); nothing from the user.

/// Samples per 30 fps frame at 48 kHz.
private let samplesPerFrame = 1600

@MainActor
private struct AudioFixture {
    let bundle: ProjectBundle
    let chain: EditChain
    let sourceID: Int64
    let clipID: Int64
    /// The signal written to the WAV (mono, 48 kHz).
    let signal: [Float]

    /// New project with `seconds` of mono pink noise at `lufs` (mono measure) on track 0 at 0.
    init(in dir: URL, seconds: Double = 4, lufs: Double = -26, peakLimit: Double = -12) throws {
        bundle = try ProjectBundle.create(at: dir.appendingPathComponent("audio.cmproj"))
        signal = AudioSignals.pinkNoise(seconds: seconds, lufs: lufs, peakLimit: peakLimit)
        let wav = dir.appendingPathComponent("pink.wav")
        try AudioSignals.writeWAV(signal, to: wav)
        let src = try bundle.importFile(wav)
        let setup = EditChain(bundle.project)
        let add = AddSource(SourceDescriptor(src: src, lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: Int64(signal.count), width: 0, height: 0,
                  sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        add.addedAt = Date(timeIntervalSince1970: 1_792_376_869)
        try setup.run(add)
        sourceID = try #require(add.sourceID)
        clipID = try #require(try setup.run(InsertClip(sourceID: sourceID, track: 0, start: 0)).clipID)
        // Edits under test start from here, so undo-all returns to this state.
        chain = EditChain(bundle.project)
    }

    /// Mixes `range` (default: the whole timeline) with a fresh mixer and pool.
    func mix(_ range: Range<Int64>? = nil, of project: Project? = nil) async throws -> PCMBuffer {
        let p = project ?? bundle.project
        let scene = AudioScene(project: p, resolve: bundle.resolve)
        let mixer = AudioMixer(scene: scene, pool: MediaPool(diskCacheDirectory: nil),
                               format: MixFormat(sampleRate: 48_000, channels: 2))
        return try await mixer.render(range ?? 0 ..< max(p.duration, 1))
    }
}

private func maxAbsDiff(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

@Suite @MainActor struct AudioIntegrationTests {

    /// Splitting a clip anywhere on the frame grid is inaudible: the mix is sample-identical.
    @Test func splitIsSampleTransparent() async throws {
        let dir = try scratchDir("aud-split")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try AudioFixture(in: dir)
        let before = try await f.mix()
        #expect(before.frameCount == f.signal.count)
        let split = try f.chain.run(SplitClip(clipID: f.clipID, at: frames(39)))
        try f.chain.run(SplitClip(clipID: try #require(split.rightID), at: frames(77)))
        let after = try await f.mix()
        #expect(after.frameCount == before.frameCount)
        for c in 0..<2 {
            #expect(after.channels[c] == before.channels[c], "channel \(c) changed by splitting (max Δ \(maxAbsDiff(after.channels[c][...], before.channels[c][...])))")
        }
    }

    /// Moving a clip by n frames delays the mix by exactly n × 1600 samples; undo restores it bit for bit.
    @Test func moveShiftsMixBySamplesAndUndoRestoresIt() async throws {
        let dir = try scratchDir("aud-move")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try AudioFixture(in: dir, seconds: 2)
        let before = try await f.mix()
        try f.chain.run(MoveClip(clipID: f.clipID, toTrack: 0, start: frames(10)))
        let after = try await f.mix()
        let shift = 10 * samplesPerFrame
        #expect(after.frameCount == before.frameCount + shift)
        #expect(after.channels[0][..<shift].allSatisfy { $0 == 0 })
        #expect(Array(after.channels[0][shift...]) == before.channels[0], "moved mix is not a pure delay")
        try f.chain.undoAll()
        let undone = try await f.mix()
        #expect(undone.channels == before.channels)
    }

    /// Mute, ripple delete, trim and speed show up in the mix; undoing the chain restores it exactly.
    @Test func editChainAffectsMixAndUndoRestoresIt() async throws {
        let dir = try scratchDir("aud-chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try AudioFixture(in: dir)
        let original = try await f.mix()

        // Mute the track: silence.
        try f.chain.run(SetTrackFlag(track: 0, .audioMuted, true))
        let muted = try await f.mix()
        #expect(muted.channels.allSatisfy { $0.allSatisfy { $0 == 0 } }, "muted track is audible")
        try f.chain.run(SetTrackFlag(track: 0, .audioMuted, false))

        // Ripple-delete the middle second: the mix is the original minus that second.
        let s1 = try f.chain.run(SplitClip(clipID: f.clipID, at: frames(30)))
        let mid = try #require(s1.rightID)
        let s2 = try f.chain.run(SplitClip(clipID: mid, at: frames(60)))
        try f.chain.run(DeleteClips(clipIDs: [mid], ripple: true))
        let cut = try await f.mix()
        let a = 30 * samplesPerFrame, b = 60 * samplesPerFrame
        #expect(cut.frameCount == original.frameCount - (b - a))
        let cutHead: [Float] = Array(cut.channels[0][..<a]), origHead: [Float] = Array(original.channels[0][..<a])
        let cutTail: [Float] = Array(cut.channels[0][a...]), origTail: [Float] = Array(original.channels[0][b...])
        #expect(cutHead == origHead)
        #expect(cutTail == origTail)

        // Trim the tail clip's end by 15 frames: the mix ends 15 frames earlier.
        let tail = try #require(s2.rightID)
        let tailClip = try #require(locateClip(tail, in: f.chain.project))
        try f.chain.run(TrimClip(clipID: tail, edge: .end, to: tailClip.end - frames(15)))
        let trimmed = try await f.mix()
        #expect(trimmed.frameCount == cut.frameCount - 15 * samplesPerFrame)

        // Speed 2× halves the clip's audio length.
        try f.chain.run(SetClipSpeed(clipID: tail, speed: Rational(2)))
        let fast = try await f.mix()
        let tailNow = try #require(locateClip(tail, in: f.chain.project))
        #expect(fast.frameCount == Int(tailNow.end / frameTicks) * samplesPerFrame)
        #expect(fast.frameCount < trimmed.frameCount)

        try f.chain.expectUndoRedoWalk()
        try f.chain.undoAll()
        let restored = try await f.mix()
        #expect(restored.channels == original.channels, "undo of the whole chain changed the mix")
    }

    /// A WizRec-made project (target −18 LUFS, normalisation on by default)
    /// mixes an unmeasured source to the target; WizRec's meter agrees with
    /// TestGenKit's independent BS.1770 implementation.
    @Test func normalisedMixReachesTargetLoudness() async throws {
        let dir = try scratchDir("aud-lufs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try AudioFixture(in: dir, seconds: 6, lufs: -30, peakLimit: -16)
        let target = f.bundle.project.root["targetLoudness"]?.double ?? -18
        #expect(target == -18)

        // Two independent meters on the raw mono signal.
        let mono = PCMBuffer(format: PCMFormat(sampleRate: 48_000, channels: 1), startTime: .zero,
                             frameCount: f.signal.count, channels: [f.signal])
        let ours = Loudness.integratedLUFS(mono), theirs = AudioSignals.integratedLUFS(f.signal)
        #expect(abs(ours - theirs) < 0.05, "AudioEngine \(ours) vs TestGenKit \(theirs) LUFS")

        let mix = try await f.mix()
        let lufs = Loudness.integratedLUFS(mix)
        #expect(abs(lufs - target) < 0.5, "normalised mix measures \(lufs) LUFS, target \(target)")
        #expect(Loudness.truePeak(mix) < 0, "normalised mix clips")

        // Clip switch off → unity gain: the mix sits at the source's own level.
        let clip = try #require(locateClip(f.clipID, in: f.chain.project))
        clip.object["attributes"]?.object?["loudnessNormalization"] = .bool(false)
        let raw = try await f.mix()
        let expected = f.signal.map { Double($0) }
        let rawLeft = raw.channels[0].map { Double($0) }
        let ratio = (rawLeft.map { $0 * $0 }.reduce(0, +) / expected.map { $0 * $0 }.reduce(0, +)).squareRoot()
        #expect(ratio > 0.5 && ratio < 1.01, "un-normalised level ratio \(ratio)")
    }

    /// The mix of a saved and reopened project equals the in-memory mix, and
    /// two mixers on fresh pools agree bit for bit (determinism).
    @Test func mixSurvivesSaveReopenAndIsDeterministic() async throws {
        let dir = try scratchDir("aud-reopen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try AudioFixture(in: dir, seconds: 3)
        if f.chain.project.tracks.count < 2 { try f.chain.run(AddTrack(at: 1)) }
        try f.chain.run(InsertClip(sourceID: f.sourceID, track: 1, start: frames(45)))
        try f.chain.run(SetParameter(clipID: f.clipID, parameter: "volume", value: 0.5, keyframeAt: frames(30)))
        let a = try await f.mix()
        let b = try await f.mix()
        #expect(a.channels == b.channels, "two fresh mixers disagree")
        try f.bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: f.bundle.directory)
        let c = try await f.mix(of: reopened.project)
        #expect(c.channels == a.channels, "reopened project mixes differently")
    }
}
