import AVFoundation
import AudioEngine
import CFFmpeg
import Foundation
import MediaEngine
import RenderEngine
import TestGenKit
import Testing
import TSCProjKit
@testable import Exporter

/// Click track: 3 s of stereo silence at 48 kHz with 2 ms full-scale bursts at 1.0 s and 2.0 s.
enum ClickTrack {
    static let rate = 48_000
    static let seconds = 3
    static let clicks = [1.0, 2.0]

    static let url: URL? = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WizRecExportTests-click-\(ProcessInfo.processInfo.processIdentifier).wav")
        let n = rate * seconds
        var x = [Float](repeating: 0, count: n)
        for c in clicks {
            let s = Int(c * Double(rate))
            for i in s..<min(s + 96, n) { x[i] = i % 2 == 0 ? 0.9 : -0.9 }
        }
        // Float32 stereo WAV (both channels equal).
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = n * 2 * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(2); u32(UInt32(rate))
        u32(UInt32(rate * 8)); u16(8); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        var inter = [Float](repeating: 0, count: 2 * n)
        for i in 0..<n { inter[2 * i] = x[i]; inter[2 * i + 1] = x[i] }
        inter.withUnsafeBytes { d.append(contentsOf: $0) }
        do { try d.write(to: url) } catch { return nil }
        return url
    }()
}

/// Clip A (video, 3 s) on track 0 and the click track as an `AMFile` on track 1.
@MainActor
func avProject() throws -> TestProject {
    guard let media = SharedMedia.set, let click = ClickTrack.url else {
        throw ExportError.failed("test media not generated")
    }
    let E: Int64 = 705_600_000
    let b = ProjectBuilder(title: "av-test", width: 480, height: 270, fps: 30)
    var sources: [MediaID: ProjectBuilder.Source] = [:]
    for id in MediaID.allCases {
        if let m = media.movies[id] { sources[id] = b.addVideoSource(src: "./media/\(id.rawValue)", movie: m) }
    }
    // An audio-only source entry (the builder has no audio helper; the mixer reads `src` + stream 0).
    let audioSrc = b.addVideoSource(src: "./media/click.wav",
                                    movie: .init(width: 0, height: 0, fps: 1, frameCount: 3, timescale: 48_000))
    guard let a = sources[.clipA] else { throw ExportError.failed("clip A missing") }
    let am = try #require(try JSON.parse("""
        {"id": 900, "_type": "AMFile", "src": \(audioSrc.id), "trackNumber": 0,
         "attributes": {"ident": "click", "gain": 1.0}, "channelNumber": "0,1",
         "parameters": {}, "effects": [], "start": 0, "duration": \(3 * E),
         "mediaStart": 0, "mediaDuration": \(3 * E), "scalar": 1, "metadata": {}, "animationTracks": {}}
        """).object)
    b.tracks = [[b.video(a, start: 0, duration: 90 * tpf)], [am]]
    let project = b.build()
    let resolve: (SourceMedia) -> URL = { s in
        let name = (s.src as NSString).lastPathComponent
        return name == "click.wav" ? click : media.directory.appendingPathComponent(name)
    }
    return TestProject(scene: SceneModel(project: project, resolve: resolve),
                       audio: AudioScene(project: project, resolve: resolve), width: 480, height: 270,
                       cardA: TestCard(width: media.movies[.clipA]?.width ?? 480,
                                       height: media.movies[.clipA]?.height ?? 270, label: "A"))
}

/// Decoded audio track: channel 0 as Float32 and the presentation time of its first sample.
func decodeAudio(_ url: URL) async throws -> (samples: [Float], rate: Double, start: Double) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(out)
    #expect(reader.startReading())
    var samples: [Float] = []
    var rate = 0.0, start: Double?
    while let sb = out.copyNextSampleBuffer() {
        if start == nil { start = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb) else { continue }
        rate = asbd.mSampleRate
        let ch = Int(asbd.mChannelsPerFrame)
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        guard let ptr else { continue }
        ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
            for i in stride(from: 0, to: len / 4, by: ch) { samples.append(f[i]) }
        }
    }
    return (samples, rate, start ?? 0)
}

/// Sample indices where |x| first exceeds 0.3 after ≥ 0.2 s of quiet.
func onsets(_ x: [Float], rate: Double) -> [Int] {
    var out: [Int] = []
    var quiet = Int(rate)
    for (i, v) in x.enumerated() {
        if abs(v) > 0.3 {
            if quiet >= Int(rate * 0.2) { out.append(i) }
            quiet = 0
        } else {
            quiet += 1
        }
    }
    return out
}

let mp3Available = avcodec_find_encoder_by_name("libmp3lame") != nil

@Suite(.serialized) struct AudioExportTests {
    @Test func wavIsSampleExact() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        let out = dir.appendingPathComponent("a.wav")
        try await export(p, ExportSettings(format: .audio(container: "wav")), to: out)
        let file = try AVAudioFile(forReading: out)
        #expect(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 2)
        #expect(file.length == 144_000)
        let a = try await decodeAudio(out)
        #expect(onsets(a.samples, rate: a.rate) == [48_000, 96_000])
    }

    @Test func m4aKeepsTimingWithinOneFrame() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        var s = ExportSettings(format: .audio(container: "m4a"))
        s.range = (tpf * 15)..<(tpf * 90)  // 0.5 s … 3 s
        let out = dir.appendingPathComponent("a.m4a")
        try await export(p, s, to: out)
        let a = try await decodeAudio(out)
        let duration = Double(a.samples.count) / a.rate
        #expect(abs(duration - 2.5) < 1.0 / 30, "duration \(duration)")
        let found = onsets(a.samples, rate: a.rate).map { a.start + Double($0) / a.rate }
        #expect(found.count == 2)
        for (f, want) in zip(found, [0.5, 1.5]) { #expect(abs(f - want) < 1.0 / 30, "click at \(f), want \(want)") }
    }

    @Test(.enabled(if: mp3Available)) func mp3KeepsTimingWithinOneFrame() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        let out = dir.appendingPathComponent("a.mp3")
        try await export(p, ExportSettings(format: .audio(container: "mp3")), to: out)
        let a = try await decodeAudio(out)
        #expect(abs(Double(a.samples.count) / a.rate - 3) < 1.0 / 30 + 0.05)
        let found = onsets(a.samples, rate: a.rate).map { a.start + Double($0) / a.rate }
        #expect(found.count == 2)
        for (f, want) in zip(found, [1.0, 2.0]) { #expect(abs(f - want) < 1.0 / 30, "click at \(f), want \(want)") }
    }

    /// Acceptance: A/V sync within 1 frame. The click at timeline 1.0 s must sound at the output
    /// time of the video frame that shows timeline frame 30 (source frame 30 of clip A).
    @Test(.enabled(if: hasGPU), arguments: [ExportFormat.mp4(codec: "h264", bitrate: nil), .mov(profile: "422")])
    func audioAndVideoStayInSync(_ format: ExportFormat) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        var s = ExportSettings(format: format)
        s.range = (tpf * 10 + 12_345)..<(tpf * 75)  // off-grid start
        let out = dir.appendingPathComponent("av.\(format.fileExtension)")
        try await export(p, s, to: out)
        var flashTime: Double?
        try await MovieFrameReader.forEachFrame(out) { _, pts, pb in
            if let img = RGBAImage(pixelBuffer: pb), p.cardA.decodeFrameNumber(img) == 30 {
                flashTime = pts.seconds
                return false
            }
            return true
        }
        let video = try #require(flashTime)
        let a = try await decodeAudio(out)
        let click = try #require(onsets(a.samples, rate: a.rate).first.map { a.start + Double($0) / a.rate })
        #expect(abs(click - video) <= 1.0 / 30, "audio \(click) s vs video \(video) s")
        let f = try await movieFacts(out)
        #expect(f.hasAudio)
    }

    @Test func includeAudioOffWritesNoAudioTrack() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        guard hasGPU else { return }
        let p = try await avProject()
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        s.range = 0..<(tpf * 3)
        let out = dir.appendingPathComponent("v.mp4")
        try await export(p, s, to: out)
        #expect(try await !movieFacts(out).hasAudio)
    }
}

