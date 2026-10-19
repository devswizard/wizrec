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

    public init() {}

    /// Parses `arguments` (without the executable path). Cocoa's own `-NSKey value`
    /// / `-AppleKey value` pairs and `-psn_…` are skipped.
    public init(arguments: [String]) {
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
            default:
                if a.hasPrefix("-psn_") { break }
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 1; break }
                if a.hasPrefix("-") { break }
                paths.append(a)
            }
            i += 1
        }
    }
}
