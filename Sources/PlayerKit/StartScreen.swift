import Foundation
import ImageIO
import TSCProjKit

/// One row of the start screen's recent projects (`RecentProjects.list`).
public struct RecentProject: Equatable, Sendable, Identifiable {
    /// The project's `.cmproj` package or `.tscproj` file.
    public var url: URL
    /// Display name: the file name without its extension.
    public var name: String
    /// The folder holding the project, with the home folder shown as `~`.
    public var folder: String
    /// When the project was last saved (its `project.tscproj` for a package); nil when missing.
    public var modified: Date?
    /// False when the file is gone (shown dimmed, with Remove from List).
    public var exists: Bool

    public var id: String { url.standardizedFileURL.path }
}

/// The start screen's recent projects: the recent-documents list (most recent first) minus the
/// entries the user removed from the start screen, with names, folders, dates and thumbnails.
public enum RecentProjects {
    /// UserDefaults key: paths removed with Remove from List (AppKit has no API to drop one
    /// recent document). An entry is dropped again when the project is opened anew.
    public static let hiddenKey = "WizRec.HiddenRecentProjects"
    /// Argument-domain override for UI checks (`-WizRec.RecentProjects '("/tmp/a.cmproj")'`):
    /// these paths replace the system's recent documents, so a check never sees or changes the
    /// user's list.
    public static let overrideKey = "WizRec.RecentProjects"

    /// Rows for `urls` (most recent first) in that order, duplicates and `hidden` paths removed,
    /// keeping only projects (`.cmproj`/`.tscproj`). Missing files stay, with `exists` false.
    public static func list(_ urls: [URL], hidden: Set<String> = [], fileManager: FileManager = .default) -> [RecentProject] {
        var seen = Set<String>()
        var rows: [RecentProject] = []
        for raw in urls {
            let url = raw.standardizedFileURL
            let path = url.path
            guard OpenableFile(url) == .project, !hidden.contains(path), seen.insert(path).inserted else { continue }
            let exists = fileManager.fileExists(atPath: path)
            rows.append(RecentProject(url: url, name: url.deletingPathExtension().lastPathComponent,
                                      folder: abbreviate(url.deletingLastPathComponent().path),
                                      modified: exists ? modificationDate(of: url, fileManager: fileManager) : nil,
                                      exists: exists))
        }
        return rows
    }

    /// `path` with the home folder replaced by `~`.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The last save: `project.tscproj` inside a package (the package folder's own date does
    /// not change when the file inside is rewritten), else the file itself.
    public static func modificationDate(of url: URL, fileManager: FileManager = .default) -> Date? {
        let inner = url.appendingPathComponent("project.tscproj")
        var isDir: ObjCBool = false
        let target = fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? inner : url
        return (try? fileManager.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date
    }

    /// `hidden` without the paths no longer in `recents` (nothing to hide any more).
    public static func pruned(hidden: Set<String>, recents: [URL]) -> Set<String> {
        hidden.intersection(Set(recents.map { $0.standardizedFileURL.path }))
    }

    /// The image bytes of the project's own `metadata.ProjectThumbnail` (a PNG Camtasia writes
    /// on save; WizRec never writes one), or nil when it has none, it is not a decodable image,
    /// or the project cannot be read. Reads through TSCProjKit and writes nothing. Slow for
    /// big projects (parses the whole file): call off the main thread.
    public static func thumbnailData(projectAt url: URL) -> Data? {
        guard let bundle = try? ProjectBundle(url: url),
              let b64 = bundle.project.root["metadata"]?.object?["ProjectThumbnail"]?.string,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return data
    }

    /// Hue (0..<1) of the generated placeholder for a project without a thumbnail: stable for
    /// a name across launches (FNV-1a of the UTF-8 bytes; Swift's `hashValue` is seeded).
    public static func placeholderHue(for name: String) -> Double {
        var h: UInt32 = 2_166_136_261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Double(h % 360) / 360
    }
}

/// What the app shows at launch when no project was opened from the command line or Finder.
public enum LaunchWindow: Equatable, Sendable {
    /// Nothing (scripted and timed runs, or projects given on the command line).
    case none
    /// First-run onboarding (`WelcomeWindowController`); the start screen follows it.
    case onboarding
    /// The start screen (recent projects, New Project, New Recording, Open, Import).
    case startScreen
    /// The open panel ("Show start screen at launch" turned off).
    case openPanel
}

extension AppPreferences {
    /// The window for a launch with `options` that opened no document.
    /// Scripted runs (paths, `--snapshot-dir`, `--quit-after`, scripted steps) show nothing,
    /// unless `--start-screen` asks for the start screen (UI checks).
    public func launchWindow(for options: LaunchOptions) -> LaunchWindow {
        guard options.paths.isEmpty else { return .none }
        if options.startScreen { return .startScreen }
        guard !options.isScripted else { return .none }
        if showsWelcome(for: options) { return .onboarding }
        return showStartScreenAtLaunch ? .startScreen : .openPanel
    }
}

/// When the start screen comes back after a project window closes.
public enum StartScreenPolicy {
    /// True when the last project window just closed (`openDocuments` is 0) in an interactive
    /// run that is not quitting and shows no modal dialog. Timed and scripted runs never show
    /// it unless `--start-screen` was given. Independent of "Show start screen at launch".
    public static func showsAfterDocumentClosed(openDocuments: Int, terminating: Bool, modalShown: Bool,
                                                options: LaunchOptions) -> Bool {
        guard openDocuments == 0, !terminating, !modalShown else { return false }
        return options.startScreen || !options.isScripted
    }

    /// Whether opening a project adds it to File ▸ Open Recent and the start screen. Scripted
    /// and timed runs (UI checks, benchmarks on temporary copies) leave the list alone, so it
    /// never fills with temporary folders.
    public static func notesRecentDocuments(options: LaunchOptions) -> Bool {
        !options.isScripted && !options.startScreen
    }
}
