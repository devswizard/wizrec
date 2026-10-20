import CoreGraphics
import Foundation
import MediaEngine
import TestGenKit
import Testing
@testable import PlayerKit

@Suite struct CaptionTargetTests {
    @Test @MainActor func findsAudioClipsOncePerSourceTrack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-captarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 1, lufs: -23), to: wav)
        let png = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 64) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let tb = doc.project.timebase
        let a1 = try await doc.importAndInsert(wav, at: 0)
        let img = try await doc.importAndInsert(png, at: tb.ticks(seconds: 5))
        let src = try #require(doc.project.sourceBin.first { $0.src.hasSuffix("voice.wav") }?.id)
        let a2 = try doc.insertSource(src, at: tb.ticks(seconds: 10), track: nil)

        let all = CaptionTarget.find(in: doc.project, selection: [a1, img, a2])
        #expect(all.count == 1)                       // same source track → once
        #expect(all.first?.clipID == a1)
        #expect(all.first?.sourceID == src)
        #expect(all.first?.track == 0)
        #expect(CaptionTarget.find(in: doc.project, selection: [img]).isEmpty)
        #expect(CaptionTarget.find(in: doc.project, selection: []).isEmpty)
        #expect(CaptionTarget.find(in: doc.project, selection: [a2]).first?.clipID == a2)
        // Add Captions works per clip: both clips of the same source.
        #expect(CaptionTarget.find(in: doc.project, selection: [a2, img, a1], perSourceTrack: false).map(\.clipID) == [a1, a2])
        // Under the playhead (start ≤ t < end): a dynamic caption at the playhead.
        #expect(CaptionTarget.under(ticks: tb.ticks(seconds: 0.5), in: doc.project).map(\.clipID) == [a1])
        #expect(CaptionTarget.under(ticks: tb.ticks(seconds: 10), in: doc.project).map(\.clipID) == [a2])
        #expect(CaptionTarget.under(ticks: tb.ticks(seconds: 5), in: doc.project).isEmpty)   // image only
        #expect(CaptionTarget.under(ticks: tb.ticks(seconds: 30), in: doc.project).isEmpty)

        // Export range of a selection: from the earliest start to the latest end.
        let end = try #require(doc.project.tracks.flatMap(\.clips).first { $0.id == a2 }?.end)
        #expect(ExportRange.selection(in: doc.project, clipIDs: [a1, a2]) == 0..<end)
        #expect(ExportRange.selection(in: doc.project, clipIDs: []) == nil)
    }
}
