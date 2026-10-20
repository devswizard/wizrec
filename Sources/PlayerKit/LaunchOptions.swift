import Foundation

/// Command-line options of the app: project paths plus debug switches.
///
/// `WizRec [options] <project.cmproj|.tscproj>…`
/// - `--autoplay`: start playing after opening.
/// - `--seek <seconds>`: open at this time.
/// - `--stats-log`: print playback stats once per second to stdout.
/// - `--overlay`: show the performance overlay.
/// - `--no-audio`: play silently on the host clock.
/// - `--quit-after <seconds>`: quit this long after launch (benchmarks).
/// - `--snapshot-dir <dir>` / `--snapshot-at <s,s,…>`: write window snapshots (verification).
/// - `--draw-always`: redraw every refresh (render-loop stress test).
/// - `--import <file>` (repeatable): import and place at the playhead (scripted verification).
/// - `--nudge <dx,dy>`: move the imported/selected clip by canvas px.
/// - `--select-last`: select the last clip when nothing else is selected (shows the inspector).
/// - `--save`: File ▸ Save after the scripted steps.
/// - `--frame-policy exact|thin|nearest`: high-speed playback policy (default nearest).
/// - `--import-captions <file.srt|.vtt>`: import captions after the scripted imports.
/// - `--export-captions <file.srt|.vtt>`: write the project's captions after the scripted steps.
/// - `--export <file>` [`--export-preset <name>`…]: export through the queue after the scripted steps,
///   then report. Without a preset, the first built-in preset whose extension matches `<file>`; with
///   several presets, each writes `<file>`'s folder and name with its own extension.
public struct LaunchOptions: Sendable, Equatable {
    public var paths: [String] = []
    public var autoplay = false
    public var seekSeconds: Double?
    public var statsLog = false
    public var overlay = false
    public var audio = true
    public var quitAfter: Double?
    /// Where window snapshots go (PNG). Snapshots are taken at `snapshotTimes`
    /// (timeline seconds) once frames are decoded, then every 4 s while autoplaying.
    public var snapshotDir: String?
    public var snapshotTimes: [Double] = []
    /// Redraw on every display refresh even when nothing changed (render-loop stress test).
    public var drawAlways = false
    /// Files to import and place at the playhead after opening.
    public var importPaths: [String] = []
    /// Canvas px to move the selected clip by after the imports.
    public var nudge: (x: Double, y: Double)?
    /// Select the last clip if nothing is selected (inspector snapshot).
    public var select = false
    /// Save after the scripted steps.
    public var save = false
    /// High-speed policy: "exact" (off), "thin" (subsample only), "nearest" (thin + `.nearestDecoded`).
    public var framePolicy = "nearest"
    /// SRT/WebVTT file to import as captions (scripted verification).
    public var importCaptions: String?
    /// Where to export the project's captions (format from the extension).
    public var exportCaptions: String?
    /// Export output file (scripted export).
    public var exportPath: String?
    /// Export preset names (batch); empty = chosen from `exportPath`'s extension.
    public var exportPresets: [String] = []

    public init() {}

    /// Scripted steps run after opening (snapshots, imports, captions, export).
    public var runsScript: Bool {
        snapshotDir != nil || !importPaths.isEmpty || importCaptions != nil || exportCaptions != nil || exportPath != nil
    }

    /// A scripted or timed run (`runsScript` or `--quit-after`): nothing may wait for the user,
    /// so no sheets or confirmations are shown.
    public var isScripted: Bool { runsScript || quitAfter != nil }

    /// Whether opening a project with `missing` unresolved media shows Relink Missing Media.
    public func showsRelinkAtOpen(missing: Int) -> Bool { missing > 0 && !isScripted }

    public static func == (a: LaunchOptions, b: LaunchOptions) -> Bool {
        a.paths == b.paths && a.autoplay == b.autoplay && a.seekSeconds == b.seekSeconds && a.statsLog == b.statsLog
            && a.overlay == b.overlay && a.audio == b.audio && a.quitAfter == b.quitAfter
            && a.snapshotDir == b.snapshotDir && a.snapshotTimes == b.snapshotTimes && a.drawAlways == b.drawAlways
            && a.importPaths == b.importPaths && a.nudge?.x == b.nudge?.x && a.nudge?.y == b.nudge?.y
            && a.select == b.select && a.save == b.save && a.framePolicy == b.framePolicy
            && a.importCaptions == b.importCaptions && a.exportCaptions == b.exportCaptions
            && a.exportPresets == b.exportPresets && a.exportPath == b.exportPath
    }

    /// Parses `arguments` (without the executable path). `-psn_…` and Cocoa's `-Key value`
    /// argument-domain pairs (`-NSKey value`, `-WizRec.ExportFolder <dir>`, …) are skipped.
    public init(arguments: [String]) { self.init(arguments: arguments, base: LaunchOptions()) }

    /// Parses `arguments` on top of `base` (e.g. values from `AppPreferences`).
    public init(arguments: [String], base: LaunchOptions) {
        self = base
        var i = 0
        func value() -> String? {
            i += 1
            return i < arguments.count ? arguments[i] : nil
        }
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--autoplay": autoplay = true
            case "--stats-log": statsLog = true
            case "--overlay": overlay = true
            case "--no-audio": audio = false
            case "--seek": seekSeconds = value().flatMap(Double.init)
            case "--quit-after": quitAfter = value().flatMap(Double.init)
            case "--snapshot-dir": snapshotDir = value()
            case "--snapshot-at":
                snapshotTimes = (value() ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            case "--draw-always": drawAlways = true
            case "--import": if let v = value() { importPaths.append(v) }
            case "--nudge":
                let xy = (value() ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if xy.count == 2 { nudge = (xy[0], xy[1]) }
            case "--select-last": select = true
            case "--save": save = true
            case "--frame-policy": framePolicy = value() ?? framePolicy
            case "--import-captions": importCaptions = value()
            case "--export-captions": exportCaptions = value()
            case "--export": exportPath = value()
            case "--export-preset": if let v = value() { exportPresets.append(v) }
            default:
                if a.hasPrefix("-psn_") { break }
                // `-Key value`: an NSArgumentDomain default (e.g. `-NSDocumentRevisionsDebugMode YES`,
                // `-WizRec.ExportFolder /tmp/x`); its value is not a project path.
                if a.count > 1, a.hasPrefix("-"), !a.hasPrefix("--") { i += 1; break }
                if a.hasPrefix("-") { break }
                paths.append(a)
            }
            i += 1
        }
    }
}
