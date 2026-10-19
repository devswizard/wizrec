import Foundation
import TSCProjKit

let usage = """
    usage: tscproj <command> <project.cmproj | project.tscproj> [options]

    commands:
      info        header, media list (flags missing files), track/clip tree
      roundtrip   parse → write → parse and verify nothing changed
                  -o <file>  also write the re-serialised project there
    """

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let url = URL(fileURLWithPath: args[1])

do {
    switch args[0] {
    case "info": try info(url)
    case "roundtrip":
        let out = args.firstIndex(of: "-o").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        try roundtrip(url, out: out.map { URL(fileURLWithPath: $0) })
    default: fail(usage)
    }
} catch {
    fail("error: \(error)")
}

func info(_ url: URL) throws {
    let bundle = try ProjectBundle(url: url)
    let p = bundle.project
    let tb = p.timebase
    let client = p.authoringClient
    print("format \(p.formatVersion)  written by \(client.name) \(client.platform) \(client.version)")
    print("canvas \(Int(p.width))x\(Int(p.height)) @ \(p.frameRate) fps  editRate \(tb.editRate)  duration \(tb.timecode(p.duration))")

    let missing = Set(bundle.missingMedia().map(\.id))
    print("\nmedia (\(p.sourceBin.count)):")
    for s in p.sourceBin {
        let streams = s.tracks.map { t in
            t.isVideo ? "video \(t.sampleRate.map { String(format: "%.3f", $0.double) } ?? "?")fps"
                : t.isAudio ? "audio \(t.sampleRate?.num ?? 0)Hz/\(t.channels)ch" : "type\(t.type)"
        }.joined(separator: ", ")
        print("  [\(s.id)] \(missing.contains(s.id) ? "MISSING " : "")\(s.src)  (\(streams))")
    }

    print("\ntimeline:")
    for track in p.tracks {
        print("  track \(track.index): \(track.clips.count) clips, \(track.transitions.count) transitions")
        for clip in track.clips {
            clip.walk { c, depth in
                let pad = String(repeating: "  ", count: depth + 2)
                var line = "\(pad)\(c.kind.typeName)#\(c.id) \(tb.timecode(c.start))–\(tb.timecode(c.end))"
                if let s = c.sourceID { line += " src=\(s)" }
                if c.scalar != Rational(1) { line += " speed=\(String(format: "%.3f", 1 / c.scalar.double))x" }
                if let n = c.name, !n.isEmpty { line += " \"\(n)\"" }
                if let d = c.callout { line += " callout=\(d.shape ?? "?")" }
                let fx = c.effects.filter { !$0.isPlaceholder }.map(\.name)
                if !fx.isEmpty { line += " fx=[\(fx.joined(separator: ","))]" }
                print(line)
            }
        }
        for t in track.transitions {
            print("    transition \(t.name) \(tb.timecode(t.duration)) left=\(t.leftMediaID.map(String.init) ?? "-") right=\(t.rightMediaID.map(String.init) ?? "-")")
        }
    }
}

func roundtrip(_ url: URL, out: URL?) throws {
    let bundle = try ProjectBundle(url: url)
    let original = try JSON.parse(Data(contentsOf: bundle.projectFile))
    let written = bundle.project.serialized()
    let reparsed = try JSON.parse(written)
    guard original == reparsed else { fail("roundtrip MISMATCH: \(bundle.projectFile.path)") }
    if let out { try written.write(to: out, options: .atomic) }
    print("roundtrip OK: \(bundle.projectFile.lastPathComponent) (\(written.count) bytes)\(out.map { " → \($0.path)" } ?? "")")
}
