import Foundation
import UniformTypeIdentifiers

/// What File ▸ Open (and a Finder or Dock open) does with a file. Decided by the file name
/// extension, so another app's type declaration for that extension (Camtasia's own `.cmproj`
/// and `.tscproj` types, when it is installed) never hides a project from WizRec.
public enum OpenableFile: Equatable, Sendable {
    /// A `.cmproj` package or a `.tscproj` file: opened as a project.
    case project
    /// A video, audio or image file (or a `.trec` recording): opened as a new project with the
    /// file on the timeline.
    case media

    /// Nil when WizRec cannot open `url`.
    public init?(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "cmproj", "tscproj":
            self = .project
        case "trec":
            self = .media
        default:
            guard let type = UTType(filenameExtension: ext),
                  type.conforms(to: .audiovisualContent) || type.conforms(to: .image) else { return nil }
            self = .media
        }
    }
}
