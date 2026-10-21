import Foundation

/// Files dropped on (or chosen for) an open project, sorted by what the editor does with them:
/// projects open in their own window, media is imported, the rest is reported in plain words.
public struct DroppedFiles: Equatable, Sendable {
    /// `.cmproj` packages and `.tscproj` files.
    public var projects: [URL] = []
    /// Video, audio, image, `.trec` and `.tscshadervid` files.
    public var media: [URL] = []
    /// Folders (other than projects) and files of other types.
    public var unsupported: [URL] = []

    public init(projects: [URL] = [], media: [URL] = [], unsupported: [URL] = []) {
        self.projects = projects; self.media = media; self.unsupported = unsupported
    }

    /// Sorts `urls` in order. `isFolder` tells folders apart (a folder named like a media file is
    /// still a folder).
    public init(_ urls: [URL], isFolder: (URL) -> Bool = DroppedFiles.isFolder) {
        for url in urls {
            switch OpenableFile(url) {
            case .project?: projects.append(url)
            case .media? where !isFolder(url): media.append(url)
            default:
                if url.pathExtension.lowercased() == "tscshadervid", !isFolder(url) { media.append(url) }
                else { unsupported.append(url) }
            }
        }
    }

    /// True for an existing directory.
    public static func isFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    /// One plain sentence about `unsupported` (nil when empty), e.g. "“notes.txt” can’t be added:
    /// WizRec imports video, audio and image files."
    public func unsupportedMessage(isFolder: (URL) -> Bool = DroppedFiles.isFolder) -> String? {
        guard let first = unsupported.first else { return nil }
        if unsupported.count == 1 {
            let name = first.lastPathComponent
            if isFolder(first) {
                return String(localized: "“\(name)” is a folder. Drop the media files inside it instead.")
            }
            return String(localized: "“\(name)” can’t be added: WizRec imports video, audio and image files.")
        }
        let names = unsupported.prefix(3).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
        let more = unsupported.count > 3 ? String(localized: " and \(unsupported.count - 3) more") : ""
        return String(localized: "\(unsupported.count) items can’t be added (\(names)\(more)): WizRec imports video, audio and image files, not folders or other documents.")
    }
}
