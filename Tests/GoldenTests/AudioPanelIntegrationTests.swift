import AudioEngine
import Foundation
import MediaEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S5-QA-1 / audio6: Audio Effects panel items and fades through the mixer, and source loudness
// measured the way the project stores it (mix rate, mono as dual mono), end to end with
// save/reopen and undo. Synthetic WAVs only.

/// A 48 kHz mono WAV of `signal` imported into a new bundle, one clip at 0; edits start after setup.
@MainActor
private struct Fixture {
    let bundle: ProjectBundle
    let chain: EditChain
    let sourceID: Int64
    let clipID: Int64
    let wav: URL

    init(in dir: URL, signal: [Float]) throws {
        bundle = try ProjectBundle.create(at: dir.appendingPathComponent("ap.cmproj"))
        let file = dir.appendingPathComponent("sig.wav")
        try AudioSignals.writeWAV(signal, to: file)
        let src = try bundle.importFile(file)
        let setup = EditChain(bundle.project)
        let add = AddSource(SourceDescriptor(src: src, lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
            .init(type: 2, editRate: 48_000, rangeEnd: Int64(signal.count), width: 0, height: 0,
                  sampleRate: Rational(48_000), bitDepth: 16, channelCount: 1),
        ]))
        add.addedAt = Date(timeIntervalSince1970: 1_792_376_869)
        try setup.run(add)
        sourceID = try #require(add.sourceID)
        clipID = try #require(try setup.run(InsertClip(sourceID: sourceID, track: 0, start: 0)).clipID)
        wav = bundle.resolve(try #require(bundle.project.source(id: sourceID)))
        chain = EditChain(bundle.project)
    }

    /// Left channel of the whole-timeline mix at 48 kHz.
    func mix(_ project: Project? = nil) async throws -> [Float] {
        let p = project ?? bundle.project
        let mixer = AudioMixer(scene: AudioScene(project: p, resolve: bundle.resolve),
                               pool: MediaPool(diskCacheDirectory: nil), format: MixFormat(sampleRate: 48_000, channels: 2))
        return try await mixer.render(0 ..< max(p.duration, 1)).channels[0]
    }
}

/// Gain envelope: `after / before` sample by sample (the input is a constant level).
private func gain(_ after: [Float], _ before: [Float], at seconds: Double) -> Double {
    let i = min(Int(seconds * 48_000), before.count - 1)
    return Double(after[i]) / Double(before[i])
}

@Suite(.serialized) @MainActor struct AudioPanelIntegrationTests {
    /// Fade In ramps the mix 0 → 1 over the first second; Fade Out 1 → 0 over the last; the rest
    /// is untouched; save/reopen keeps the envelope; undo restores the bytes and the mix.
    @Test func fadesShapeTheMix() async throws {
        let dir = try scratchDir("s5-audio-fades")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try Fixture(in: dir, signal: [Float](repeating: 0.25, count: 4 * 48_000))
        let original = f.chain.project.serialized()
        let flat = try await f.mix()
        #expect(flat.count == 4 * 48_000 && flat.allSatisfy { abs($0 - flat[0]) < 1e-6 && $0 > 0.05 },
                "constant input should mix to a constant level")

        try f.chain.run(ApplyAudioItem(clipID: f.clipID, item: .fadeIn))
        try f.chain.run(ApplyAudioItem(clipID: f.clipID, item: .fadeOut))
        let faded = try await f.mix()
        let g = { (s: Double) in gain(faded, flat, at: s) }
        print(String(format: "audio fades: gain 0 s %.3f, 0.25 s %.3f, 0.5 s %.3f, 1 s %.3f, 2 s %.3f, 3.5 s %.3f, end %.3f",
                     g(0), g(0.25), g(0.5), g(1), g(2), g(3.5), g(3.9999)))
        #expect(g(0) < 0.01, "fade-in does not start at 0")
        #expect(g(0.5) > 0.3 && g(0.5) < 0.7, "fade-in midpoint \(g(0.5))")
        #expect(abs(g(1.0) - 1) < 0.01 && abs(g(2) - 1) < 1e-4 && abs(g(2.99) - 1) < 0.01, "level between the fades")
        #expect(g(3.5) > 0.3 && g(3.5) < 0.7, "fade-out midpoint \(g(3.5))")
        #expect(g(3.9999) < 0.01, "fade-out does not reach 0")
        let rampIn = (0 ..< 48_000).map { Double(faded[$0]) }
        #expect(zip(rampIn, rampIn.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 }, "fade-in not monotonic")
        let rampOut = (3 * 48_000 ..< 4 * 48_000).map { Double(faded[$0]) }
        #expect(zip(rampOut, rampOut.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }, "fade-out not monotonic")

        try f.bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: f.bundle.directory)
        #expect(reopened.project.serialized() == f.chain.project.serialized())
        #expect(try await f.mix(reopened.project) == faded, "mix changed across save/reopen")

        try f.chain.expectUndoRedoWalk()
        try f.chain.undoAll()
        #expect(f.chain.project.serialized() == original)
        #expect(try await f.mix() == flat)
    }

    /// Every panel item applies through one command: effect items add their entry, Clip Speed
    /// sets its metadata, Captions is refused; the project mixes, saves and reopens unchanged,
    /// and undo-all restores the bytes.
    @Test func panelItemsApplySaveAndUndo() async throws {
        let dir = try scratchDir("s5-audio-panel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try Fixture(in: dir, signal: AudioSignals.pinkNoise(seconds: 2, lufs: -23))
        let original = f.chain.project.serialized()
        for item in AudioPanelItem.allCases where item != .captions {
            try f.chain.run(ApplyAudioItem(clipID: f.clipID, item: item))
        }
        #expect(throws: (any Error).self) { try ApplyAudioItem(clipID: f.clipID, item: .captions).apply(to: f.chain.project) }
        let clip = try #require(f.chain.project.tracks.first?.clips.first)
        let names = (clip.object["effects"]?.array?.items ?? []).compactMap { $0.object?["effectName"]?.string }
        let expected = AudioPanelItem.allCases.compactMap(\.effectName)
        #expect(names == expected, "effects \(names)")
        #expect(clip.object["metadata"]?.object?["effectApplied"] != nil)

        let mixed = try await f.mix()
        #expect(mixed.count == 2 * 48_000 && mixed.contains { $0 != 0 })
        try f.bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: f.bundle.directory)
        #expect(reopened.project.serialized() == f.chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        try f.chain.expectUndoRedoWalk()
        try f.chain.undoAll()
        #expect(f.chain.project.serialized() == original)
    }

    /// A mono WAV measures as dual mono: mono BS.1770 loudness + 3.01 LU, at the 44.1 kHz default
    /// mix rate and at 48 kHz alike; the peak is the signal's. Stored with SetSourceLoudness,
    /// saved, reopened, undone.
    @Test func monoSourceLoudnessIsDualMono() async throws {
        let dir = try scratchDir("s5-audio-lufs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let signal = AudioSignals.pinkNoise(seconds: 6, lufs: -26, peakLimit: -6)
        let f = try Fixture(in: dir, signal: signal)
        let mono = AudioSignals.integratedLUFS(signal)
        let peak = Double(signal.map { abs($0) }.max() ?? 0)
        let pool = MediaPool(diskCacheDirectory: nil)
        let m441 = try #require(try await SourceLoudness.measure(pool: pool, url: f.wav, stream: 0))
        let m48 = try #require(try await SourceLoudness.measure(pool: pool, url: f.wav, stream: 0, mixRate: 48_000))
        print(String(format: "loudness: mono %.2f LUFS → stored %.2f (44.1 kHz), %.2f (48 kHz); peak %.4f vs %.4f",
                     mono, m441.integratedLUFS, m48.integratedLUFS, m441.peakLevel, peak))
        #expect(abs(m48.integratedLUFS - (mono + 3.01)) < 0.1, "48 kHz: \(m48.integratedLUFS) vs dual mono \(mono + 3.01)")
        #expect(abs(m441.integratedLUFS - (mono + 3.01)) < 0.3, "44.1 kHz: \(m441.integratedLUFS) vs dual mono \(mono + 3.01)")
        #expect(abs(m48.peakLevel - peak) < 1e-3, "peak \(m48.peakLevel) vs \(peak)")
        #expect(m441.peakLevel >= peak * 0.97 && m441.peakLevel <= peak * 1.1, "resampled peak \(m441.peakLevel)")
        #expect(try await SourceLoudness.measure(pool: pool, url: dir.appendingPathComponent("missing.wav"), stream: 0) == nil)

        let original = f.chain.project.serialized()
        try f.chain.run(SetSourceLoudness(sourceID: f.sourceID, track: 0, integratedLUFS: m441.integratedLUFS,
                                          peakLevel: m441.peakLevel))
        try f.bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: f.bundle.directory)
        let stored = try #require(reopened.project.source(id: f.sourceID)?.tracks.first?.integratedLUFS)
        #expect(abs(stored - m441.integratedLUFS) < 1e-9)
        try f.chain.undoAll()
        #expect(f.chain.project.serialized() == original)
    }
}
