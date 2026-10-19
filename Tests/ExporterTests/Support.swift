import Accelerate
import AudioEngine
import CoreGraphics
import Foundation
import Metal
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit
@testable import Exporter

let hasGPU = MTLCreateSystemDefaultDevice() != nil

/// Ticks per frame at 30 fps.
let tpf: Int64 = 23_520_000

/// A fresh temp directory per call (removed by the caller via `defer`).
func tempDir(_ tag: String = #function) throws -> URL {
    let safe = tag.filter { $0.isLetter || $0.isNumber }
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("WizRecExportTests-\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Synthetic test media shared by all tests (written once per process into a temp dir).
enum SharedMedia {
    /// Test card A (≈ 480×270, 30 fps, 300 frames), B (≈ 320×180), card + marker PNGs.
    static let set: TestGen.MediaSet? = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WizRecExportTests-media-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        return try? TestGen.makeMedia(in: dir, scale: 0.25)
    }()
}

/// A generated project and its render/audio scenes (built on the main actor).
struct TestProject: Sendable {
    let scene: SceneModel
    let audio: AudioScene
    /// Canvas size, px.
    let width: Int, height: Int
    /// Test card A, for barcode checks.
    let cardA: TestCard
}

/// Builds a project on a `width`×`height` canvas (30 fps) from the shared media.
/// `build` gets the builder and the sources for clip A, clip B, the card PNG and the marker PNG.
@MainActor
func makeProject(width: Int = 480, height: Int = 270, background: [Int64] = [0, 0, 0, 255],
                 _ build: (ProjectBuilder, [MediaID: ProjectBuilder.Source]) -> Void) throws -> TestProject {
    guard let media = SharedMedia.set else { throw ExportError.failed("test media not generated") }
    let b = ProjectBuilder(title: "export-test", width: width, height: height, fps: 30)
    b.background = background
    var sources: [MediaID: ProjectBuilder.Source] = [:]
    for id in MediaID.allCases {
        let src = "./media/\(id.rawValue)"
        if let m = media.movies[id] { sources[id] = b.addVideoSource(src: src, movie: m) }
        if let s = media.images[id] { sources[id] = b.addImageSource(src: src, width: s.width, height: s.height) }
    }
    build(b, sources)
    let project = b.build()
    let resolve: (SourceMedia) -> URL = { s in
        media.directory.appendingPathComponent((s.src as NSString).lastPathComponent)
    }
    let a = media.movies[.clipA]
    return TestProject(scene: SceneModel(project: project, resolve: resolve),
                       audio: AudioScene(project: project, resolve: resolve),
                       width: width, height: height,
                       cardA: TestCard(width: a?.width ?? width, height: a?.height ?? height, label: "A"))
}

/// Clip A full canvas for `frames` frames, plus clip B (scaled, moving right) on top.
@MainActor
func movingProject(frames: Int64 = 60, background: [Int64] = [0, 0, 0, 255]) throws -> TestProject {
    try makeProject(background: background) { b, m in
        guard let a = m[.clipA], let bb = m[.clipB] else { return }
        b.tracks = [
            [b.video(a, start: 0, duration: frames * tpf)],
            [b.video(bb, start: 0, duration: frames * tpf, mediaStart: 30 * tpf, params: [
                "scale0": .constant(0.4), "scale1": .constant(0.4),
                "translation0": .animated(initial: -150, [
                    KeyframeSpec(time: 30 * tpf, endTime: (30 + frames) * tpf, value: 150, interp: "linr"),
                ]),
                "rotation2": .constant(0.2),
            ])],
        ]
    }
}

/// Mean SSIM (luma BT.709, 11×11 Gaussian σ 1.5, valid region) of two equal-size images.
func ssim(_ a: RGBAImage, _ b: RGBAImage) -> Double {
    precondition(a.width == b.width && a.height == b.height)
    let w = a.width, h = a.height
    func luma(_ img: RGBAImage) -> [Float] {
        let n = w * h
        var r = [Float](repeating: 0, count: n), g = r, b = r
        img.pixels.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            vDSP_vfltu8(base, 4, &r, 1, vDSP_Length(n))
            vDSP_vfltu8(base + 1, 4, &g, 1, vDSP_Length(n))
            vDSP_vfltu8(base + 2, 4, &b, 1, vDSP_Length(n))
        }
        var y = vDSP.multiply(0.2126, r)
        y = vDSP.add(multiplication: (g, 0.7152), y)
        return vDSP.add(multiplication: (b, 0.0722), y)
    }
    let x = luma(a), y = luma(b)
    let r = 5
    let taps: [Float] = {
        let t = (-r...r).map { i in exp(-Float(i * i) / (2 * 1.5 * 1.5)) }
        let s = t.reduce(0, +)
        return t.map { $0 / s }
    }()
    func blur(_ p: [Float]) -> [Float] {
        var src = p, out = [Float](repeating: 0, count: p.count)
        src.withUnsafeMutableBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { dp in
                var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                      rowBytes: w * 4)
                var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                      rowBytes: w * 4)
                _ = vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, taps, UInt32(taps.count), taps, UInt32(taps.count),
                                              0, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }
    let mx = blur(x), my = blur(y)
    let xx = blur(vDSP.multiply(x, x)), yy = blur(vDSP.multiply(y, y)), xy = blur(vDSP.multiply(x, y))
    let c1: Float = (0.01 * 255) * (0.01 * 255), c2: Float = (0.03 * 255) * (0.03 * 255)
    var sum: Double = 0, n = 0
    for j in r..<(h - r) { for i in r..<(w - r) {
        let k = j * w + i
        let sx = xx[k] - mx[k] * mx[k], sy = yy[k] - my[k] * my[k], sxy = xy[k] - mx[k] * my[k]
        let v = ((2 * mx[k] * my[k] + c1) * (2 * sxy + c2)) / ((mx[k] * mx[k] + my[k] * my[k] + c1) * (sx + sy + c2))
        sum += Double(v); n += 1
    } }
    return n > 0 ? sum / Double(n) : 1
}

/// Runs an export of `project` and returns the output URL.
func export(_ project: TestProject, _ settings: ExportSettings, to url: URL, pool: MediaPool = MediaPool()) async throws {
    let session = ExportSession(scene: project.scene, audio: project.audio, pool: pool, settings: settings, output: url)
    try await session.run()
}

