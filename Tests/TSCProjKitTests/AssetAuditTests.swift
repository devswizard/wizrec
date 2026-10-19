import Foundation
import Testing
@testable import TSCProjKit

/// Repository asset audit (CLAUDE.md hard rule 3): no TechSmith content is vendored.
///
/// Fails on Camtasia-only file types (shader videos, recordings, project bundles,
/// libraries) anywhere in the repo, and on any `.tscproj` that still carries
/// `metadata.ProjectThumbnail` (a Camtasia render of the canvas). Strip one with
/// `swift run tscproj strip-thumbnail <file>`.
enum AssetAudit {
    /// Extensions of Camtasia/TechSmith file types that must never be committed.
    static let forbiddenExtensions: Set<String> = [
        "tscshadervid", "trec", "cmproj", "camproj", "camrec", "libzip", "tscvideo", "tsclib",
    ]

    /// Directories skipped: build products and VCS/tooling state, never committed.
    static let skippedDirectories: Set<String> = [".build", ".git", ".swiftpm", ".claude", "DerivedData"]

    /// Human-readable violations under `root` (paths relative to it); empty when clean.
    static func violations(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ["cannot enumerate \(root.path)"]
        }
        var found: [String] = []
        let base = root.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let full = url.resolvingSymlinksInPath().path
            let rel = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, skippedDirectories.contains(name) {
                walker.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if forbiddenExtensions.contains(ext) {
                found.append("\(rel): forbidden file type .\(ext)")
                if isDir { walker.skipDescendants() }
                continue
            }
            if !isDir, ext == "tscproj" {
                do {
                    let project = try Project(contentsOf: url)
                    if project.root["metadata"]?.object?["ProjectThumbnail"] != nil {
                        found.append("\(rel): vendored metadata.ProjectThumbnail (run `tscproj strip-thumbnail`)")
                    }
                } catch {
                    found.append("\(rel): unreadable project (\(error))")
                }
            }
        }
        return found.sorted()
    }
}

/// The package root: this file is `<root>/Tests/TSCProjKitTests/AssetAuditTests.swift`.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct AssetAuditTests {
    @Test func repositoryHasNoTechSmithAssets() {
        let violations = AssetAudit.violations(in: repoRoot)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    /// The audit itself: a vendored thumbnail and a forbidden file type both fail; a clean
    /// project passes.
    @Test func auditCatchesThumbnailsAndForbiddenFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(#"{"metadata":{"title":""},"x":1.50}"#.utf8).write(to: dir.appendingPathComponent("clean.tscproj"))
        #expect(AssetAudit.violations(in: dir).isEmpty)

        try Data(#"{"metadata":{"ProjectThumbnail":"iVBORw0KGgo="}}"#.utf8)
            .write(to: dir.appendingPathComponent("thumb.tscproj"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("skip/.build"),
                                                withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("skip/.build/ignored.trec"))
        try Data().write(to: dir.appendingPathComponent("bg.tscshadervid"))

        let v = AssetAudit.violations(in: dir)
        #expect(v.count == 2)
        #expect(v.contains { $0.hasPrefix("thumb.tscproj: vendored metadata.ProjectThumbnail") })
        #expect(v.contains { $0.hasPrefix("bg.tscshadervid: forbidden") })
    }
}
