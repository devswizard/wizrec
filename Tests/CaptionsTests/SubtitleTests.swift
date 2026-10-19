import Testing
@testable import Captions

@Suite struct SRTTests {
    @Test func parsesBasicFile() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello world\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\nlines\n"
        let cues = try SubtitleFile.parseSRT(srt)
        #expect(cues == [CaptionCue(start: 1, end: 2.5, text: "Hello world"), CaptionCue(start: 3, end: 4, text: "Two\nlines")])
    }

    @Test func toleratesBOMCRLFMissingIndicesAndBlankLines() throws {
        let srt = "\u{FEFF}\r\n\r\n00:00:01.5 --> 00:00:02,000\r\n<i>First</i>\r\n\r\n\r\n7\r\n00:01:00,000 --> 01:00:00,250 X1:10 X2:20 Y1:1 Y2:2\r\n{\\an8}Second &amp; more\r\n3\r\n00:02:00,000 --> 00:02:01,000\r\nThird\r\n"
        let doc = try SubtitleDocument.parseSRT(srt)
        #expect(doc.cues.map(\.identifier) == [nil, "7", "3"])
        #expect(doc.cues[1].settings == "X1:10 X2:20 Y1:1 Y2:2")
        #expect(doc.captionCues == [CaptionCue(start: 1.5, end: 2, text: "First"),
                                    CaptionCue(start: 60, end: 3600.25, text: "Second & more"),
                                    CaptionCue(start: 120, end: 121, text: "Third")])
    }

    @Test func roundTripsDocument() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,500\n<b>Bold</b> text\n\n2\n00:00:03,000 --> 00:00:04,000 X1:1\nTwo\nlines\n"
        #expect(try SubtitleDocument.parseSRT(srt).text() == srt)
    }

    @Test func writesNumberedCues() throws {
        let cues = [CaptionCue(start: 0, end: 1.2345, text: "A"), CaptionCue(start: 3661.001, end: 3662, text: "B\n\nC --> D")]
        let out = SubtitleFile.srt(cues)
        #expect(out == "1\n00:00:00,000 --> 00:00:01,235\nA\n\n2\n01:01:01,001 --> 01:01:02,000\nB\nC -> D\n")
        #expect(try SubtitleFile.parseSRT(out).map(\.text) == ["A", "B\nC -> D"])
    }

    @Test func rejectsGarbage() throws {
        #expect(throws: CaptionsError.self) { try SubtitleFile.parseSRT("not a subtitle file") }
        #expect(try SubtitleFile.parseSRT("\n\n").isEmpty)
    }
}

@Suite struct VTTTests {
    static let file = """
    WEBVTT - Example
    Kind: captions

    STYLE
    ::cue { color: yellow }

    NOTE a comment
    spanning lines

    intro
    00:01.000 --> 00:02.000 align:start line:0
    <v Bob>Hi &lt;there&gt;</v>

    00:00:03.500 --> 00:00:05.000
    <c.loud>Second</c> cue

    """

    @Test func parsesCuesSettingsAndBlocks() throws {
        let doc = try SubtitleDocument.parseVTT(Self.file)
        #expect(doc.header == "- Example\nKind: captions")
        #expect(doc.blocks.count == 4)
        #expect(doc.cues[0].identifier == "intro")
        #expect(doc.cues[0].settings == "align:start line:0")
        #expect(doc.captionCues == [CaptionCue(start: 1, end: 2, text: "Hi <there>"), CaptionCue(start: 3.5, end: 5, text: "Second cue")])
    }

    @Test func roundTripsDocumentModuloTimestampForm() throws {
        let doc = try SubtitleDocument.parseVTT(Self.file)
        let again = try SubtitleDocument.parseVTT(doc.text())
        #expect(again == doc)
        #expect(doc.text().contains("NOTE a comment\nspanning lines\n\nintro\n00:00:01.000 --> 00:00:02.000 align:start line:0\n<v Bob>Hi &lt;there&gt;</v>\n"))
    }

    @Test func crlfAndBOM() throws {
        let cues = try SubtitleFile.parseVTT("\u{FEFF}WEBVTT\r\n\r\n00:00.000 --> 00:01.000\r\nA\r\n")
        #expect(cues == [CaptionCue(start: 0, end: 1, text: "A")])
    }

    @Test func requiresSignature() {
        #expect(throws: CaptionsError.self) { try SubtitleFile.parseVTT("WEBVTTX\n\n00:00.000 --> 00:01.000\nA\n") }
        #expect(throws: CaptionsError.self) { try SubtitleFile.parseVTT("1\n00:00:00,000 --> 00:00:01,000\nA\n") }
    }

    @Test func writesEscapedText() throws {
        let out = SubtitleFile.vtt([CaptionCue(start: 0.5, end: 1, text: "Tom & <Jerry>")])
        #expect(out == "WEBVTT\n\n00:00:00.500 --> 00:00:01.000\nTom &amp; &lt;Jerry&gt;\n")
        #expect(try SubtitleFile.parseVTT(out) == [CaptionCue(start: 0.5, end: 1, text: "Tom & <Jerry>")])
        #expect(SubtitleFile.vtt([]) == "WEBVTT\n")
    }

    @Test func convertsBetweenFormats() throws {
        let doc = try SubtitleDocument.parseVTT(Self.file)
        let srt = doc.text(.srt)
        #expect(srt.hasPrefix("1\n00:00:01,000 --> 00:00:02,000\n<v Bob>"))
        #expect(try SubtitleFile.parseSRT(srt).map(\.text) == ["Hi <there>", "Second cue"])
    }
}
