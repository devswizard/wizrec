import CoreGraphics
import Foundation
import MediaEngine
import TestGenKit
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

/// The Audio library, Add Audio Point, inspector volume points and loudness measured on import.
@Suite @MainActor struct AudioPanelTests {
    struct Fixture {
        let dir: URL
        let doc: EditorDocumentModel
        let voice: Int64    // 3 s mono pink noise at -23 LUFS, at 0 s
        let still: Int64    // image at 5 s
    }

    static func fixture() async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-audiopanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("voice.wav")
        try AudioSignals.writeWAV(AudioSignals.pinkNoise(seconds: 3, lufs: -23), to: wav)
        let png = dir.appendingPathComponent("still.png")
        try MediaWriter.writePNG(to: png, width: 64, height: 64) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let voice = try await doc.importAndInsert(wav, at: 0)
        let still = try await doc.importAndInsert(png, at: doc.project.timebase.ticks(seconds: 5))
        return Fixture(dir: dir, doc: doc, voice: voice, still: still)
    }

    static func clip(_ id: Int64, _ doc: EditorDocumentModel) -> JSONObject? {
        doc.project.tracks.flatMap(\.clips).first { $0.id == id }?.object
    }

    static func volumePoints(_ id: Int64, _ doc: EditorDocumentModel) -> [JSONObject] {
        clip(id, doc)?["parameters"]?.object?["volume"]?.object?["keyframes"]?.array?.items.compactMap(\.object) ?? []
    }

    @Test func measuresLoudnessOnImport() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let src = try #require(f.doc.project.sourceBin.first { $0.src.hasSuffix("voice.wav") })
        let track = try #require(src.object["sourceTracks"]?.array?.items.first?.object)
        let lufs = try #require(track["integratedLUFS"]?.double)
        let peak = try #require(track["peakLevel"]?.double)
        // Mono counts as dual mono (+3 LU), as Camtasia stores it; no placeholder 100 / -1.
        #expect(abs(lufs - -20) < 1)
        #expect(peak > 0 && peak <= 1.5)
        // Import + placement + measurement is one undo step.
        try f.doc.undoLast()   // the image
        try f.doc.undoLast()   // the voice
        #expect(f.doc.project.sourceBin.isEmpty)
    }

    @Test func appliesPanelItemsToSelectedAudioClips() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let p = f.doc.project
        #expect(AudioPanel.audioClips(in: p, selection: [f.voice, f.still]).map(\.id) == [f.voice])
        #expect(AudioPanel.command(.fadeIn, project: p, selection: [f.still]) == nil)        // no audio
        #expect(AudioPanel.command(.captions, project: p, selection: [f.voice]) == nil)      // Captions menu

        let before = p.serialized()
        try f.doc.perform(try #require(AudioPanel.command(.fadeIn, project: p, selection: [f.voice, f.still])))
        let pts = Self.volumePoints(f.voice, f.doc)
        #expect(pts.map { $0["value"]?.double } == [0, 1])
        #expect(pts.allSatisfy { $0["interp"] == nil && $0["duration"]?.int == 0 })
        try f.doc.perform(try #require(AudioPanel.command(.emphasize, project: p, selection: [f.voice])))
        let effects = Self.clip(f.voice, f.doc)?["effects"]?.array?.items.compactMap { $0.object?["effectName"]?.string }
        #expect(effects == ["Emphasize"])
        try f.doc.undoLast()
        try f.doc.undoLast()
        #expect(p.serialized() == before)
    }

    @Test func addsAudioPointAtThePlayhead() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let tb = f.doc.project.timebase
        #expect(AudioPanel.addPointCommand(project: f.doc.project, selection: [f.voice], playhead: tb.ticks(seconds: 4)) == nil)
        #expect(AudioPanel.addPointCommand(project: f.doc.project, selection: [f.still], playhead: tb.ticks(seconds: 5)) == nil)
        let c = try #require(AudioPanel.addPointCommand(project: f.doc.project, selection: [f.voice], playhead: tb.ticks(seconds: 1)))
        try f.doc.perform(c)
        // A clip without points gets one at its start and one at the playhead, both at the level.
        #expect(Self.volumePoints(f.voice, f.doc).map { $0["time"]?.int } == [0, tb.ticks(seconds: 1)])
        #expect(Self.volumePoints(f.voice, f.doc).map { $0["value"]?.double } == [1, 1])
    }

    @Test func inspectorVolumeEditsWriteCamtasiaPoints() async throws {
        let f = try await Self.fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let tb = f.doc.project.timebase
        try f.doc.perform(AudioFade(clipID: f.voice, .fadeIn))   // points at 0 and 1 s
        let playhead = tb.ticks(seconds: 2)
        let i = try #require(ClipInspection.make(project: f.doc.project, clipID: f.voice, playhead: playhead))
        #expect(i.animated.contains(.volume))
        let before = f.doc.project.serialized()
        try f.doc.set(i.changes(.volume, 0.5))
        let pts = Self.volumePoints(f.voice, f.doc)
        #expect(pts.map { $0["time"]?.int } == [0, tb.ticks(seconds: 1), playhead])
        #expect(pts.last?["value"]?.double == 0.5)
        #expect(pts.allSatisfy { $0["interp"] == nil && $0["duration"]?.int == 0 && $0["endTime"] == $0["time"] })
        // Editing the same point again changes it in place.
        try f.doc.set(i.changes(.volume, 0.25))
        #expect(Self.volumePoints(f.voice, f.doc).count == 3)
        #expect(Self.volumePoints(f.voice, f.doc).last?["value"]?.double == 0.25)
        try f.doc.undoLast()
        try f.doc.undoLast()
        #expect(f.doc.project.serialized() == before)
        // Without points a volume edit stays a constant.
        try f.doc.undoLast()
        let j = try #require(ClipInspection.make(project: f.doc.project, clipID: f.voice, playhead: playhead))
        try f.doc.set(j.changes(.volume, 0.5))
        #expect(Self.volumePoints(f.voice, f.doc).isEmpty)
        let v = Self.clip(f.voice, f.doc)?["parameters"]?.object?["volume"]
        #expect((v?.double ?? v?.object?["defaultValue"]?.double) == 0.5)
    }
}
