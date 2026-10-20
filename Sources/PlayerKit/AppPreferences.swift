import Foundation

/// The app's user preferences, stored in `UserDefaults` under `Key` (never in projects).
/// Command-line switches override them for one launch (`launchOptions(arguments:)`).
public struct AppPreferences: Sendable, Equatable {
    /// High-speed playback policy (see `LaunchOptions.framePolicy`).
    public enum FramePolicy: String, CaseIterable, Sendable {
        /// Decode every frame (may stutter at high clip speeds).
        case exact
        /// Show a subset of frames when decoding cannot keep up.
        case thin
        /// Thin, and show the nearest already-decoded frame while seeking.
        case nearest
    }

    /// UserDefaults keys (also used by the Settings window's `@AppStorage`).
    public enum Key {
        public static let onboardingCompleted = "WizRec.OnboardingCompleted"
        public static let showWelcomeAtLaunch = "WizRec.ShowWelcomeAtLaunch"
        public static let crashLogsEnabled = "WizRec.CrashLogsEnabled"
        public static let playAudio = "WizRec.PlayAudio"
        public static let framePolicy = "WizRec.FramePolicy"
        public static let showPerformanceOverlay = "WizRec.ShowPerformanceOverlay"
        public static let warnUnsignedBackgrounds = "WizRec.WarnUnsignedBackgrounds"
    }

    /// The welcome window was finished once (it then shows only if `showWelcomeAtLaunch`).
    public var onboardingCompleted = false
    public var showWelcomeAtLaunch = false
    /// Opt-in: write crash reports to `~/Library/Logs/WizRec` (local only, never sent).
    public var crashLogsEnabled = false
    public var playAudio = true
    public var framePolicy: FramePolicy = .nearest
    public var showPerformanceOverlay = false
    /// Saving a project with WizRec backgrounds says Camtasia won't show them (`BackgroundSaveNotice`).
    public var warnUnsignedBackgrounds = true

    public init() {}

    /// Values stored in `defaults`; missing or invalid entries keep the defaults above.
    public static func load(from defaults: UserDefaults) -> AppPreferences {
        var p = AppPreferences()
        func bool(_ k: String, _ v: inout Bool) { if defaults.object(forKey: k) != nil { v = defaults.bool(forKey: k) } }
        bool(Key.onboardingCompleted, &p.onboardingCompleted)
        bool(Key.showWelcomeAtLaunch, &p.showWelcomeAtLaunch)
        bool(Key.crashLogsEnabled, &p.crashLogsEnabled)
        bool(Key.playAudio, &p.playAudio)
        bool(Key.showPerformanceOverlay, &p.showPerformanceOverlay)
        bool(Key.warnUnsignedBackgrounds, &p.warnUnsignedBackgrounds)
        if let s = defaults.string(forKey: Key.framePolicy), let f = FramePolicy(rawValue: s) { p.framePolicy = f }
        return p
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted)
        defaults.set(showWelcomeAtLaunch, forKey: Key.showWelcomeAtLaunch)
        defaults.set(crashLogsEnabled, forKey: Key.crashLogsEnabled)
        defaults.set(playAudio, forKey: Key.playAudio)
        defaults.set(framePolicy.rawValue, forKey: Key.framePolicy)
        defaults.set(showPerformanceOverlay, forKey: Key.showPerformanceOverlay)
        defaults.set(warnUnsignedBackgrounds, forKey: Key.warnUnsignedBackgrounds)
    }

    /// Whether the welcome window opens at launch. Never for scripted launches (project
    /// paths, snapshots or `--quit-after` on the command line).
    public func showsWelcome(for options: LaunchOptions) -> Bool {
        guard options.paths.isEmpty, options.snapshotDir == nil, options.quitAfter == nil else { return false }
        return !onboardingCompleted || showWelcomeAtLaunch
    }

    /// Launch options starting from these preferences, then `arguments` on top.
    public func launchOptions(arguments: [String]) -> LaunchOptions {
        var base = LaunchOptions()
        base.audio = playAudio
        base.overlay = showPerformanceOverlay
        base.framePolicy = framePolicy.rawValue
        return LaunchOptions(arguments: arguments, base: base)
    }
}
