import AVFoundation
import Foundation
import Testing
@testable import Exporter

/// Compressed sample data of every track of `mediaType` in `url`, concatenated in decode order
/// (passthrough: no decode), with each sample's presentation time.
func trackBytes(_ url: URL, _ mediaType: AVMediaType) async throws -> (data: Data, times: [CMTime]) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    out.alwaysCopiesSampleData = false
    reader.add(out)
    #expect(reader.startReading())
    var data = Data(), times: [CMTime] = []
    while let sb = out.copyNextSampleBuffer() {
        times.append(CMSampleBufferGetPresentationTimeStamp(sb))
        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
        let len = CMBlockBufferGetDataLength(block)
        var chunk = Data(count: len)
        let status = chunk.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
        }
        #expect(status == noErr)
        data.append(chunk)
    }
    #expect(reader.status == .completed)
    return (data, times)
}

@Suite(.enabled(if: hasGPU), .serialized) struct AudioPrefetchTests {
    /// Audio mixed on the prefetch task is byte-identical to the inline (serial) mix, and the
    /// video is untouched by it (ProRes: VideoToolbox H.264 is not bit-reproducible).
    @Test(arguments: ["48000", "44100"])
    func prefetchedAudioEqualsSerialAudio(_ rate: String) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject(sampleRate: rate)
        var s = ExportSettings(format: .mov(profile: "422"))
        s.range = (tpf * 3 + 777)..<(tpf * 88)  // off-grid start, several 0.5 s chunks
        let serial = dir.appendingPathComponent("serial.mov")
        let parallel = dir.appendingPathComponent("parallel.mov")
        try await ExportSession.$serialAudio.withValue(true) { try await export(p, s, to: serial) }
        try await export(p, s, to: parallel)

        let a = try await trackBytes(serial, .audio), b = try await trackBytes(parallel, .audio)
        #expect(!a.data.isEmpty)
        #expect(a.data == b.data, "audio bytes differ")
        #expect(a.times == b.times)
        let va = try await trackBytes(serial, .video), vb = try await trackBytes(parallel, .video)
        #expect(va.data == vb.data, "video bytes differ")
        #expect(va.times == vb.times)
    }

    /// A long range with a shallow queue: the producer blocks on a full queue and resumes in order.
    @Test func queueKeepsOrderAndPropagatesErrors() async throws {
        let q = ChunkQueue<Int>(capacity: 2)
        let producer = Task {
            for i in 0..<100 { guard await q.put(i) else { return } }
            await q.finish(ExportError.failed("boom"))
        }
        var got: [Int] = []
        do {
            while let x = try await q.take() { got.append(x) }
            Issue.record("expected the producer's error")
        } catch let e as ExportError {
            #expect(e == .failed("boom"))
        }
        await producer.value
        #expect(got == Array(0..<100))
    }

    @Test func closeReleasesABlockedProducer() async throws {
        let q = ChunkQueue<Int>(capacity: 1)
        let producer = Task { () -> Int in
            var n = 0
            while await q.put(n) { n += 1 }
            return n
        }
        _ = try await q.take()
        await q.close()
        let puts = await producer.value
        #expect(puts <= 3)
    }
}
