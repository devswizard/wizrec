import PlayerKit
import Testing

/// `--quit-after` runs never wait for the user: quitting drops unsaved edits; everything else asks.
struct QuitPolicyTests {
    @Test func quitAfterRunsDiscardUnsavedEdits() {
        for args in [["p.cmproj", "--import", "a.mp4", "--quit-after", "25"],
                     ["p.cmproj", "--quit-after", "3"],
                     ["--quit-after", "0", "p.cmproj", "--export", "/tmp/x.mp4"]] {
            #expect(LaunchOptions(arguments: args).unsavedEditsOnQuit == .discard, "\(args)")
        }
    }

    /// Interactive use keeps the save/don't save/cancel review, and so do scripted steps
    /// without `--quit-after` (a person may be watching that run).
    @Test func otherRunsAsk() {
        for args in [[String](), ["p.cmproj"], ["p.cmproj", "--autoplay"],
                     ["p.cmproj", "--import", "a.mp4"], ["p.cmproj", "--import", "a.mp4", "--save"],
                     ["p.cmproj", "-WizRec.ExportFolder", "/tmp/out"]] {
            #expect(LaunchOptions(arguments: args).unsavedEditsOnQuit == .ask, "\(args)")
        }
        // An unparsable value is no timed quit.
        #expect(LaunchOptions(arguments: ["p.cmproj", "--quit-after", "soon"]).unsavedEditsOnQuit == .ask)
    }

    @Test func discardNoticeIsOneLineNamingTheDocuments() throws {
        #expect(UnsavedEditsOnQuit.discardNotice(documents: []) == nil)
        let line = try #require(UnsavedEditsOnQuit.discardNotice(documents: ["demo.cmproj", "b.tscproj"]))
        #expect(!line.contains("\n"))
        #expect(line.contains("--quit-after") && line.contains("demo.cmproj, b.tscproj"))
        #expect(line.contains("discarded unsaved edits"))
    }
}
