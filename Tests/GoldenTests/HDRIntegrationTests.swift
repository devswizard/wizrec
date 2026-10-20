import AudioEngine
import CoreGraphics
import Exporter
import Foundation
import Metal
import MediaEngine
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit
import WizRecTestSupport

// Session 4 (S4-MED-1, HDR10/HLG → SDR tone mapping) end to end: an HDR clip on the timeline
// goes through evaluate → decode → composite → export. Synthetic media only (ffmpeg testsrc2).

private let W = 640, H = 360
private let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

/// Transfer tags the synthesised 10-bit HEVC clip carries. All but `sdr709` use BT.2020
/// primaries and matrix, so PQ/HLG differ from `sdr2020` only in the transfer function.
enum HDRTransfer: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case pq = "smpte2084", hlg = "arib-std-b67", sdr2020 = "bt2020-10", sdr709 = "bt709"
    var testDescription: String { rawValue }
}

/// Writes 30 frames of 10-bit HEVC testsrc2 tagged with `transfer`. The pixel data is the same
/// for every transfer.
private func writeClip(_ transfer: HDRTransfer, to url: URL) throws {
    let ffmpeg = try #require(ffmpeg)
    // Tags via setparams: this ffmpeg drops the -colorspace/-color_trc output flags.
    let colour = transfer == .sdr709
        ? ["-vf", "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709"]
        : ["-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=\(transfer.rawValue)"]
    let args: [String] = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                          "-f", "lavfi", "-i", "testsrc2=size=\(W)x\(H):rate=30", "-frames:v", "30",
                          "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1",
                          "-pix_fmt", "yuv420p10le"] + colour + [url.path]
    let r = try TestProcess.run(ffmpeg, args, stdout: .discard)
    #expect(r.status == 0, "ffmpeg failed for \(transfer): \(r.stderrText)")
}

/// A project with the clip on track 0 for its full 30 frames.
@MainActor
private func project(_ transfer: HDRTransfer, in dir: URL) throws -> ProjectBundle {
    let movie = dir.appendingPathComponent("clip-\(transfer).mp4")
    try writeClip(transfer, to: movie)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("hdr-\(transfer).cmproj"), width: W, height: H)
    let chain = EditChain(bundle.project)
    let v = AddSource(SourceDescriptor(src: try bundle.importFile(movie), lastModified: Date(timeIntervalSince1970: 1_792_000_000), tracks: [
        .init(type: 0, editRate: 30, rangeEnd: 30, width: W, height: H, sampleRate: Rational(30), bitDepth: 30, channelCount: 0),
    ]))
    try chain.run(v)
    try chain.run(InsertClip(sourceID: try #require(v.sourceID), track: 0, start: 0))
    return bundle
}

@MainActor
private func preview(_ bundle: ProjectBundle, frame n: Int, toneMapping: HDRToneMapping = .cpu,
                     pool: MediaPool? = nil) async throws -> RGBAImage {
    let r = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve),
                            pool: pool ?? MediaPool(diskCacheDirectory: nil, hdrToneMapping: toneMapping))
    return RGBAImage(try await r.image(at: Int64(n) * frameTicks, size: CGSize(width: W, height: H)))
}

/// Mean absolute difference over R, G, B, 0…255.
private func meanAbsDiff(_ a: RGBAImage, _ b: RGBAImage) -> Double {
    var sum = 0, n = 0
    for i in stride(from: 0, to: a.pixels.count, by: 4) {
        for c in 0..<3 { sum += abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c])); n += 1 }
    }
    return Double(sum) / Double(max(n, 1))
}

@Suite(.serialized, .timeLimit(.minutes(6)),
       .enabled(if: ffmpeg != nil && MTLCreateSystemDefaultDevice() != nil, "needs ffmpeg and a Metal device"))
@MainActor struct HDRIntegrationTests {
    /// A clip of each transfer renders the same twice (fresh pools) and its ProRes 4444 export
    /// decodes to what the preview draws (PSNR ≥ 45 dB) at the first, middle and last frame.
    /// 4444, not 422: tone-mapped testsrc2 has saturated colour edges that 4:2:2 chroma
    /// subsampling alone pulls down to ~32 dB (SDR ~48 dB). That is expected codec loss, not a
    /// tone-mapping bug: with 4444 all transfers reach ~55 dB.
    @Test(arguments: HDRTransfer.allCases)
    func exportMatchesPreview(_ transfer: HDRTransfer) async throws {
        let dir = try scratchDir("s4-hdr-export")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try project(transfer, in: dir)
        let out = dir.appendingPathComponent("out.mov")
        var settings = ExportSettings(format: .mov(profile: "4444"))
        settings.includeAudio = false
        try await ExportSession(scene: SceneModel(project: bundle.project, resolve: bundle.resolve),
                                audio: AudioScene(project: bundle.project, resolve: bundle.resolve),
                                pool: MediaPool(diskCacheDirectory: nil), settings: settings, output: out).run()
        let probes = [0, 15, 29]
        let exported = try await MovieFrameReader.frames(out, indices: probes)
        for n in probes {
            let p = try await preview(bundle, frame: n)
            #expect(p == (try await preview(bundle, frame: n)), "\(transfer) frame \(n): preview not deterministic")
            let e = try #require(exported[n], "frame \(n) missing")
            let psnr = Metrics.psnr(p, e)
            #expect(psnr >= 45, "\(transfer) frame \(n): export vs preview PSNR \(psnr) dB")
        }
    }

    /// S5 (media6/render6): the playback pool's Metal tone map (`HDRToneMapping.gpu`) composites
    /// to the CPU reference through the whole render path: ≤ 1 code per channel and ≥ 99.9 %
    /// exact (DECISIONS 2026-10-20) at the first, middle and last frame, for every transfer
    /// (SDR clips take the plain path either way).
    @Test(arguments: HDRTransfer.allCases)
    func gpuToneMapMatchesCPUReference(_ transfer: HDRTransfer) async throws {
        let dir = try scratchDir("s5-hdr-gpu")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try project(transfer, in: dir)
        let cpuPool = MediaPool(diskCacheDirectory: nil, hdrToneMapping: .cpu)
        let gpuPool = MediaPool(diskCacheDirectory: nil, hdrToneMapping: .gpu)
        defer {
            // media7: prove which path ran. HDR transfers tone-map on the GPU with no fallback;
            // SDR transfers never tone-map.
            let g = gpuPool.toneMapStats, c = cpuPool.toneMapStats
            print("HDR toneMapStats \(transfer.rawValue): gpu pool \(g), cpu pool \(c)")
            if transfer == .pq || transfer == .hlg {
                #expect(g.gpuFrames > 0 && g.cpuFallbackFrames == 0 && g.cpuFrames == 0, "\(transfer): gpu pool \(g)")
                #expect(c.cpuFrames > 0 && c.gpuFrames == 0, "\(transfer): cpu pool \(c)")
            } else {
                #expect(g == ToneMapStats() && c == ToneMapStats(), "\(transfer): SDR tone-mapped (\(g), \(c))")
            }
        }
        for n in [0, 15, 29] {
            let cpu = try await preview(bundle, frame: n, pool: cpuPool)
            let gpu = try await preview(bundle, frame: n, pool: gpuPool)
            var maxDiff = 0, exact = 0, total = 0
            for i in stride(from: 0, to: cpu.pixels.count, by: 4) {
                for c in 0..<3 {
                    let d = abs(Int(cpu.pixels[i + c]) - Int(gpu.pixels[i + c]))
                    maxDiff = max(maxDiff, d); exact += d == 0 ? 1 : 0; total += 1
                }
            }
            let fraction = Double(exact) / Double(max(total, 1))
            if n == 15 {
                print(String(format: "HDR gpu vs cpu %@: max |Δ| %d, exact %.4f %%", transfer.rawValue, maxDiff, fraction * 100))
            }
            #expect(maxDiff <= 1, "\(transfer) frame \(n): GPU differs from CPU by \(maxDiff) codes")
            #expect(fraction >= 0.999, "\(transfer) frame \(n): only \(fraction * 100) % exact")
        }
    }

    /// The transfer tag reaches the compositor: the same 10-bit BT.2020 pixels tagged PQ or HLG
    /// render differently from the SDR-transfer clip (tone mapping applied), and PQ differs from
    /// HLG. The BT.709-tagged clip is printed for reference only.
    @Test func transferTagChangesTheRender() async throws {
        let dir = try scratchDir("s4-hdr-tags")
        defer { try? FileManager.default.removeItem(at: dir) }
        var images: [HDRTransfer: RGBAImage] = [:]
        for t in HDRTransfer.allCases { images[t] = try await preview(try project(t, in: dir), frame: 15) }
        let sdr = try #require(images[.sdr2020]), pq = try #require(images[.pq]), hlg = try #require(images[.hlg])
        let dPQ = meanAbsDiff(pq, sdr), dHLG = meanAbsDiff(hlg, sdr), dPH = meanAbsDiff(pq, hlg)
        let d709 = meanAbsDiff(sdr, try #require(images[.sdr709]))
        print(String(format: "HDR integration: mean |Δ| PQ–SDR %.2f, HLG–SDR %.2f, PQ–HLG %.2f, SDR2020–SDR709 %.2f",
                     dPQ, dHLG, dPH, d709))
        #expect(dPQ > 2, "PQ renders like SDR (mean |Δ| \(dPQ))")
        #expect(dHLG > 2, "HLG renders like SDR (mean |Δ| \(dHLG))")
        #expect(dPH > 1, "PQ and HLG render alike (mean |Δ| \(dPH))")
    }
}
