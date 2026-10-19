import Foundation
import Testing
import TSCProjKit
import TimelineEngine
@testable import Captions

@MainActor @Suite struct ClassicCaptionTests {
    @Test func addsCaptionKeyframesOnAudioClip() throws {
        let p = try makeProject(tracks: [amFile(10, start: s(2), dur: s(10))])
        let cmd = AddCaptions(cues: [CaptionCue(start: 3, end: 5, text: "One"), CaptionCue(start: 7, end: 8, text: "Two\n\nlines")])
        try cmd.apply(to: p)
        // Clip-local axis: timeline 3 s → 1 s.
        try expectJSON(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters", """
        {"captions" : {"type" : "caption", "keyframes" : [
          {"endTime" : 0, "time" : 0, "value" : {"text" : "", "textAttributes" : null}, "duration" : 0},
          {"endTime" : \(s(1)), "time" : \(s(1)), "value" : {"text" : "One", "textAttributes" : null}, "duration" : 0},
          {"endTime" : \(s(3)), "time" : \(s(3)), "value" : {"text" : "", "textAttributes" : null}, "duration" : 0},
          {"endTime" : \(s(5)), "time" : \(s(5)), "value" : {"text" : "Two\\nlines", "textAttributes" : null}, "duration" : 0},
          {"endTime" : \(s(6)), "time" : \(s(6)), "value" : {"text" : "", "textAttributes" : null}, "duration" : 0}]}}
        """)
        #expect(cmd.droppedCues.isEmpty)
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 3, end: 5, text: "One"),
                                                 CaptionCue(start: 7, end: 8, text: "Two\nlines")])
        try cmd.revert(on: p)
        try expectReversible(cmd, on: p)
    }

    @Test func newCuesReplaceOverlapsAndKeepOthers() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(10))])
        try AddCaptions(cues: [CaptionCue(start: 0, end: 4, text: "Old A"), CaptionCue(start: 6, end: 9, text: "Old B")]).apply(to: p)
        let cmd = AddCaptions(cues: [CaptionCue(start: 3, end: 7, text: "New"), CaptionCue(start: 2.5, end: 3.5, text: "Early")])
        try expectReversible(cmd, on: p)
        try cmd.apply(to: p)
        // Among new cues the later start wins where they overlap; old ones are trimmed.
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 0, end: 2.5, text: "Old A"),
                                                 CaptionCue(start: 2.5, end: 3, text: "Early"),
                                                 CaptionCue(start: 3, end: 7, text: "New"),
                                                 CaptionCue(start: 7, end: 9, text: "Old B")])
    }

    @Test func picksCarrierByOverlapAndDropsOrphans() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(4)), unified(20, start: s(4), dur: s(6))])
        let cmd = AddCaptions(cues: [CaptionCue(start: 3, end: 6, text: "mostly unified"),
                                     CaptionCue(start: 1, end: 2, text: "am"),
                                     CaptionCue(start: 20, end: 21, text: "nowhere"),
                                     CaptionCue(start: 1, end: 2, text: "  ")])
        try cmd.apply(to: p)
        #expect(cmd.droppedCues.map(\.text) == ["nowhere", "  "])
        let u = try #require(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0/audio/parameters/captions/keyframes")?.array)
        #expect(u.items.compactMap { $0.object?["value"]?.object?["text"]?.string } == ["mostly unified", ""])
        #expect(ClassicCaptions.cues(in: p).map(\.text) == ["am", "mostly unified"])
        #expect(ClassicCaptions.cues(in: p)[1] == CaptionCue(start: 4, end: 6, text: "mostly unified"))
        try cmd.revert(on: p)
        try expectReversible(cmd, on: p)
    }

    @Test func explicitClipAndRejections() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(4)), amFile(11, start: 0, dur: s(4))])
        let cmd = AddCaptions(cues: [CaptionCue(start: 0, end: 1, text: "x")], clipID: 11)
        try cmd.apply(to: p)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters/captions") == nil)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0/parameters/captions") != nil)
        try cmd.revert(on: p)
        expectRejected(AddCaptions(cues: [CaptionCue(start: 0, end: 1, text: "x")], clipID: 99), on: p)
        expectRejected(AddCaptions(cues: [CaptionCue(start: 50, end: 51, text: "x")]), on: p)
        expectRejected(AddCaptions(cues: []), on: p)
    }

    @Test func importAndExportSubtitleFiles() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(10))])
        let srt = "1\n00:00:01,000 --> 00:00:02,500\n<i>Hello</i>\n\n2\n00:00:04,000 --> 00:00:05,000\nWorld\n"
        let cmd = try CaptionFiles.importCommand(srt)
        try cmd.apply(to: p)
        // 2.5 s is a whole frame at 30 fps, so times survive exactly.
        #expect(CaptionFiles.srt(p) == "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:04,000 --> 00:00:05,000\nWorld\n")
        #expect(CaptionFiles.vtt(p) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n00:00:04.000 --> 00:00:05.000\nWorld\n")
        let vttCmd = try CaptionFiles.importCommand("\u{FEFF}WEBVTT\n\n00:06.000 --> 00:07.000\nThird\n")
        try vttCmd.apply(to: p)
        #expect(CaptionFiles.cues(in: p).map(\.text) == ["Hello", "World", "Third"])
        #expect(throws: CaptionsError.self) { try CaptionFiles.importCommand("garbage") }
    }

    /// Captions sit on the media axis, so split, trim and speed keep them on the same audio.
    @Test func captionsSurviveSplitTrimAndSpeed() throws {
        let cues = [CaptionCue(start: 0.5, end: 1.5, text: "Hello"), CaptionCue(start: 2, end: 3.2, text: "Zweite"),
                    CaptionCue(start: 4, end: 5, text: "Third")]
        let p = try makeProject(tracks: [unified(20, start: 0, dur: s(6))])
        try AddCaptions(cues: cues).apply(to: p)
        let split = SplitClip(clipID: 20, at: s(3.5))
        try split.apply(to: p)
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 0.5, end: 1.5, text: "Hello"),
                                                 CaptionCue(start: 2, end: 3.2, text: "Zweite"),
                                                 CaptionCue(start: 4, end: 5, text: "Third")])
        try split.revert(on: p)

        try TrimClip(clipID: 20, edge: .start, to: s(1)).apply(to: p)
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 1, end: 1.5, text: "Hello"),
                                                 CaptionCue(start: 2, end: 3.2, text: "Zweite"),
                                                 CaptionCue(start: 4, end: 5, text: "Third")])

        // A 2× clip from media 0: media 2 s plays at timeline 1 s.
        let fast = try makeProject(tracks: [amFile(10, start: 0, dur: s(3))])
        let clip = try #require(at(fast, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0")?.object)
        clip["scalar"] = .string("1/2"); clip["mediaDuration"] = .number(JSONNumber(s(6)))
        try AddCaptions(cues: [CaptionCue(start: 1, end: 2, text: "x")]).apply(to: fast)
        let kfs = at(fast, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters/captions/keyframes")?.array?.items ?? []
        #expect(kfs.compactMap { $0.object?["time"]?.int } == [0, s(2), s(4)])
        #expect(ClassicCaptions.cues(in: fast) == [CaptionCue(start: 1, end: 2, text: "x")])
    }

    @Test func removeCaptionsTrimsAndDeletes() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(10))])
        try AddCaptions(cues: [CaptionCue(start: 1, end: 4, text: "A"), CaptionCue(start: 6, end: 8, text: "B")]).apply(to: p)
        let cut = RemoveCaptions(range: 3...7)
        try expectReversible(cut, on: p)
        try cut.apply(to: p)
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 1, end: 3, text: "A"), CaptionCue(start: 7, end: 8, text: "B")])
        let all = RemoveCaptions()
        try expectReversible(all, on: p)
        try all.apply(to: p)
        try expectJSON(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters", "{}")
        expectRejected(RemoveCaptions(), on: p)
        expectRejected(RemoveCaptions(range: 0...1, clipID: 99), on: p)
    }

    @Test func captionStyleSetsKeysInPlace() throws {
        let text = """
        {"title" : "t", "editRate" : 705600000, "sourceBin" : [], "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : []},
         "trackAttributes" : [], "parameters" : {}, "captionAttributes" : {"enabled" : true, "fontName" : "Arial",
         "fontSize" : 32, "backgroundColor" : [0, 0, 0, 204], "lang" : "en", "opacity" : 0.5}, "gain" : 1.0}}
        """
        let p = try Project(data: Data(text.utf8))
        #expect(CaptionStyle(project: p) == CaptionStyle(enabled: true, fontName: "Arial", fontSize: 32,
                                                          backgroundColor: [0, 0, 0, 204], lang: "en"))
        let cmd = SetCaptionStyle(CaptionStyle(fontSize: 48, foregroundColor: [255, 255, 0, 300], lang: "bn"))
        try expectReversible(cmd, on: p)
        try cmd.apply(to: p)
        try expectJSON(p, "timeline/captionAttributes", """
        {"enabled" : true, "fontName" : "Arial", "fontSize" : 48, "backgroundColor" : [0, 0, 0, 204], "lang" : "bn",
         "opacity" : 0.5, "foregroundColor" : [255, 255, 0, 255]}
        """)
        expectRejected(SetCaptionStyle(CaptionStyle(fontSize: 48.0)), on: p) // unchanged

        let bare = try Project(data: Data(#"{"timeline" : {"id" : 1, "parameters" : {}, "gain" : 1.0}}"#.utf8))
        let create = SetCaptionStyle(CaptionStyle(enabled: true, lang: "en"))
        try expectReversible(create, on: bare)
        try create.apply(to: bare)
        #expect(bare.root["timeline"]?.object?.keys == ["id", "parameters", "captionAttributes", "gain"])
    }

    @Test func readsTimesClippedToClipAndSkipsEmpty() throws {
        // A hand-written captions parameter whose last caption runs past the clip end.
        let params = """
        {"captions" : {"type" : "caption", "keyframes" : [
          {"endTime" : 0, "time" : 0, "value" : {"text" : "", "textAttributes" : null}, "duration" : 0},
          {"endTime" : \(s(1)), "time" : \(s(1)), "value" : {"text" : "tail", "textAttributes" : null}, "duration" : 0}]}}
        """
        let p = try makeProject(tracks: [amFile(10, start: s(5), dur: s(3), parameters: params)])
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 6, end: 8, text: "tail")])
    }
}

@MainActor @Suite struct DynamicCaptionCommandTests {
    func transcribed() throws -> Project {
        let p = try makeProject(tracks: [amFile(10, start: s(1), dur: s(6), mediaStart: s(1))])
        try ApplyTranscription(sourceID: 1, track: 0, words: [
            w("The", 1.0, 1.5), w("quick", 1.5, 2.0), w("fox.", 2.0, 2.5), w("Later", 5.0, 5.5),
        ]).apply(to: p)
        return p
    }

    @Test func addsCalloutOnNewTrack() throws {
        let p = try transcribed()
        let cmd = AddDynamicCaption(audioClipID: 10)
        try cmd.apply(to: p)
        #expect(cmd.calloutID == p.maxID)
        let c = try #require(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0")?.object)
        #expect(c["_type"]?.string == "Callout" && c["id"]?.int == cmd.calloutID)
        #expect(c["start"]?.int == s(1) && c["duration"]?.int == s(6))
        let def = try #require(c["def"]?.object)
        #expect(DynamicCaptionStyle.isDynamicCaption(def) && DynamicCaptionStyle(def: def) == DynamicCaptionStyle())
        #expect(Array(def.keys.prefix(4)) == ["kind", "shape", "style", "corner-radius"])
        #expect(def["text"]?.string == "The quick fox.")
        #expect(def["width"]?.double == 1728 && def["height"]?.double == 216)
        // Box bottom 5 % above the canvas bottom, +y up.
        #expect(c["parameters"]?.object?["translation1"]?.double == -378.0) // -540 + 54 + 216 / 2
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/trackIndex")?.int == 1)
        try cmd.revert(on: p)
        #expect(cmd.calloutID == nil)
        try expectReversible(cmd, on: p)
    }

    @Test func cuesFollowTheAudioClipMapping() throws {
        let p = try transcribed()
        try AddDynamicCaption(audioClipID: 10).apply(to: p)
        // Clip at timeline 1 s plays media from 1 s: media word times map 1:1; the gap splits blocks.
        #expect(DynamicCaptions.cues(in: p) == [CaptionCue(start: 1, end: 2.5, text: "The quick fox."),
                                                 CaptionCue(start: 5, end: 5.5, text: "Later")])
        #expect(CaptionFiles.cues(in: p).count == 2) // no classic captions → dynamic ones
    }

    @Test func usesGivenFreeTrackAndRejectsBusyOrUntranscribed() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(6)), "", amFile(12, start: s(3), dur: s(2))])
        try ApplyTranscription(sourceID: 1, track: 0, words: [w("hi", 0, 1)]).apply(to: p)
        expectRejected(AddDynamicCaption(audioClipID: 10, track: 2), on: p)  // busy
        expectRejected(AddDynamicCaption(audioClipID: 10, track: 7), on: p)  // no such track
        expectRejected(AddDynamicCaption(audioClipID: 99), on: p)
        let cmd = AddDynamicCaption(audioClipID: 10, track: 1)
        try expectReversible(cmd, on: p)
        try cmd.apply(to: p)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks")?.array?.count == 3)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0/_type")?.string == "Callout")

        let bare = try makeProject(tracks: [amFile(10, start: 0, dur: s(6))])
        expectRejected(AddDynamicCaption(audioClipID: 10), on: bare)
    }

    @Test func setStyleRewritesOnlyCaptionKeys() throws {
        let p = try transcribed()
        let add = AddDynamicCaption(audioClipID: 10)
        try add.apply(to: p)
        let id = try #require(add.calloutID)
        let defPath = "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0/def"
        let keysBefore = at(p, defPath)?.object?.keys ?? []
        var style = DynamicCaptionStyle()
        style.pastWordOpacity = 0.4
        style.blockTransitionName = "Fade"
        let cmd = SetDynamicCaptionStyle(clipID: id, style: style)
        try expectReversible(cmd, on: p)
        try cmd.apply(to: p)
        let def = try #require(at(p, defPath)?.object)
        #expect(def.keys == keysBefore)
        #expect(DynamicCaptionStyle(def: def) == style)
        #expect(def["width"]?.double == 1728)
        expectRejected(SetDynamicCaptionStyle(clipID: 10, style: style), on: p)
    }

    @Test func setStyleInsertsMissingKeysInOrder() throws {
        let p = try transcribed()
        let add = AddDynamicCaption(audioClipID: 10)
        try add.apply(to: p)
        let defPath = "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0/def"
        let def = try #require(at(p, defPath)?.object)
        def["dynamic-caption-past-word-opacity"] = nil
        def["dynamic-caption-style"] = nil
        var style = DynamicCaptionStyle()
        style.pastWordOpacity = 0.25
        try SetDynamicCaptionStyle(clipID: try #require(add.calloutID), style: style).apply(to: p)
        let keys = try #require(at(p, defPath)?.object?.keys)
        let i = try #require(keys.firstIndex(of: "dynamic-caption-past-word-opacity"))
        #expect(keys[i - 1] == "dynamic-caption-new-paragraph-for-each-sentence")
        #expect(keys[i + 1] == "dynamic-caption-word-easing-duration")
        let j = try #require(keys.firstIndex(of: "dynamic-caption-style"))
        #expect(keys[j - 1] == "dynamic-caption-block-transition-name" && keys[j + 1] == "horizontal-alignment")
    }
}

/// Camtasia's dynamic-caption sample projects, read in place (skipped when Camtasia is not installed).
private let sampleDir = URL(fileURLWithPath: "/Applications/Camtasia.app/Contents/Resources/DynamicCaptions")
private let samplesAvailable = FileManager.default.fileExists(
    atPath: sampleDir.appendingPathComponent("DynamicCaptionPreviewBaseProject_en-US.tscproj").path)

@MainActor @Suite struct SampleProjectTests {
    static let dir = sampleDir

    @Test(.enabled(if: samplesAvailable)) func readsWordsStyleAndCues() throws {
        let p = try Project(contentsOf: Self.dir.appendingPathComponent("DynamicCaptionPreviewBaseProject_en-US.tscproj"))
        let audio = try #require(p.sourceBin.first { $0.tracks.contains { Transcript.isSet($0) } })
        let ti = try #require(audio.tracks.firstIndex { Transcript.isSet($0) })
        let words = Transcript.words(in: p, sourceID: audio.id, track: ti)
        #expect(words.first?.text == "The" && words.first?.start == 0)
        #expect(words.allSatisfy { $0.end > $0.start })
        let callout = try #require(p.tracks.flatMap(\.clips).first { $0.object["_type"]?.string == "Callout" })
        let def = try #require(callout.object["def"]?.object)
        // The defaults are the sample's values.
        #expect(DynamicCaptionStyle(def: def) == DynamicCaptionStyle())
        let cues = DynamicCaptions.cues(in: p)
        #expect(!cues.isEmpty)
        #expect(cues.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            == words.map(\.text).joined(separator: " "))
    }

    @Test(.enabled(if: samplesAvailable)) func allLanguagesDecode() throws {
        for lang in ["de-DE", "en-US", "es-ES", "fr-FR", "ja-JP", "pt-BR", "zh-CN"] {
            let p = try Project(contentsOf: Self.dir.appendingPathComponent("DynamicCaptionPreviewBaseProject_\(lang).tscproj"))
            #expect(!DynamicCaptions.cues(in: p).isEmpty, "\(lang)")
        }
    }
}
