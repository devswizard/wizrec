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

    /// CA1: Add Captions writes an empty caption every 4 s of media time from `mediaStart`.
    @Test func addEmptyCaptionsEveryFourSecondsOfMediaTime() throws {
        let p = try makeProject(tracks: [amFile(10, start: s(2), dur: s(13.2))])
        let cmd = AddEmptyCaptions(clipID: 10)
        try cmd.apply(to: p)
        let e = { (t: Double) in
            #"{"endTime" : \#(s(t)), "time" : \#(s(t)), "value" : {"text" : "", "textAttributes" : null}, "duration" : 0}"#
        }
        try expectJSON(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters", """
        {"captions" : {"type" : "caption", "keyframes" : [\(e(0)), \(e(4)), \(e(8)), \(e(12))]}}
        """)
        #expect(ClassicCaptions.cues(in: p).isEmpty)  // empty text: nothing shown
        try cmd.revert(on: p)
        try expectReversible(cmd, on: p)
        try cmd.apply(to: p)
        expectRejected(AddEmptyCaptions(clipID: 10), on: p)  // already has captions [WizRec]
        expectRejected(AddEmptyCaptions(clipID: 99), on: p)

        // After a 1 s left trim: 1, 5, 9, 13 s (the last segment 13–13.2 s).
        let trimmed = try makeProject(tracks: [amFile(10, start: 0, dur: s(12.2), mediaStart: s(1))])
        try AddEmptyCaptions(clipID: 10).apply(to: trimmed)
        let kfs = at(trimmed, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters/captions/keyframes")?
            .array?.items ?? []
        #expect(kfs.compactMap { $0.object?["time"]?.int } == [s(1), s(5), s(9), s(13)])
        // On a UnifiedMedia the captions go to its audio half.
        let u = try makeProject(tracks: [unified(20, start: 0, dur: s(5))])
        try AddEmptyCaptions(clipID: 20).apply(to: u)
        #expect(at(u, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/audio/parameters/captions/keyframes")?
            .array?.count == 2)
        // Imported captions start their filler at the media window too.
        let imp = try makeProject(tracks: [amFile(10, start: 0, dur: s(8), mediaStart: s(1))])
        try AddCaptions(cues: [CaptionCue(start: 2, end: 3, text: "x")]).apply(to: imp)
        let ik = at(imp, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/parameters/captions/keyframes")?.array?.items ?? []
        #expect(ik.compactMap { $0.object?["time"]?.int } == [s(1), s(3), s(4)])
    }

    /// CA1: split, ripple delete and move keep every caption keyframe on each piece (none pruned
    /// or shifted), so a piece may carry captions outside its media window.
    @Test func editsNeverPruneCaptionKeyframes() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(13.2))])
        try AddEmptyCaptions(clipID: 10).apply(to: p)
        try AddCaptions(cues: [CaptionCue(start: 1, end: 3, text: "One"), CaptionCue(start: 9, end: 11, text: "Two")])
            .apply(to: p)
        func captions() -> [JSON] {
            (at(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias")?.array?.items ?? [])
                .compactMap { $0.object?["parameters"]?.object?["captions"] }
        }
        let original = try #require(captions().first)
        let before = p.serialized()
        let split = SplitClip(clipID: 10, at: s(6))
        try split.apply(to: p)
        #expect(captions() == [original, original])
        let pieces = (at(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias")?.array?.items ?? [])
            .compactMap { $0.object?["id"]?.int }
        let ripple = DeleteClips(clipIDs: [pieces[0]], ripple: true)
        try ripple.apply(to: p)
        #expect(captions() == [original])
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0/start")?.int == 0)
        // The right piece shows only its own window's captions.
        #expect(ClassicCaptions.cues(in: p) == [CaptionCue(start: 3, end: 5, text: "Two")])
        let move = MoveClip(clipID: pieces[1], toTrack: 0, start: s(20))
        try move.apply(to: p)
        #expect(captions() == [original])
        try move.revert(on: p); try ripple.revert(on: p); try split.revert(on: p)
        #expect(p.serialized() == before)
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

    static let calloutPath = "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0"

    /// CA2: "Arial 2 Line Dark Background" at the playhead (1 s) → a 60 s callout on a new top track.
    @Test func addsSixtySecondCalloutAtPlayheadOnNewTrack() throws {
        let p = try transcribed()
        let cmd = AddDynamicCaption(at: 1)
        try cmd.apply(to: p)
        #expect(cmd.calloutID == p.maxID)
        try expectJSON(p, Self.calloutPath, """
        {"id" : \(p.maxID), "_type" : "Callout", "def" : {"kind" : "remix", "shape" : "text", "style" : "caption",
          "corner-radius" : 6.0,
          "dynamic-caption-background-corner-radius" : 24.0,
          "dynamic-caption-background-fill-color-alpha" : 0.6, "dynamic-caption-background-fill-color-blue" : 0.0,
          "dynamic-caption-background-fill-color-green" : 0.0, "dynamic-caption-background-fill-color-red" : 0.0,
          "dynamic-caption-block-transition-duration" : 0.5, "dynamic-caption-block-transition-reverse" : 0.0,
          "dynamic-caption-current-word-color-alpha" : 1.0, "dynamic-caption-current-word-color-blue" : 1.0,
          "dynamic-caption-current-word-color-green" : 1.0, "dynamic-caption-current-word-color-red" : 1.0,
          "dynamic-caption-current-word-enabled" : 0.0, "dynamic-caption-current-word-extra-scale" : 0.0,
          "dynamic-caption-current-word-glow-radius" : 0.0,
          "dynamic-caption-current-word-stroke-color-alpha" : 0.0, "dynamic-caption-current-word-stroke-color-blue" : 0.0,
          "dynamic-caption-current-word-stroke-color-green" : 0.0, "dynamic-caption-current-word-stroke-color-red" : 1.0,
          "dynamic-caption-current-word-stroke-extra-width" : 18.0, "dynamic-caption-future-word-opacity" : 0.0,
          "dynamic-caption-new-paragraph-for-each-sentence" : 0.0, "dynamic-caption-past-word-opacity" : 1.0,
          "dynamic-caption-word-easing-duration" : 0.0,
          "dynamic-caption-word-rectangle-color-alpha" : 0.0, "dynamic-caption-word-rectangle-color-blue" : 1.0,
          "dynamic-caption-word-rectangle-color-green" : 1.0, "dynamic-caption-word-rectangle-color-red" : 1.0,
          "dynamic-caption-word-rectangle-corner-radius" : 6.0, "dynamic-caption-word-rectangle-extra-size" : 0.125,
          "dynamic-caption-word-rectangle-transition-time" : 0.1,
          "enable-ligatures" : 1.0, "hasDropShadow" : 0.0, "height" : 288.0, "line-spacing" : 0.0,
          "text-stroke-alignment" : 2.0, "text-stroke-color-alpha" : 0.4, "text-stroke-color-blue" : 0.0,
          "text-stroke-color-green" : 0.0, "text-stroke-color-red" : 0.0, "text-stroke-width" : 0.0,
          "tracking" : 0.0, "width" : 1280.0, "word-wrap" : 1.0,
          "dynamic-caption-block-transition-name" : "", "dynamic-caption-display-name" : "Arial 2 Line Dark Background",
          "dynamic-caption-preset-ID" : "blockPreset8", "dynamic-caption-style" : "block",
          "horizontal-alignment" : "center", "modifier" : "dynamicCaption", "resize-behavior" : "resizeCallout",
          "text" : "ABC", "vertical-alignment" : "center",
          "font" : {"color-blue" : 1.0, "color-green" : 1.0, "color-opacity" : 1.0, "color-red" : 1.0, "size" : 128.0,
                    "name" : "Bebas Neue", "weight" : "Regular"},
          "textAttributes" : {"type" : "textAttributeList", "keyframes" : [{"endTime" : 0, "time" : 0, "value" : [
            {"name" : "fontItalic", "rangeEnd" : 3, "rangeStart" : 0, "value" : 0, "valueType" : "int"},
            {"name" : "kerning", "rangeEnd" : 3, "rangeStart" : 0, "value" : -0.02, "valueType" : "double"},
            {"name" : "fontWeight", "rangeEnd" : 3, "rangeStart" : 0, "value" : 400, "valueType" : "int"},
            {"name" : "underline", "rangeEnd" : 3, "rangeStart" : 0, "value" : 0, "valueType" : "int"},
            {"name" : "fontName", "rangeEnd" : 3, "rangeStart" : 0, "value" : "Arial", "valueType" : "string"},
            {"name" : "fgColor", "rangeEnd" : 3, "rangeStart" : 0, "value" : "(255,255,255,255)", "valueType" : "color"},
            {"name" : "fontSize", "rangeEnd" : 3, "rangeStart" : 0, "value" : 96.0, "valueType" : "double"},
            {"name" : "strikethrough", "rangeEnd" : 3, "rangeStart" : 0, "value" : 0, "valueType" : "int"}],
            "duration" : 0}]}},
         "attributes" : {"ident" : "", "autoRotateText" : true},
         "parameters" : {"translation1" : -396.0, "geometryCrop0" : 0.0, "geometryCrop1" : 0.0, "geometryCrop2" : 0.0,
                         "geometryCrop3" : 0.0},
         "effects" : [], "start" : \(s(1)), "duration" : \(s(60)), "mediaStart" : 0, "mediaDuration" : \(s(60)),
         "scalar" : 1,
         "metadata" : {"audiateLinkedSession" : "", "clipSpeedAttribute" : {"type" : "bool", "value" : false},
                       "colorAttribute" : {"type" : "color", "value" : [0, 0, 0, 0]}, "effectApplied" : "none"},
         "animationTracks" : {}}
        """)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/trackIndex")?.int == 1)
        try cmd.revert(on: p)
        #expect(cmd.calloutID == nil)
        try expectReversible(cmd, on: p)
    }

    /// CA2: a second style at 4 s adds a second callout on another new track.
    @Test func secondStyleAddsSecondCallout() throws {
        let p = try transcribed()
        let first = AddDynamicCaption(at: 1)
        try first.apply(to: p)
        let before = p.serialized()
        let second = AddDynamicCaption(at: 4, preset: .bangersSingleLine)
        try second.apply(to: p)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks")?.array?.count == 3)
        #expect(at(p, Self.calloutPath + "/def/dynamic-caption-preset-ID")?.string == "blockPreset8")
        let c2 = "timeline/sceneTrack/scenes/0/csml/tracks/2/medias/0"
        #expect(at(p, c2 + "/id")?.int == second.calloutID && second.calloutID == (first.calloutID ?? 0) + 1)
        #expect(at(p, c2 + "/start")?.int == s(4) && at(p, c2 + "/duration")?.int == s(60))
        let def = try #require(at(p, c2 + "/def")?.object)
        #expect(def["dynamic-caption-display-name"]?.string == "Bangers Single Line")
        #expect(def["hasDropShadow"] == nil)  // absent in this preset [obs]
        #expect(def["height"]?.double == 150 && def["width"]?.double == 1280)
        #expect(def["text-stroke-width"]?.double == 8 && def["text-stroke-color-alpha"]?.double == 1)
        #expect(DynamicCaptionStyle(def: def) == DynamicCaptionPreset.bangersSingleLine.style)
        #expect(at(p, c2 + "/parameters/translation1")?.double == -457)
        // Runs decide the visible font; def.font stays the leftover default.
        #expect(def["font"]?.object?["name"]?.string == "Bebas Neue")
        #expect(CaptionBlockRules.baseFontSize(def: def) == 96)
        try second.revert(on: p)
        #expect(p.serialized() == before)  // byte-exact undo
    }

    @Test func scalesBoxToCanvasAndKeepsOldDefSizing() throws {
        let text = """
        {"title" : "t", "editRate" : 705600000, "width" : 1280.0, "height" : 720.0, "videoFormatFrameRate" : 30, \
        "sourceBin" : [], "timeline" : {"id" : 1, "sceneTrack" : {"scenes" : [{"csml" : {"tracks" : []}}]}, \
        "trackAttributes" : []}}
        """
        let p = try Project(data: Data(text.utf8))
        try AddDynamicCaption(at: 0).apply(to: p)
        let c = "timeline/sceneTrack/scenes/0/csml/tracks/0/medias/0"
        #expect(at(p, c + "/def/width")?.double == 853.333 && at(p, c + "/def/height")?.double == 192)
        #expect(at(p, c + "/parameters/translation1")?.double == -264)
        // Earlier saves (CP1 / WizRec before CA2): resizeText, size from def.font.
        let old = JSONObject([("resize-behavior", .string("resizeText")),
                              ("font", J.obj([("size", J.dbl(72))]))])
        #expect(CaptionBlockRules.baseFontSize(def: old) == 72)
        #expect(CaptionBlockRules.baseFontSize(def: JSONObject()) == 96)
    }

    @Test func cuesFollowTheAudioClipMapping() throws {
        let p = try transcribed()
        try AddDynamicCaption(audioClipID: 10).apply(to: p)
        // Clip at timeline 1 s plays media from 1 s: media word times map 1:1; the gap splits blocks.
        #expect(DynamicCaptions.cues(in: p) == [CaptionCue(start: 1, end: 2.5, text: "The quick fox."),
                                                 CaptionCue(start: 5, end: 5.5, text: "Later")])
        #expect(CaptionFiles.cues(in: p).count == 2) // no classic captions → dynamic ones
        #expect(at(p, Self.calloutPath + "/start")?.int == s(1) && at(p, Self.calloutPath + "/duration")?.int == s(60))
    }

    @Test func usesGivenFreeTrackAndRejectsBusyOrUntranscribed() throws {
        let p = try makeProject(tracks: [amFile(10, start: 0, dur: s(6)), "", amFile(12, start: s(70), dur: s(2))])
        try ApplyTranscription(sourceID: 1, track: 0, words: [w("hi", 0, 1)]).apply(to: p)
        expectRejected(AddDynamicCaption(at: 15, track: 2), on: p)  // busy within the 60 s span
        expectRejected(AddDynamicCaption(at: 0, track: 7), on: p)  // no such track
        expectRejected(AddDynamicCaption(audioClipID: 99), on: p)
        let cmd = AddDynamicCaption(at: 0, track: 1)
        try expectReversible(cmd, on: p)
        try cmd.apply(to: p)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks")?.array?.count == 3)
        #expect(at(p, "timeline/sceneTrack/scenes/0/csml/tracks/1/medias/0/_type")?.string == "Callout")
        try expectReversible(AddDynamicCaption(at: 0, track: 2), on: p)  // 0–60 s is free before 70 s

        let bare = try makeProject(tracks: [amFile(10, start: 0, dur: s(6))])
        expectRejected(AddDynamicCaption(audioClipID: 10), on: bare)  // convenience form needs words
        try expectReversible(AddDynamicCaption(at: 2), on: bare)      // the playhead form does not
    }

    @Test func setStyleRewritesOnlyCaptionKeys() throws {
        let p = try transcribed()
        let add = AddDynamicCaption(at: 1)
        try add.apply(to: p)
        let id = try #require(add.calloutID)
        let defPath = Self.calloutPath + "/def"
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
        #expect(def["width"]?.double == 1280)
        expectRejected(SetDynamicCaptionStyle(clipID: 10, style: style), on: p)
    }

    @Test func setStyleInsertsMissingKeysInOrder() throws {
        let p = try transcribed()
        let add = AddDynamicCaption(at: 1)
        try add.apply(to: p)
        let defPath = Self.calloutPath + "/def"
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
        #expect(keys[j - 1] == "dynamic-caption-preset-ID" && keys[j + 1] == "horizontal-alignment")
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
