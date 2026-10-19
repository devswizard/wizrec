import Foundation
import Testing
@testable import TSCProjKit

/// A fresh temp folder per test; every write in these tests goes there.
private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("wizrec-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func fixtureURL() throws -> URL {
    try #require(Bundle.module.url(forResource: "demo.tscproj", withExtension: nil, subdirectory: "Fixtures"))
}

/// A `.cmproj` copy of the demo fixture in a temp folder, with a dummy media file.
private func demoBundleCopy() throws -> URL {
    let dir = try tempDir().appendingPathComponent("demo.cmproj")
    let fm = FileManager.default
    try fm.createDirectory(at: dir.appendingPathComponent("media/1792376869.292854"), withIntermediateDirectories: true)
    try fm.copyItem(at: fixtureURL(), to: dir.appendingPathComponent("project.tscproj"))
    try Data("x".utf8).write(to: dir.appendingPathComponent("media/1792376869.292854/a.mp4"))
    try Data().write(to: dir.appendingPathComponent("~project.tscproj"))
    try Data("prefs".utf8).write(to: dir.appendingPathComponent("docPrefs"))
    return dir
}

// MARK: - create

@Test func createWritesAnEmptyFormat10Project() throws {
    let url = try tempDir().appendingPathComponent("New.cmproj")
    let made = try ProjectBundle.create(at: url, width: 1280, height: 720, fps: 60)
    #expect(made.isPackage)
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("media").path))

    let b = try ProjectBundle(url: url)
    let p = b.project
    #expect(p.formatVersion == "10.0")
    #expect(p.timebase.editRate == 705_600_000)
    #expect(p.width == 1280 && p.height == 720)
    #expect(p.frameRate == Rational(60))
    #expect(p.authoringClient.name == "WizRec")
    #expect(p.authoringClient.platform == "Mac")
    #expect(p.authoringClient.version == ProjectBundle.authoringVersion)
    #expect(p.sourceBin.isEmpty)
    #expect(p.tracks.count == 1)
    #expect(p.tracks[0].clips.isEmpty)
    #expect(p.timeline?.trackAttributes.count == 1)
    #expect(p.timeline?.backgroundColor == [0, 0, 0, 255])
    // Same top-level and timeline key sets/order as a Camtasia 2026 project.
    let demo = try Project(contentsOf: fixtureURL())
    #expect(p.root.keys == demo.root.keys)
    #expect(p.timeline?.object.keys == demo.timeline?.object.keys)
    #expect(p.timeline?.trackAttributes[0].keys == demo.timeline?.trackAttributes[0].keys)
    #expect(p.root["width"]?.number?.lexeme == "1280.0")
    #expect(p.root["targetLoudness"]?.number?.lexeme == "-18.0")
    // Serialisation is stable.
    #expect(try Project(data: p.serialized()).serialized() == p.serialized())
}

@Test func createRefusesExistingURL() throws {
    let url = try tempDir()
    #expect(throws: BundleWriteError.exists(url)) { try ProjectBundle.create(at: url) }
}

// MARK: - importFile

@Test func importCopiesIntoTimestampedMediaFolders() throws {
    let tmp = try tempDir()
    let b = try ProjectBundle.create(at: tmp.appendingPathComponent("P.cmproj"))
    let file = tmp.appendingPathComponent("clip.mp4")
    try Data("movie".utf8).write(to: file)

    let a = try b.importFile(file)
    let c = try b.importFile(file)
    #expect(a != c, "two imports of the same name must not clash")
    for src in [a, c] {
        let parts = src.split(separator: "/")
        #expect(parts.count == 4 && parts[0] == "." && parts[1] == "media" && parts[3] == "clip.mp4")
        let stamp = String(parts[2])
        #expect(stamp.wholeMatch(of: /\d{10}\.\d{6}/) != nil, "\(stamp)")
        #expect(try Data(contentsOf: b.directory.appendingPathComponent(src)) == Data("movie".utf8))
    }
    // A file already inside the bundle is referenced, not copied again.
    let inside = b.directory.appendingPathComponent(String(a.dropFirst(2)))
    #expect(try b.importFile(inside) == a)
    #expect(throws: BundleWriteError.self) { try b.importFile(tmp.appendingPathComponent("nope.mp4")) }
}

@Test func importIntoBareProjectReturnsRelativePath() throws {
    let tmp = try tempDir()
    let projDir = tmp.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: projDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixtureURL(), to: projDir.appendingPathComponent("x.tscproj"))
    let b = try ProjectBundle(url: projDir.appendingPathComponent("x.tscproj"))
    #expect(!b.isPackage)

    let under = projDir.appendingPathComponent("sub/a.png")
    let outside = tmp.appendingPathComponent("b.png")
    try Data().write(to: under); try Data().write(to: outside)
    #expect(try b.importFile(under) == "./sub/a.png")
    #expect(try b.importFile(outside) == "../b.png")
    #expect(!FileManager.default.fileExists(atPath: projDir.appendingPathComponent("media").path))
}

@Test func stampFormatsMicroseconds() {
    #expect(ProjectBundle.stamp(1_792_376_869_292_854) == "1792376869.292854")
    #expect(ProjectBundle.stamp(1_792_376_869_000_054) == "1792376869.000054")
}

// MARK: - saveWithBackup

@Test func saveKeepsUntouchedContentAndWritesBackup() throws {
    let dir = try demoBundleCopy()
    let file = dir.appendingPathComponent("project.tscproj")
    let original = try Data(contentsOf: file)
    let b = try ProjectBundle(url: dir)

    b.project.root["title"] = .string("Edited")
    try b.saveWithBackup()

    let backup = dir.appendingPathComponent("project.tscproj.wizrec-backup")
    #expect(try Data(contentsOf: backup) == original, "backup is the previous file byte for byte")
    let saved = try JSON.parse(Data(contentsOf: file))
    let want = try JSON.parse(original)
    want.object?["title"] = .string("Edited")
    #expect(saved == want, "only the edited key changed (keys, order, number lexemes)")

    // A second save replaces the backup with the first save's bytes.
    let first = try Data(contentsOf: file)
    b.project.root["title"] = .string("Again")
    try b.saveWithBackup()
    #expect(try Data(contentsOf: backup) == first)
    // Save of an unchanged project is byte-stable.
    let again = try Data(contentsOf: file)
    try b.saveWithBackup()
    #expect(try Data(contentsOf: file) == again)
}

// MARK: - saveAs

@Test func saveAsCopiesPackageAndSharesProject() throws {
    let dir = try demoBundleCopy()
    let b = try ProjectBundle(url: dir)
    try b.saveWithBackup()  // leaves a backup that must not be copied
    b.project.root["title"] = .string("Copy")

    let dest = dir.deletingLastPathComponent().appendingPathComponent("copy.cmproj")
    let c = try b.saveAs(to: dest)
    #expect(c.project === b.project)
    #expect(c.directory == dest && c.isPackage)
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: dest.appendingPathComponent("media/1792376869.292854/a.mp4").path))
    #expect(fm.fileExists(atPath: dest.appendingPathComponent("docPrefs").path))
    #expect(!fm.fileExists(atPath: dest.appendingPathComponent("~project.tscproj").path))
    #expect(!fm.fileExists(atPath: dest.appendingPathComponent("project.tscproj.wizrec-backup").path))
    #expect(try ProjectBundle(url: dest).project.title == "Copy")
    // The original bundle on disk is unchanged by Save As.
    #expect(try ProjectBundle(url: dir).project.title == "")
    #expect(throws: BundleWriteError.exists(dest)) { try b.saveAs(to: dest) }
}

@Test func saveAsBareProjectKeepsSrcUntouched() throws {
    let tmp = try tempDir()
    let src = tmp.appendingPathComponent("a/x.tscproj")
    try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tmp.appendingPathComponent("b"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixtureURL(), to: src)
    let b = try ProjectBundle(url: src)
    let dest = tmp.appendingPathComponent("b/y.tscproj")
    let c = try b.saveAs(to: dest)
    #expect(c.project === b.project && !c.isPackage)
    #expect(c.directory.standardizedFileURL == dest.deletingLastPathComponent().standardizedFileURL)
    let reopened = try ProjectBundle(url: dest)
    #expect(reopened.project.sourceBin.map(\.src) == b.project.sourceBin.map(\.src))
    // Only the .tscproj is written; relative media now resolve against b/ and are reported missing.
    #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("b").path) == ["y.tscproj"])
    #expect(reopened.missingMedia().count == reopened.project.sourceBin.filter { !$0.src.hasPrefix("/") }.count)
}
