import Foundation
import Testing
import PlayerKit

/// File ▸ Open decides by extension: projects stay openable when another app owns their type.
@Suite struct OpenableFileTests {
    @Test(arguments: ["a.cmproj", "b.tscproj", "C.CMPROJ", "My Vlog.cmproj"])
    func projectsOpenAsProjects(_ name: String) {
        #expect(OpenableFile(URL(fileURLWithPath: "/tmp/\(name)")) == .project)
    }

    @Test(arguments: ["v.mp4", "v.MOV", "a.m4a", "a.wav", "i.png", "i.jpg", "r.trec"])
    func mediaOpensAsNewProject(_ name: String) {
        #expect(OpenableFile(URL(fileURLWithPath: "/tmp/\(name)")) == .media)
    }

    @Test(arguments: ["notes.txt", "archive.zip", "Tool.app", "noextension", "data.json"])
    func otherFilesAreNotOpenable(_ name: String) {
        #expect(OpenableFile(URL(fileURLWithPath: "/tmp/\(name)")) == nil)
    }
}
