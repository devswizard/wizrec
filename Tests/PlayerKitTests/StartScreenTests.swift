import Foundation
import Testing
import TestGenKit
import TSCProjKit
@testable import PlayerKit

/// Start screen model (APP13-1): recent rows, thumbnails, launch and close policies.
@Suite struct StartScreenTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A new empty `.cmproj` in `dir`, optionally carrying a ProjectThumbnail written through
    /// TSCProjKit (our own generated PNG; no Camtasia render is ever vendored).
    private func makeProject(_ name: String, in dir: URL, thumbnail: Data? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let bundle = try ProjectBundle.create(at: url, width: 320, height: 180, fps: 30)
        if let thumbnail {
            let metadata = bundle.project.root["metadata"]?.object ?? JSONObject()
            metadata["ProjectThumbnail"] = .string(thumbnail.base64EncodedString())
            bundle.project.root["metadata"] = .object(metadata)
            try bundle.save()
        }
        return url
    }

    private func png(in dir: URL) throws -> Data {
        let file = dir.appendingPathComponent("thumb.png")
        try MediaWriter.writePNG(to: file, width: 64, height: 36) { ctx in
            ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        return try Data(contentsOf: file)
    }

    @Test func rowsKeepRecencyOrderDropDuplicatesHiddenAndNonProjects() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeProject("Alpha.cmproj", in: dir)
        let b = try makeProject("Beta.cmproj", in: dir)
        let gone = dir.appendingPathComponent("Gone.cmproj")
        let bare = dir.appendingPathComponent("Loose.tscproj")
        try Data("{}".utf8).write(to: bare)
        let movie = dir.appendingPathComponent("clip.mp4")
        let urls = [b, gone, a, URL(fileURLWithPath: b.path + "/"), movie, bare,
                    dir.appendingPathComponent("./Alpha.cmproj")]
        let rows = RecentProjects.list(urls)
        #expect(rows.map(\.name) == ["Beta", "Gone", "Alpha", "Loose"])
        #expect(rows.map(\.exists) == [true, false, true, true])
        #expect(rows[1].modified == nil)
        #expect(rows[0].folder == RecentProjects.abbreviate(dir.path))

        let hidden: Set<String> = [gone.standardizedFileURL.path]
        #expect(RecentProjects.list(urls, hidden: hidden).map(\.name) == ["Beta", "Alpha", "Loose"])
        #expect(RecentProjects.list([]).isEmpty)
    }

    @Test func hiddenEntriesArePrunedWhenNoLongerRecent() {
        let a = URL(fileURLWithPath: "/x/a.cmproj"), b = URL(fileURLWithPath: "/x/b.cmproj")
        #expect(RecentProjects.pruned(hidden: [a.path, b.path, "/x/c.cmproj"], recents: [b]) == [b.path])
    }

    @Test func folderAbbreviatesHome() {
        #expect(RecentProjects.abbreviate("/Users/me/Documents", home: "/Users/me") == "~/Documents")
        #expect(RecentProjects.abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(RecentProjects.abbreviate("/Users/meX/Documents", home: "/Users/me") == "/Users/meX/Documents")
        #expect(RecentProjects.abbreviate("/tmp/a", home: "") == "/tmp/a")
    }

    /// A package's date is its project file's: rewriting `project.tscproj` does not touch the
    /// package folder's own date.
    @Test func packageDateIsTheProjectFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try makeProject("Dated.cmproj", in: dir)
        let fm = FileManager.default
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_750_000_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: p.path)
        try fm.setAttributes([.modificationDate: new], ofItemAtPath: p.appendingPathComponent("project.tscproj").path)
        #expect(RecentProjects.modificationDate(of: p) == new)
        #expect(RecentProjects.list([p]).first?.modified == new)
    }

    @Test func thumbnailComesFromTheProjectWhenPresent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try png(in: dir)
        let with = try makeProject("With.cmproj", in: dir, thumbnail: image)
        let without = try makeProject("Without.cmproj", in: dir)
        let before = try Data(contentsOf: with.appendingPathComponent("project.tscproj"))

        #expect(RecentProjects.thumbnailData(projectAt: with) == image)
        #expect(RecentProjects.thumbnailData(projectAt: without) == nil)
        #expect(RecentProjects.thumbnailData(projectAt: with.appendingPathComponent("project.tscproj")) == image)
        #expect(RecentProjects.thumbnailData(projectAt: dir.appendingPathComponent("Missing.cmproj")) == nil)
        // Reading writes nothing.
        #expect(try Data(contentsOf: with.appendingPathComponent("project.tscproj")) == before)

        // Not an image: no thumbnail (the placeholder shows).
        let junk = try makeProject("Junk.cmproj", in: dir, thumbnail: Data("not a png".utf8))
        #expect(RecentProjects.thumbnailData(projectAt: junk) == nil)
    }

    /// The demo fixture (a user-owned project with its ProjectThumbnail stripped) has none.
    @Test func strippedFixtureHasNoThumbnail() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TSCProjKitTests/Fixtures/demo.tscproj")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("demo.tscproj")
        try FileManager.default.copyItem(at: fixture, to: copy)
        #expect(RecentProjects.thumbnailData(projectAt: copy) == nil)
        #expect(RecentProjects.list([copy]).first?.name == "demo")
    }

    @Test func placeholderHueIsStable() {
        let h = RecentProjects.placeholderHue(for: "demo project")
        #expect(h >= 0 && h < 1)
        #expect(h == RecentProjects.placeholderHue(for: "demo project"))
        #expect(h != RecentProjects.placeholderHue(for: "vlog"))
    }

    @Test func startScreenPreferenceDefaultsOn() {
        let name = "WizRecTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        defer { d.removePersistentDomain(forName: name) }
        #expect(AppPreferences().showStartScreenAtLaunch)
        #expect(AppPreferences.load(from: d).showStartScreenAtLaunch)
        d.set(false, forKey: AppPreferences.Key.showStartScreenAtLaunch)
        #expect(!AppPreferences.load(from: d).showStartScreenAtLaunch)
        var p = AppPreferences()
        p.showStartScreenAtLaunch = false
        p.save(to: d)
        #expect(AppPreferences.load(from: d) == p)
    }

    @Test func launchWindowPolicy() {
        var p = AppPreferences()
        #expect(p.launchWindow(for: LaunchOptions()) == .onboarding)
        p.onboardingCompleted = true
        #expect(p.launchWindow(for: LaunchOptions()) == .startScreen)
        #expect(p.launchWindow(for: LaunchOptions(arguments: ["a.cmproj"])) == .none)
        #expect(p.launchWindow(for: LaunchOptions(arguments: ["--quit-after", "5"])) == .none)
        #expect(p.launchWindow(for: LaunchOptions(arguments: ["--snapshot-dir", "/tmp/s"])) == .none)
        #expect(p.launchWindow(for: LaunchOptions(arguments: ["--quit-after", "5", "--start-screen"])) == .startScreen)
        #expect(p.launchWindow(for: LaunchOptions(arguments: ["a.cmproj", "--start-screen"])) == .none)
        p.showStartScreenAtLaunch = false
        #expect(p.launchWindow(for: LaunchOptions()) == .openPanel)
        p.showWelcomeAtLaunch = true
        #expect(p.launchWindow(for: LaunchOptions()) == .onboarding)
        // The first-run onboarding is skipped when a check asks for the start screen.
        #expect(AppPreferences().launchWindow(for: LaunchOptions(arguments: ["--start-screen"])) == .startScreen)
    }

    @Test func lastWindowClosedBringsTheStartScreenBack() {
        let interactive = LaunchOptions()
        let timed = LaunchOptions(arguments: ["--quit-after", "9"])
        let check = LaunchOptions(arguments: ["--quit-after", "9", "--start-screen"])
        func shows(_ n: Int, _ o: LaunchOptions, terminating: Bool = false, modal: Bool = false) -> Bool {
            StartScreenPolicy.showsAfterDocumentClosed(openDocuments: n, terminating: terminating, modalShown: modal, options: o)
        }
        #expect(shows(0, interactive))
        #expect(!shows(1, interactive))
        #expect(!shows(0, interactive, terminating: true))
        #expect(!shows(0, interactive, modal: true))
        #expect(!shows(0, timed))
        #expect(shows(0, check))
        #expect(!shows(0, LaunchOptions(arguments: ["a.cmproj", "--snapshot-dir", "/tmp/s"])))
        // Opened from the command line, interactive: closing it still shows the start screen.
        #expect(shows(0, LaunchOptions(arguments: ["a.cmproj"])))
    }

    @Test func scriptedRunsLeaveRecentDocumentsAlone() {
        #expect(StartScreenPolicy.notesRecentDocuments(options: LaunchOptions()))
        #expect(StartScreenPolicy.notesRecentDocuments(options: LaunchOptions(arguments: ["a.cmproj"])))
        #expect(!StartScreenPolicy.notesRecentDocuments(options: LaunchOptions(arguments: ["a.cmproj", "--quit-after", "3"])))
        #expect(!StartScreenPolicy.notesRecentDocuments(options: LaunchOptions(arguments: ["--start-screen"])))
    }

    @Test func startScreenOptionParses() {
        #expect(LaunchOptions(arguments: ["--start-screen"]).startScreen)
        #expect(!LaunchOptions(arguments: []).startScreen)
        #expect(LaunchOptions(arguments: ["--start-screen"]) != LaunchOptions(arguments: []))
    }
}
