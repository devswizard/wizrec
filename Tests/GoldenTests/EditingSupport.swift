import Foundation
import Testing
import TSCProjKit
import TimelineEngine

// QA-8 support: drive chains of TimelineEngine commands through an
// `UndoStack`, check structural invariants after every step, and verify that
// undo/redo walk back and forth through byte-identical serialisations.

/// One frame at 30 fps in editRate 705600000 ticks.
let frameTicks: Int64 = 705_600_000 / 30

/// `n` frames in ticks (30 fps, editRate 705600000).
func frames(_ n: Int64) -> Int64 { n * frameTicks }

/// A command chain on one project: performs commands through an `UndoStack`,
/// keeps the serialisation after every step, and checks invariants.
@MainActor
final class EditChain {
    let stack: UndoStack
    var project: Project { stack.project }
    /// `snapshots[i]` = serialisation after `i` performed commands (0 = start).
    private(set) var snapshots: [Data]
    /// Names of the performed commands, for failure messages.
    private(set) var names: [String] = []
    /// Commands that threw (rejected); each must have left the project unchanged.
    private(set) var rejected = 0

    init(_ project: Project) {
        stack = UndoStack(project: project, limit: 10_000)
        snapshots = [project.serialized()]
    }

    /// Performs `command`, expecting success, and checks invariants.
    @discardableResult
    func run<C: EditCommand>(_ command: C, sourceLocation: SourceLocation = #_sourceLocation) throws -> C {
        do {
            try stack.perform(command)
        } catch {
            Issue.record("step \(names.count + 1) \(command.name) threw \(error)", sourceLocation: sourceLocation)
            throw error
        }
        record(command.name, strict: true, sourceLocation: sourceLocation)
        return command
    }

    /// Performs `command` if it applies; a rejection must leave the project
    /// byte-identical. A successful no-op (e.g. a trim clamped to where the
    /// edge already is, a flag set to its current value) is allowed here.
    /// Returns whether it applied.
    @discardableResult
    func attempt(_ command: any EditCommand, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let before = project.serialized()
        do {
            try stack.perform(command)
        } catch {
            rejected += 1
            #expect(project.serialized() == before,
                    "rejected \(command.name) (\(error)) changed the project", sourceLocation: sourceLocation)
            return false
        }
        record(command.name, strict: false, sourceLocation: sourceLocation)
        return true
    }

    private func record(_ name: String, strict: Bool, sourceLocation: SourceLocation) {
        names.append(name)
        let data = project.serialized()
        if strict {
            #expect(data != snapshots.last, "step \(names.count) \(name) changed nothing",
                    sourceLocation: sourceLocation)
        }
        snapshots.append(data)
        let problems = ProjectInvariants.check(project)
        #expect(problems.isEmpty, "after step \(names.count) \(name): \(problems.joined(separator: "; "))",
                sourceLocation: sourceLocation)
    }

    /// Undoes every step, expecting each undo to reproduce the earlier
    /// serialisation byte for byte, then redoes every step the same way.
    /// Leaves the project at the end of the chain.
    func expectUndoRedoWalk(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let n = snapshots.count - 1
        for i in stride(from: n, to: 0, by: -1) {
            try stack.undo()
            if project.serialized() != snapshots[i - 1] {
                Issue.record("undo of step \(i) \(names[i - 1]) is not byte-identical", sourceLocation: sourceLocation)
                return
            }
        }
        #expect(!stack.canUndo, sourceLocation: sourceLocation)
        for i in 1...max(n, 1) where n > 0 {
            try stack.redo()
            if project.serialized() != snapshots[i] {
                Issue.record("redo of step \(i) \(names[i - 1]) differs from its first apply",
                             sourceLocation: sourceLocation)
                return
            }
        }
        #expect(!stack.canRedo, sourceLocation: sourceLocation)
    }

    /// Undoes everything and expects the original bytes.
    func undoAll(sourceLocation: SourceLocation = #_sourceLocation) throws {
        while stack.canUndo { try stack.undo() }
        #expect(project.serialized() == snapshots[0], "undo-all is not byte-identical", sourceLocation: sourceLocation)
    }
}

/// Structural invariants every edited project must keep.
@MainActor
enum ProjectInvariants {
    /// Human-readable problems; empty when the project is consistent.
    static func check(_ project: Project) -> [String] {
        var problems: [String] = []
        let data = project.serialized()

        // Lossless: parse → serialise reproduces the bytes.
        if let again = try? Project(data: data) {
            if again.serialized() != data { problems.append("re-parse is not byte-identical") }
        } else {
            problems.append("serialisation does not parse")
        }

        let sources = Set(project.sourceBin.map(\.id))
        var clipIDs: [Int64: Int] = [:]
        let maxID = project.maxID

        func checkTrack(_ track: Track, path: String, magnetic: Bool) {
            let clips = track.clips
            var lastEnd: Int64 = magnetic ? 0 : Int64.min
            for (i, c) in clips.enumerated() {
                if c.start < 0 { problems.append("\(path) clip \(c.id) starts at \(c.start) < 0") }
                if c.duration <= 0 { problems.append("\(path) clip \(c.id) duration \(c.duration) ≤ 0") }
                if i > 0, c.start < lastEnd {
                    problems.append("\(path) clip \(c.id) at \(c.start) overlaps previous end \(lastEnd)")
                }
                if magnetic, c.start != lastEnd {
                    problems.append("\(path) magnetic track has a gap before clip \(c.id)")
                }
                lastEnd = c.end
                visit(c, path: "\(path)/\(c.id)")
            }
            let ids = Set(clips.map(\.id))
            for t in track.transitions {
                for ref in [t.leftMediaID, t.rightMediaID].compactMap({ $0 }) where !ids.contains(ref) {
                    problems.append("\(path) transition \(t.name) references \(ref), not on the track")
                }
                if t.duration <= 0 { problems.append("\(path) transition \(t.name) duration ≤ 0") }
            }
        }

        func visit(_ c: Clip, path: String) {
            // `id` first: with -O, Swift 6.3.3 rejects `c` captured by the `||` autoclosure
            // (SendingRisksDataRace) (QA12-1).
            let id = c.id
            clipIDs[id, default: 0] += 1
            if id < 0 || id > maxID { problems.append("\(path) id \(id) outside 0…maxID \(maxID)") }
            if let s = c.sourceID, !sources.contains(s) {
                problems.append("\(path) references missing source \(s)")
            }
            if c.scalar.num <= 0 { problems.append("\(path) scalar ≤ 0") }
            switch c.kind {
            case .group:
                for (i, t) in c.tracks.enumerated() {
                    checkTrack(t, path: "\(path).t\(i)", magnetic: t.object["magnetic"]?.bool ?? false)
                }
            case .unified:
                for half in [c.video, c.audio].compactMap({ $0 }) { visit(half, path: "\(path).\(half.id)") }
            case .stitched:
                for s in c.segments { visit(s, path: "\(path).\(s.id)") }
            default: break
            }
        }

        let attrs = project.timeline?.trackAttributes ?? []
        let tracks = project.tracks
        if attrs.count != tracks.count {
            problems.append("\(tracks.count) tracks but \(attrs.count) trackAttributes")
        }
        for (i, t) in tracks.enumerated() {
            if t.index != Int64(i) { problems.append("track \(i) has trackIndex \(t.index)") }
            let magnetic = i < attrs.count ? (attrs[i]["magnetic"]?.bool ?? false) : false
            checkTrack(t, path: "track\(i)", magnetic: magnetic)
        }
        for (id, n) in clipIDs where n > 1 { problems.append("clip id \(id) used \(n) times") }
        return problems
    }
}

/// A source descriptor for a synthetic movie (`frames` at 30 fps, optional audio).
func movieDescriptor(src: String, frames n: Int64, audio: Bool, video: Bool = true) -> SourceDescriptor {
    var tracks: [SourceDescriptor.Track] = []
    if video {
        tracks.append(.init(type: 0, editRate: 30, rangeEnd: n, width: 320, height: 180,
                            sampleRate: Rational(30), bitDepth: 24, channelCount: 0))
    }
    if audio {
        tracks.append(.init(type: 2, editRate: 44100, rangeEnd: n * 44100 / 30, width: 0, height: 0,
                            sampleRate: Rational(44100), bitDepth: 16, channelCount: 2))
    }
    return SourceDescriptor(src: src, lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: tracks)
}

/// A source descriptor for a still image.
func imageDescriptor(src: String) -> SourceDescriptor {
    SourceDescriptor(src: src, lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
        .init(type: 1, editRate: 1, rangeEnd: 1, width: 320, height: 180,
              sampleRate: Rational(0), bitDepth: 32, channelCount: 0),
    ])
}

/// Deterministic SplitMix64 generator for reproducible random edit chains.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `~/Documents/demo project.cmproj` when present (read-only; tests copy it).
var userDemoBundle: URL? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/demo project.cmproj")
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("project.tscproj").path) ? url : nil
}

/// Copies only `project.tscproj` (and `docPrefs`) of `bundle` into a new
/// `.cmproj` under `dir`; user media is never copied.
func copyProjectOnly(_ bundle: URL, into dir: URL, name: String = "copy.cmproj") throws -> URL {
    let fm = FileManager.default
    let out = dir.appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    for item in ["project.tscproj", "docPrefs"] {
        let src = bundle.appendingPathComponent(item)
        if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: out.appendingPathComponent(item)) }
    }
    return out
}
