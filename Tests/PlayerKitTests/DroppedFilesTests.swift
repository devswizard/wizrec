import Foundation
import Testing
@testable import PlayerKit

@Suite struct DroppedFilesTests {
    private func u(_ p: String) -> URL { URL(fileURLWithPath: "/tmp/drop/\(p)") }

    @Test func sortsProjectsMediaAndTheRest() {
        let folders: Set<String> = ["Clips", "demo.cmproj", "odd.mov"]
        let isFolder: (URL) -> Bool = { folders.contains($0.lastPathComponent) }
        let d = DroppedFiles([u("a.mp4"), u("demo.cmproj"), u("notes.txt"), u("voice.m4a"), u("Clips"), u("shot.png"),
                              u("rec.trec"), u("bg.tscshadervid"), u("p.tscproj"), u("odd.mov")], isFolder: isFolder)
        #expect(d.projects == [u("demo.cmproj"), u("p.tscproj")])
        #expect(d.media == [u("a.mp4"), u("voice.m4a"), u("shot.png"), u("rec.trec"), u("bg.tscshadervid")])
        #expect(d.unsupported == [u("notes.txt"), u("Clips"), u("odd.mov")])
    }

    @Test func messagesSayWhatWentWrong() {
        let none = DroppedFiles([u("a.mp4")], isFolder: { _ in false })
        #expect(none.unsupportedMessage(isFolder: { _ in false }) == nil)

        let file = DroppedFiles([u("notes.txt")], isFolder: { _ in false })
        #expect(file.unsupportedMessage(isFolder: { _ in false })
            == "“notes.txt” can’t be added: WizRec imports video, audio and image files.")

        let folder = DroppedFiles([u("Clips")], isFolder: { _ in true })
        #expect(folder.unsupportedMessage(isFolder: { _ in true }) == "“Clips” is a folder. Drop the media files inside it instead.")

        let many = DroppedFiles([u("a.txt"), u("b.doc"), u("c.zip"), u("d.key"), u("e.pdf")], isFolder: { _ in false })
        let text = many.unsupportedMessage(isFolder: { _ in false }) ?? ""
        #expect(text.hasPrefix("5 items can’t be added (“a.txt”, “b.doc”, “c.zip” and 2 more)"))
    }

    @Test func unreadableMediaIsExplained() {
        let text = DocumentError.unsupportedMedia("clip.mp4").description
        #expect(text == "WizRec can’t read “clip.mp4”. The file may be damaged, or its format isn’t supported.")
    }
}
