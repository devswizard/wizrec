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

    // MARK: Several documents (APP11-2: the ⌘Q unsaved-documents review and the timed quit)

    @MainActor @Test func discardClearsEveryEditedDocumentAndLogsOneLine() throws {
        let docs = [FakeDocument("a.cmproj", edited: true), FakeDocument("b.cmproj", edited: false),
                    FakeDocument("c.tscproj", edited: true)]
        let policy = LaunchOptions(arguments: ["a.cmproj", "b.cmproj", "c.tscproj", "--quit-after", "5"]).unsavedEditsOnQuit
        #expect(policy == .discard)
        let line = try #require(policy.prepareQuit(docs))
        #expect(line.contains("a.cmproj, c.tscproj") && !line.contains("b.cmproj"))
        #expect(docs.allSatisfy { !$0.hasUnsavedEdits }, "a document would still ask on quit")
        #expect(docs.map(\.discards) == [1, 0, 1])
        // The timed quit and the review AppKit runs for the same quit both apply the policy:
        // the second pass finds nothing to drop and logs nothing.
        #expect(policy.prepareQuit(docs) == nil)
        #expect(docs.map(\.discards) == [1, 0, 1])
    }

    @MainActor @Test func askLeavesEditedDocumentsForTheReview() {
        let docs = [FakeDocument("a.cmproj", edited: true), FakeDocument("b.cmproj", edited: true)]
        #expect(LaunchOptions(arguments: ["a.cmproj", "b.cmproj"]).unsavedEditsOnQuit.prepareQuit(docs) == nil)
        #expect(docs.allSatisfy { $0.hasUnsavedEdits })
        #expect(docs.allSatisfy { $0.discards == 0 })
    }

    @MainActor @Test func discardWithNothingEditedLogsNothing() {
        let docs = [FakeDocument("a.cmproj", edited: false), FakeDocument("b.cmproj", edited: false)]
        #expect(UnsavedEditsOnQuit.discard.prepareQuit(docs) == nil)
        #expect(UnsavedEditsOnQuit.discard.prepareQuit([]) == nil)
    }
}

/// Stand-in for the app's `ProjectDocument`.
@MainActor private final class FakeDocument: QuitReviewedDocument {
    let quitDisplayName: String
    private(set) var hasUnsavedEdits: Bool
    private(set) var discards = 0
    init(_ name: String, edited: Bool) {
        quitDisplayName = name
        hasUnsavedEdits = edited
    }
    func discardEditsForQuit() {
        discards += 1
        hasUnsavedEdits = false
    }
}
