import Foundation
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
}
