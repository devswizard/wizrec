// M2 additions to ProjectBundle (writing side), frozen by coordination/CONTRACTS.md.

import Foundation

public enum BundleWriteError: Error, Equatable {
    case notImplemented
    case exists(URL)
    case copyFailed(String)
}

extension ProjectBundle {
    /// Version written to `authoringClientName.version` in projects WizRec creates.
    public static let authoringVersion = "0.1.0"

    /// Name of the copy of the previous `project.tscproj` kept by `saveWithBackup`.
    public static let backupSuffix = ".wizrec-backup"

    /// Creates a new empty `.cmproj` at `url`: format `10.0`, editRate 705600000,
    /// canvas `width`×`height` px at `fps`, one empty track. Fails if `url` exists.
    public static func create(at url: URL, width: Int = 1920, height: Int = 1080,
                              fps: Int = 30) throws -> ProjectBundle {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw BundleWriteError.exists(url) }
        guard width > 0, height > 0, fps > 0 else { throw BundleWriteError.copyFailed("invalid canvas or frame rate") }
        let project = ProjectTemplate.newProject(width: width, height: height, fps: fps)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            try fm.createDirectory(at: url.appendingPathComponent("media"), withIntermediateDirectories: false)
            let file = url.appendingPathComponent("project.tscproj")
            try project.serialized().write(to: file, options: .atomic)
            return ProjectBundle(directory: url, projectFile: file, project: project, isPackage: true)
        } catch {
            try? fm.removeItem(at: url)
            throw BundleWriteError.copyFailed("create \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Copies `file` into `media/<unix-ts>/` inside the bundle and returns its
    /// project-relative `src` (e.g. `"./media/1792376869.292854/clip.mp4"`).
    /// Bare `.tscproj` projects return a path relative to the project's folder without copying.
    ///
    /// - `<unix-ts>` is seconds since 1970 with six decimals (µs), as Camtasia
    ///   names these folders [obs]. If that folder already exists the stamp is
    ///   bumped by 1 µs until it is free, so two imports never share a folder.
    /// - A file that already lies inside the bundle is not copied again; its
    ///   bundle-relative path is returned.
    /// - Bare projects: `./sub/clip.mp4` for files under the project's folder,
    ///   otherwise a `../`-relative path.
    public func importFile(_ file: URL) throws -> String {
        let fm = FileManager.default
        let source = file.standardizedFileURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: source.path) else {
            throw BundleWriteError.copyFailed("no such file: \(file.path)")
        }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard isPackage else { return Self.relativePath(of: source, from: base) }
        if Self.isInside(source, base) { return Self.relativePath(of: source, from: base) }

        let media = directory.appendingPathComponent("media")
        var micros = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
        var folder: URL
        repeat {
            folder = media.appendingPathComponent(Self.stamp(micros))
            micros += 1
        } while fm.fileExists(atPath: folder.path)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        } catch {
            try? fm.removeItem(at: folder)
            throw BundleWriteError.copyFailed("import \(source.lastPathComponent): \(error.localizedDescription)")
        }
        return "./media/\(folder.lastPathComponent)/\(source.lastPathComponent)"
    }

    /// Saves atomically and keeps the previous `project.tscproj` as
    /// `project.tscproj.wizrec-backup` (overwritten on each save).
    ///
    /// The backup is written (atomically) before the project is replaced, so
    /// a failure at any point leaves either the old project or the new one in
    /// place, never a partial file. No backup is made when there is no
    /// previous file.
    public func saveWithBackup() throws {
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: projectFile.path + Self.backupSuffix)
        if fm.fileExists(atPath: projectFile.path) {
            do {
                try Data(contentsOf: projectFile).write(to: backup, options: .atomic)
            } catch {
                throw BundleWriteError.copyFailed("backup: \(error.localizedDescription)")
            }
        }
        try project.serialized().write(to: projectFile, options: .atomic)
    }

    /// Writes the project to a new location and returns the bundle there.
    ///
    /// - Package: copies the whole `.cmproj` (media/, recordings/, docPrefs,
    ///   bookmarks.plist, audiate/, …) to `url`, skipping `~project.tscproj`
    ///   and `*.wizrec-backup`, then writes `project.tscproj` atomically
    ///   there. Relative `src` paths keep working because the media moves too.
    /// - Bare `.tscproj`: writes only the new file at `url`. `src` paths are
    ///   left untouched, so relative paths now resolve against `url`'s folder;
    ///   when that folder differs the app must warn or copy the media
    ///   (`missingMedia()` on the result reports what no longer resolves).
    ///
    /// The returned bundle shares this bundle's `Project` instance, so undo
    /// history stays valid. Throws `.exists` if `url` exists.
    public func saveAs(to url: URL) throws -> ProjectBundle {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw BundleWriteError.exists(url) }
        guard isPackage else {
            try project.serialized().write(to: url, options: .atomic)
            return ProjectBundle(directory: url.deletingLastPathComponent(), projectFile: url,
                                 project: project, isPackage: false)
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            let items = try fm.contentsOfDirectory(atPath: directory.path)
            for name in items where !Self.skippedOnSaveAs(name) {
                try fm.copyItem(at: directory.appendingPathComponent(name), to: url.appendingPathComponent(name))
            }
            let file = url.appendingPathComponent("project.tscproj")
            try project.serialized().write(to: file, options: .atomic)
            return ProjectBundle(directory: url, projectFile: file, project: project, isPackage: true)
        } catch {
            try? fm.removeItem(at: url)
            throw BundleWriteError.copyFailed("save as \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func skippedOnSaveAs(_ name: String) -> Bool {
        name == "project.tscproj" || name == "~project.tscproj" || name.hasSuffix(backupSuffix)
            || name == ".DS_Store"
    }

    /// `"1792376869.292854"` for 1792376869292854 µs.
    static func stamp(_ micros: Int64) -> String {
        let s = micros / 1_000_000, f = micros % 1_000_000
        return "\(s)." + String(repeating: "0", count: 6 - String(f).count) + String(f)
    }

    static func isInside(_ file: URL, _ dir: URL) -> Bool {
        let d = dir.pathComponents, f = file.pathComponents
        return f.count > d.count && Array(f.prefix(d.count)) == d
    }

    /// `./a/b.mp4` under `dir`, else `../x/b.mp4`.
    static func relativePath(of file: URL, from dir: URL) -> String {
        let d = dir.pathComponents, f = file.pathComponents
        var common = 0
        while common < d.count, common < f.count - 1, d[common] == f[common] { common += 1 }
        let ups = d.count - common
        let rest = f[common...].joined(separator: "/")
        return ups == 0 ? "./" + rest : String(repeating: "../", count: ups) + rest
    }
}

/// Builders for the JSON that Camtasia 2026 (format 10.0) writes for a new
/// project and new tracks. Key names and order follow the user's own
/// projects (`demo project.cmproj`, the vlog) [obs].
public enum ProjectTemplate {
    /// A new empty project: format `10.0`, editRate 705600000, canvas
    /// `width`×`height` px, `fps` frames per second, one empty track,
    /// `authoringClientName` = WizRec / Mac / `ProjectBundle.authoringVersion`.
    public static func newProject(width: Int, height: Int, fps: Int,
                                  version: String = ProjectBundle.authoringVersion) -> Project {
        let timeline = JSONObject([
            ("id", int(1)),
            ("sceneTrack", obj([("scenes", arr([obj([("csml", obj([("tracks", arr([.object(track(index: 0))]))]))])]))])),
            ("trackAttributes", arr([.object(trackAttributes())])),
            ("parameters", obj([])),
            ("captionAttributes", obj([
                ("enabled", .bool(true)), ("fontName", .string("Arial")), ("fontSize", int(32)),
                ("backgroundColor", arr([int(0), int(0), int(0), int(204)])),
                ("foregroundColor", arr([int(255), int(255), int(255), int(255)])),
                ("lang", .string("en")), ("alignment", int(0)), ("defaultFontSize", .bool(true)),
                ("opacity", dbl(0.5)), ("backgroundEnabled", .bool(true)),
                ("backgroundOnlyAroundText", .bool(true)),
            ])),
            ("gain", dbl(1)),
            ("legacyAttenuateAudioMix", .bool(false)),
            ("backgroundColor", arr([int(0), int(0), int(0), int(255)])),
        ])
        let root = JSONObject([
            ("title", .string("")), ("description", .string("")), ("author", .string("")),
            ("targetLoudness", dbl(-18)), ("shouldApplyLoudnessNormalization", .bool(true)),
            ("videoFormatFrameRate", int(fps)), ("audioFormatSampleRate", int(44100)),
            ("allowSubFrameEditing", .bool(false)),
            ("width", dbl(Double(width))), ("height", dbl(Double(height))),
            ("version", .string("10.0")), ("editRate", int(705_600_000)),
            ("authoringClientName", obj([
                ("name", .string("WizRec")), ("platform", .string("Mac")), ("version", .string(version)),
            ])),
            ("sourceBin", arr([])),
            ("timeline", .object(timeline)),
            ("metadata", obj([
                ("RulerGuidesX", arr([])), ("RulerGuidesY", arr([])),
                ("RulerShowing", obj([("type", .string("bool")), ("value", .bool(false))])),
                ("projectDuration", .string("00:00")),
            ])),
        ])
        return Project(root: root)
    }

    /// A top-level scene track: `{trackIndex, medias: [], parameters: {}}`.
    public static func track(index: Int) -> JSONObject {
        JSONObject([("trackIndex", int(index)), ("medias", arr([])), ("parameters", obj([]))])
    }

    /// A `timeline.trackAttributes` entry with every flag off.
    public static func trackAttributes() -> JSONObject {
        JSONObject([
            ("ident", .string("")), ("audioMuted", .bool(false)), ("videoHidden", .bool(false)),
            ("magnetic", .bool(false)), ("matte", int(0)), ("solo", .bool(false)),
            ("metadata", obj([("IsLocked", .string("False")), ("trackHeight", .string("56"))])),
        ])
    }

    /// A track inside a `Group`: flags inline on the track object [obs, demo].
    public static func groupTrack(index: Int) -> JSONObject {
        JSONObject([
            ("trackIndex", int(index)), ("medias", arr([])), ("parameters", obj([])),
            ("ident", .string("")), ("audioMuted", .bool(false)), ("videoHidden", .bool(false)),
            ("magnetic", .bool(false)), ("matte", int(0)), ("solo", .bool(false)),
        ])
    }

    private static func int(_ v: Int) -> JSON { .number(JSONNumber(v)) }
    private static func dbl(_ v: Double) -> JSON { .number(JSONNumber(v)) }
    private static func arr(_ v: [JSON]) -> JSON { .array(JSONArray(v)) }
    private static func obj(_ pairs: [(String, JSON)]) -> JSON { .object(JSONObject(pairs)) }
}
