import Foundation

/// A `.cmproj` package (macOS) or a bare `.tscproj` (Windows / exported).
///
/// `.cmproj` layout:
/// ```
/// Foo.cmproj/
///   project.tscproj     timeline JSON
///   ~project.tscproj    0-byte marker Camtasia writes while the project is open
///   docPrefs            plist: editor UI state (panels, zoom, scroll)
///   bookmarks.plist     plist: security-scoped bookmarks to linked media
///   media/<ts>/…        imported files
///   recordings/<ts>/…   .trec screen recordings
///   audiate/            Audiate link data
/// ```
public struct ProjectBundle {
    /// The `.cmproj` folder, or the directory holding a bare `.tscproj`.
    public let directory: URL
    public let projectFile: URL
    public let project: Project

    public init(url: URL) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            directory = url
            projectFile = url.appendingPathComponent("project.tscproj")
            guard FileManager.default.fileExists(atPath: projectFile.path) else {
                throw ProjectError.missingProjectFile(url)
            }
        } else {
            directory = url.deletingLastPathComponent()
            projectFile = url
        }
        project = try Project(contentsOf: projectFile)
    }

    /// Absolute URL for a source's `src`.
    public func resolve(_ source: SourceMedia) -> URL {
        let src = source.src
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
        if let u = URL(string: src), u.scheme == "file" { return u }
        return directory.appendingPathComponent(src).standardizedFileURL
    }

    /// Sources whose file is missing on this machine — the usual problem
    /// when a project comes from another device.
    public func missingMedia() -> [SourceMedia] {
        project.sourceBin.filter { !FileManager.default.fileExists(atPath: resolve($0).path) }
    }

    /// Writes the project atomically. Untouched keys are preserved.
    public func save(to url: URL? = nil) throws {
        try project.serialized().write(to: url ?? projectFile, options: .atomic)
    }
}
