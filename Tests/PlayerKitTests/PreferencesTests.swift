import Foundation
import Testing
@testable import PlayerKit

@Suite struct AppPreferencesTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "WizRecTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name) ?? .standard, name)
    }

    @Test func defaultsAndRoundTrip() {
        let (d, name) = defaults()
        defer { d.removePersistentDomain(forName: name) }
        let fresh = AppPreferences.load(from: d)
        #expect(fresh == AppPreferences())
        #expect(!fresh.crashLogsEnabled)          // opt-in
        #expect(fresh.playAudio && fresh.framePolicy == .nearest)
        var p = fresh
        p.crashLogsEnabled = true
        p.framePolicy = .exact
        p.playAudio = false
        p.onboardingCompleted = true
        p.save(to: d)
        #expect(AppPreferences.load(from: d) == p)
        d.set("bogus", forKey: AppPreferences.Key.framePolicy)
        #expect(AppPreferences.load(from: d).framePolicy == .nearest)
    }

    @Test func commandLineOverridesPreferences() {
        var p = AppPreferences()
        p.playAudio = false
        p.framePolicy = .thin
        p.showPerformanceOverlay = true
        let o = p.launchOptions(arguments: ["x.cmproj", "--frame-policy", "exact"])
        #expect(o.paths == ["x.cmproj"])
        #expect(!o.audio && o.overlay)
        #expect(o.framePolicy == "exact")
        #expect(AppPreferences().launchOptions(arguments: ["--no-audio"]).audio == false)
        #expect(LaunchOptions(arguments: ["a"]) == LaunchOptions(arguments: ["a"], base: LaunchOptions()))
    }

    @Test func welcomeShowsOnFirstInteractiveLaunchOnly() {
        var p = AppPreferences()
        #expect(p.showsWelcome(for: LaunchOptions()))
        #expect(!p.showsWelcome(for: LaunchOptions(arguments: ["p.cmproj"])))
        #expect(!p.showsWelcome(for: LaunchOptions(arguments: ["--quit-after", "3"])))
        p.onboardingCompleted = true
        #expect(!p.showsWelcome(for: LaunchOptions()))
        p.showWelcomeAtLaunch = true
        #expect(p.showsWelcome(for: LaunchOptions()))
    }
}

@Suite(.serialized) struct CrashLogTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func namesAndHeader() {
        let launch = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 08:53:20 UTC
        #expect(CrashLog.fileName(launch: launch, pid: 42) == "crash-20251009-085320-42.log")
        let h = CrashLog.header(appVersion: "0.1.0 (7)", osVersion: "Version 27.0", launch: launch)
        #expect(h.contains("app: 0.1.0 (7)\n") && h.contains("macOS: Version 27.0\n"))
        #expect(h.contains("never sent"))
        let r = CrashLog.exceptionReport(header: h, name: "NSRangeException", reason: nil, stack: ["0 a", "1 b"])
        #expect(r.hasSuffix("reason: -\n\nbacktrace:\n0 a\n1 b\n"))
    }

    @Test func pruneKeepsNewest() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        for i in 0..<5 { try Data().write(to: d.appendingPathComponent("crash-2026010\(i)-000000-1.log")) }
        try Data().write(to: d.appendingPathComponent("notes.txt"))
        CrashLog.prune(in: d, keep: 2)
        #expect(CrashLog.reports(in: d).map(\.lastPathComponent)
                == ["crash-20260104-000000-1.log", "crash-20260103-000000-1.log"])
        CrashLog.deleteAll(in: d)
        #expect(CrashLog.reports(in: d).isEmpty)
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("notes.txt").path))
    }

    @Test func signalReportWritesOnlyWhenEnabled() throws {
        let d = try tempDir()
        defer {
            CrashLog.setEnabled(false)
            try? FileManager.default.removeItem(at: d)
        }
        CrashLog.setEnabled(false)
        #expect(!CrashLog.writeSignalReport(SIGSEGV))
        CrashLog.setEnabled(true, directory: d, appVersion: "test", osVersion: "os")
        #expect(CrashLog.isEnabled)
        #expect(CrashLog.writeSignalReport(SIGSEGV))
        let file = try #require(CrashLog.reports(in: d).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("WizRec crash report"))
        #expect(text.contains("app: test\n"))
        #expect(text.contains("signal: \(SIGSEGV)\n\nbacktrace:\n"))
        #expect(text.split(separator: "\n").count > 8)     // symbolised frames follow
        CrashLog.setEnabled(false)
        #expect(!CrashLog.writeSignalReport(SIGSEGV))
    }
}
