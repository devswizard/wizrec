import Foundation
import Testing
import TSCProjKit
import TimelineEngine
@testable import Captions

@MainActor @Suite struct TranscriptionCommandTests {
    @Test func appliesWordsAsSourceTrackKeyframes() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(10))])
        let cmd = ApplyTranscription(sourceID: 1, track: 0, words: [
            w("Hello", 0, 0.5), w(" world. ", 0.5, 1.0), w("", 1.2, 1.3), w("Again", 3.0, 3.4),
        ])
        try cmd.apply(to: p)
        try expectJSON(p, "sourceBin/0/sourceTracks/0", """
        {"range" : [0, 480000], "type" : 2, "editRate" : 48000, "trackRect" : [0, 0, 0, 0],
         "sampleRate" : 48000, "bitDepth" : 16, "numChannels" : 1, "metaData" : "", "transcriptionSet" : true,
         "parameters" : {"transcription" : {"type" : "string", "keyframes" : [
           {"endTime" : 0, "time" : 0, "value" : "Hello", "duration" : 0},
           {"endTime" : \(s(0.5)), "time" : \(s(0.5)), "value" : "world.", "duration" : 0},
           {"endTime" : \(s(1)), "time" : \(s(1)), "value" : "", "duration" : 0},
           {"endTime" : \(s(3)), "time" : \(s(3)), "value" : "Again", "duration" : 0},
           {"endTime" : \(s(3.4)), "time" : \(s(3.4)), "value" : "", "duration" : 0}]}}}
        """)
        // Reads back as the trimmed, non-empty words, ends from the next keyframe.
        let back = Transcript.words(in: p, sourceID: 1, track: 0)
        #expect(back.map(\.text) == ["Hello", "world.", "Again"])
        #expect(back.map(\.start) == [0, 0.5, 3.0])
        #expect(back.map(\.end) == [0.5, 1.0, 3.4])
        try cmd.revert(on: p)
        try expectReversible(cmd, on: p)
    }

    @Test func roundsToFramesAndKeepsTimesIncreasing() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(10))])
        // 0.01 s and 0.02 s both round to frame 0: the second is pushed to frame 1.
        let cmd = ApplyTranscription(sourceID: 1, track: 0, words: [w("b", 0.02, 0.03), w("a", 0.01, 0.02)], closeGap: 10)
        try cmd.apply(to: p)
        let kfs = at(p, "sourceBin/0/sourceTracks/0/parameters/transcription/keyframes")?.array?.items ?? []
        #expect(kfs.compactMap { $0.object?["time"]?.int } == [0, frame, 2 * frame])
        #expect(kfs.compactMap { $0.object?["value"]?.string } == ["a", "b", ""])
    }

    @Test func replacesExistingTranscriptionAndCreatesParameters() throws {
        let bin = testSourceBin.replacingOccurrences(of: #""metaData" : "", "parameters" : {}}]}, "#,
                                                     with: #""metaData" : ""}]}, "#)
        let p = try makeProject(tracks: [""], sourceBin: bin)
        let first = ApplyTranscription(sourceID: 1, track: 0, words: [w("one", 0, 1)])
        try first.apply(to: p)
        try expectJSON(p, "sourceBin/0/sourceTracks/0/transcriptionSet", "true")
        let keys = at(p, "sourceBin/0/sourceTracks/0")?.object?.keys ?? []
        #expect(keys.suffix(2) == ["transcriptionSet", "parameters"])
        let second = ApplyTranscription(sourceID: 1, track: 0, words: [w("two", 2, 3)])
        try expectReversible(second, on: p)
        try second.apply(to: p)
        #expect(Transcript.words(in: p, sourceID: 1, track: 0).map(\.text) == ["two"])
    }

    @Test func emptyWordListWritesEmptyKeyframes() throws {
        let p = try makeProject(tracks: [""])
        try ApplyTranscription(sourceID: 1, track: 0, words: []).apply(to: p)
        try expectJSON(p, "sourceBin/0/sourceTracks/0/parameters", #"{"transcription" : {"type" : "string", "keyframes" : []}}"#)
    }

    @Test func rejectsBadTargets() throws {
        let p = try makeProject(tracks: [""])
        expectRejected(ApplyTranscription(sourceID: 9, track: 0, words: [w("x", 0, 1)]), on: p)
        expectRejected(ApplyTranscription(sourceID: 1, track: 3, words: [w("x", 0, 1)]), on: p)
        expectRejected(ApplyTranscription(sourceID: 2, track: 0, words: [w("x", 0, 1)]), on: p) // video track
        expectRejected(RemoveTranscription(sourceID: 1, track: 0), on: p) // nothing to remove
    }

    @Test func removeTranscriptionIsReversible() throws {
        let p = try makeProject(tracks: [""])
        try ApplyTranscription(sourceID: 2, track: 1, words: [w("hi", 0, 1)]).apply(to: p)
        let before = p.serialized()
        let rm = RemoveTranscription(sourceID: 2, track: 1)
        try rm.apply(to: p)
        #expect(at(p, "sourceBin/1/sourceTracks/1/transcriptionSet") == nil)
        try expectJSON(p, "sourceBin/1/sourceTracks/1/parameters", "{}")
        try rm.revert(on: p)
        #expect(p.serialized() == before)
        try expectReversible(rm, on: p)
    }

    @Test func undoStackRoundTrip() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(10))])
        let original = p.serialized()
        let undo = UndoStack(project: p)
        try undo.perform(ApplyTranscription(sourceID: 1, track: 0, words: [w("a", 0, 1)]))
        let applied = p.serialized()
        try undo.undo()
        #expect(p.serialized() == original)
        try undo.redo()
        #expect(p.serialized() == applied)
    }
}
