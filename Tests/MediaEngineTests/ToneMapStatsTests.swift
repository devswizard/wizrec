// `MediaPool.toneMapStats` tells whether HDR frames went through the Metal kernel or the CPU.

import CoreMedia
import Foundation
import Testing
@testable import MediaEngine

@Suite(.enabled(if: Synth.ffmpegPath != nil, "needs ffmpeg"))
struct ToneMapStatsTests {
    /// A 3-frame 128×72 HDR10 (PQ) ProRes clip, plus an SDR one.
    static func clips(_ dir: URL) throws -> (hdr: URL, sdr: URL) {
        let hdr = dir.appendingPathComponent("pq.mov"), sdr = dir.appendingPathComponent("sdr.mov")
        try Synth.ffmpeg(["-f", "lavfi", "-i", "color=c=0x949494:size=128x72:rate=30", "-frames:v", "3",
                          "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                          "-vf", "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084", hdr.path])
        try Synth.ffmpeg(["-f", "lavfi", "-i", "color=c=0x949494:size=128x72:rate=30", "-frames:v", "3",
                          "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", sdr.path])
        return (hdr, sdr)
    }

    static func decodeAll(_ pool: MediaPool, _ url: URL) async throws {
        for i in 0..<3 {
            _ = try await pool.frame(FrameRequest(url: url, stream: 0, time: CMTime(value: Int64(i), timescale: 30)))
        }
    }

    @Test func gpuPoolCountsKernelFramesOrFallbacks() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (hdr, sdr) = try Self.clips(dir)
        let pool = MediaPool(diskCacheDirectory: nil, hdrToneMapping: .gpu)
        #expect(pool.toneMapStats == ToneMapStats())
        try await Self.decodeAll(pool, sdr)
        #expect(pool.toneMapStats == ToneMapStats(), "SDR frames are not tone-mapped")
        try await Self.decodeAll(pool, hdr)
        if MetalToneMapper.shared != nil {
            #expect(pool.toneMapStats == ToneMapStats(gpuFrames: 3))
        } else {
            #expect(pool.toneMapStats == ToneMapStats(cpuFallbackFrames: 3))
        }
        // Cache hits and thumbnails do not count.
        try await Self.decodeAll(pool, hdr)
        _ = try await pool.thumbnail(url: hdr, stream: 0, at: .zero, maxPixelSize: 32)
        #expect(pool.toneMapStats.gpuFrames + pool.toneMapStats.cpuFallbackFrames == 3)
    }

    @Test func cpuPoolCountsCPUFrames() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (hdr, _) = try Self.clips(dir)
        let pool = MediaPool(diskCacheDirectory: nil)
        try await Self.decodeAll(pool, hdr)
        #expect(pool.toneMapStats == ToneMapStats(cpuFrames: 3))
    }
}
