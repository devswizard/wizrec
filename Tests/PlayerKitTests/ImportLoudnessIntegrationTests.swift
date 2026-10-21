import AudioEngine
import Foundation
import MediaEngine
import PlayerKit
import Testing
import TestGenKit
import TSCProjKit

// S5-QA-1 / app7: importing audio through the document model measures its loudness the way the
// project stores it (BS.1770 at the mix rate, mono as dual mono) and writes it in the same undo
// step as the import, for both Import Media and Add to Timeline; save/reopen keeps it.

@Suite(.serialized) @MainActor struct ImportLoudnessIntegrationTests {
    private func wav(in dir: URL, lufs: Double) throws -> (URL, mono: Double, peak: Double) {
        let signal = AudioSignals.pinkNoise(seconds: 5, lufs: lufs, peakLimit: -6)
        let url = dir.appendingPathComponent("pink\(Int(-lufs)).wav")
        try AudioSignals.writeWAV(signal, to: url)
        return (url, AudioSignals.integratedLUFS(signal), Double(signal.map { abs($0) }.max() ?? 0))
    }

    @Test func importMeasuresLoudnessInOneUndoStep() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s5-import-lufs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        let original = doc.project.serialized()

        // Import Media (bin only).
        let (a, monoA, peakA) = try wav(in: dir, lufs: -30)
        let sa = try await doc.importMedia(a)
        let trackA = try #require(doc.project.source(id: sa)?.tracks.first)
        let lufsA = try #require(trackA.integratedLUFS)
        let storedPeakA = trackA.object["peakLevel"]?.double ?? -1
        print(String(format: "import loudness: mono %.2f → stored %.2f LUFS, peak %.4f (signal %.4f)", monoA, lufsA, storedPeakA, peakA))
        #expect(abs(lufsA - (monoA + 3.01)) < 0.3, "stored \(lufsA), dual mono \(monoA + 3.01)")
        #expect(storedPeakA >= peakA * 0.97 && storedPeakA <= peakA * 1.1, "peak \(storedPeakA) vs \(peakA)")
        #expect(doc.undo.undoName == "Import Media")

        // Add to Timeline: measured as well, one step with the clip.
        let (b, monoB, _) = try wav(in: dir, lufs: -20)
        let clip = try await doc.importAndInsert(b, at: 0)
        let sb = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == clip }?.object["src"]?.int)
        let lufsB = try #require(doc.project.source(id: sb)?.tracks.first?.integratedLUFS)
        #expect(abs(lufsB - (monoB + 3.01)) < 0.3, "stored \(lufsB), dual mono \(monoB + 3.01)")
        #expect(doc.undo.undoName == "Add to Timeline")

        try doc.save()
        let reopened = try ProjectBundle(url: doc.bundle.directory)
        #expect(reopened.project.source(id: sa)?.tracks.first?.integratedLUFS == lufsA)
        #expect(reopened.project.source(id: sb)?.tracks.first?.integratedLUFS == lufsB)

        // Each import (source, loudness, clip) undoes as one step.
        try doc.undoLast()
        #expect(doc.project.source(id: sb) == nil && doc.project.tracks.flatMap(\.clips).isEmpty)
        try doc.undoLast()
        #expect(doc.project.serialized() == original)
    }

    /// APP12-3: a project without `audioFormatSampleRate` stores import loudness measured at the
    /// rate it is mixed at (48 kHz, like `AudioMixer`'s on-the-fly measurement then), not at
    /// 44.1 kHz; a project with the key keeps measuring at its own rate.
    @Test func keylessProjectMeasuresAtTheMixRate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("app12-import-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, _, _) = try wav(in: dir, lufs: -30)
        let pool = MediaPool(diskCacheDirectory: nil)
        let at48 = try #require(try await SourceLoudness.measure(pool: pool, url: a, stream: 0, mixRate: 48_000))
        let at44 = try #require(try await SourceLoudness.measure(pool: pool, url: a, stream: 0, mixRate: 44_100))
        #expect(abs(at48.integratedLUFS - at44.integratedLUFS) > 0.01, "the test signal must tell the two measurement rates apart")

        let url = dir.appendingPathComponent("keyless.cmproj", isDirectory: true)
        let bundle = try ProjectBundle.create(at: url, width: 640, height: 360, fps: 30)
        bundle.project.root["audioFormatSampleRate"] = nil
        try bundle.save()
        let keyless = try EditorDocumentModel(url: url)
        #expect(keyless.audioScene.sampleRate == nil)
        #expect(keyless.audioSampleRate == 48_000, "keyless playback mixes at the export rate")
        let s = try await keyless.importMedia(a)
        let t = try #require(keyless.project.source(id: s)?.tracks.first)
        #expect(abs((t.integratedLUFS ?? 0) - at48.integratedLUFS) < 1e-9, "stored at 15 significant digits")
        #expect(abs((t.object["peakLevel"]?.double ?? -1) - at48.peakLevel) < 1e-9)

        let keyed = try EditorDocumentModel.untitled(width: 640, height: 360, in: dir)
        #expect(keyed.audioScene.sampleRate == 44_100 && keyed.audioSampleRate == 44_100)
        let k = try await keyed.importMedia(a)
        #expect(abs((keyed.project.source(id: k)?.tracks.first?.integratedLUFS ?? 0) - at44.integratedLUFS) < 1e-9)
    }
}
