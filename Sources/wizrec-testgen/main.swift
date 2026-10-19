// wizrec-testgen: builds the effect-free golden test projects (and their
// original synthetic media) that the user opens in Camtasia and exports as
// reference renders. See docs/testing/reference-exports.md.

import Foundation
import TestGenKit

let usage = """
    usage:
      wizrec-testgen [--out DIR] [--case NAME]... [--force]
          Write each case to DIR/<case>/ (default: \(TestGen.defaultOutputDirectory.path)).
          Existing cases are skipped unless --force; reference.mp4 is never touched.
      wizrec-testgen --list
          List the cases.
      wizrec-testgen track-marker MOVIE [--canvas WxH]
          Print CSV of the magenta marker's centroid per frame of MOVIE (e.g. a
          keyframes-* reference.mp4): frame, pixel x/y (top-left origin), and
          canvas x/y (px from centre, +y up). Used to fit the eioe curve.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("wizrec-testgen: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())

if args.first == "track-marker" {
    args.removeFirst()
    guard let path = args.first else { fail("track-marker needs a movie path\n\(usage)") }
    var canvas = (w: 1920.0, h: 1080.0)
    if let i = args.firstIndex(of: "--canvas"), i + 1 < args.count {
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { fail("bad --canvas \(args[i + 1])") }
        canvas = (parts[0], parts[1])
    }
    print("frame,pixels,x_px,y_px,x_canvas,y_canvas")
    do {
        try await MovieFrameReader.forEachFrame(URL(fileURLWithPath: path)) { n, _, pb in
            guard let img = RGBAImage(pixelBuffer: pb) else { return true }
            var sx = 0.0, sy = 0.0, count = 0.0
            for y in 0..<img.height {
                for x in 0..<img.width {
                    let p = img.pixel(x, y)
                    // Marker fill: magenta (242, 26, 217); its white cross is ignored. The
                    // test cards' 75 % magenta bar (191, 0, 191) stays below the red cut.
                    if p.r > 215, p.g < 90, p.b > 180 { sx += Double(x); sy += Double(y); count += 1 }
                }
            }
            if count == 0 {
                print("\(n),0,,,,")
            } else {
                let cx = sx / count + 0.5, cy = sy / count + 0.5
                let kx = canvas.w / Double(img.width), ky = canvas.h / Double(img.height)
                print(String(format: "%d,%.0f,%.3f,%.3f,%.3f,%.3f", n, count, cx, cy,
                             cx * kx - canvas.w / 2, canvas.h / 2 - cy * ky))
            }
            return true
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}

if args.contains("--list") {
    for c in TestGen.cases { print("\(c.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(c.summary)") }
    exit(0)
}

var out = TestGen.defaultOutputDirectory
var only: [String] = []
var force = false
var i = 0
while i < args.count {
    switch args[i] {
    case "--out":
        guard i + 1 < args.count else { fail("--out needs a directory") }
        out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        i += 1
    case "--case":
        guard i + 1 < args.count else { fail("--case needs a name") }
        only.append(args[i + 1])
        i += 1
    case "--force":
        force = true
    default:
        fail("unknown argument \(args[i])\n\(usage)")
    }
    i += 1
}

let known = Set(TestGen.cases.map(\.name))
for name in only where !known.contains(name) { fail("unknown case \(name); try --list") }
let selected = TestGen.cases.filter { only.isEmpty || only.contains($0.name) }
let fm = FileManager.default

do {
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let todo = selected.filter { c in
        let bundle = out.appendingPathComponent("\(c.name)/\(c.name).cmproj")
        if fm.fileExists(atPath: bundle.path) && !force {
            print("skip   \(c.name) (exists; --force to rebuild)")
            return false
        }
        return true
    }
    if todo.isEmpty { exit(0) }
    let mediaDir = out.appendingPathComponent("_media", isDirectory: true)
    print("Synthesising media in \(mediaDir.path) …")
    let media = try TestGen.makeMedia(in: mediaDir)
    for c in todo {
        let caseDir = out.appendingPathComponent(c.name, isDirectory: true)
        let bundle = caseDir.appendingPathComponent("\(c.name).cmproj")
        try TestGen.write(c, media: media, to: out)
        let ref = caseDir.appendingPathComponent("reference.mp4")
        let note = fm.fileExists(atPath: ref.path) ? "  [reference.mp4 exists: re-export it if the case changed]" : ""
        print("wrote  \(bundle.path)\(note)")
    }
} catch {
    fail("\(error)")
}
