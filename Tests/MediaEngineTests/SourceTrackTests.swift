// StreamInfo's sourceTracks metadata (timescale, length, frame rate, bit depth, track type).

import AVFoundation
import CoreMedia
import Foundation
import Testing
import TSCProjKit
@testable import MediaEngine

@Suite struct SourceTrackTests {
    @Test func movieTimingAndFrameRate() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cfr.mp4")
        try await Synth.writeMovie(to: url, times: (0..<60).map { Double($0) / 30 })
        let s = try #require(try await MediaPool().probe(url).streams.first)
        #expect(s.trackType == 0)
        #expect(s.bitDepth == 0)
        #expect(s.bitsPerComponent == 8)
        #expect(s.frameRate == Rational(30))
        #expect(s.timescale > 0)
        // AVFoundation's track range: 2 s (60 frames at 30 fps).
        #expect(abs(Double(s.length) / Double(s.timescale) - 2.0) < 0.05)
    }

    @Test func wavTiming() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.wav")
        try Synth.writeWAV(to: url, seconds: 1.5, sampleRate: 44100, channels: 2)
        let s = try #require(try await MediaPool().probe(url).streams.first)
        #expect(s.trackType == 2)
        #expect(s.timescale == 44100)
        #expect(s.length == 66150)
        #expect(s.bitsPerComponent == 16)
        #expect(s.frameRate == nil)
    }

    @Test func imageIsTypeOne() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("i.png")
        try Synth.writePNG(to: url, width: 8, height: 4, rgba: (1, 2, 3, 255))
        let s = try #require(try await MediaPool().probe(url).streams.first)
        #expect(s.trackType == 1)
        #expect(s.timescale == 600)
        #expect(s.length == 1)
        #expect(s.bitDepth == 0)
    }

    @Test func shaderHasOneEndlessTrack() async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.tscshadervid")
        try Data(#"{"name":"t","width":1280,"height":720,"code":""}"#.utf8).write(to: url)
        let info = try await MediaPool().probe(url)
        #expect(info.kind == .shader)
        let s = try #require(info.streams.first)
        #expect(info.streams.count == 1)
        #expect(s.pixelSize == CGSize(width: 1280, height: 720))
        #expect(s.timescale == 30)
        #expect(s.length == Int64.max)
        #expect(s.bitDepth == 32)
        #expect(s.trackType == 0)
    }

    /// Every source of the user's projects: probe == what Camtasia wrote in `sourceTracks`.
    @Test(arguments: ["demo project", "Moheshkali Dwip Vlog"])
    func matchesCamtasiaSourceTracks(project name: String) async throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/\(name).cmproj")
        guard FileManager.default.fileExists(atPath: dir.path) else { return } // not installed: skip
        let bundle = try ProjectBundle(url: dir)
        let pool = MediaPool()
        var checked = 0
        for src in bundle.project.sourceBin {
            let url = bundle.resolve(src)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let info = try await pool.probe(url)
            let tracks = src.tracks
            #expect(info.streams.count == tracks.count, "\(url.lastPathComponent)")
            for (s, t) in zip(info.streams, tracks) {
                let label = "\(url.lastPathComponent) #\(s.index)"
                #expect(Int64(s.trackType) == t.type, "\(label) type")
                #expect(Int64(s.timescale) == t.editRate, "\(label) editRate")
                #expect(t.range.count == 2 && s.length == t.range[1], "\(label) range \(s.length) vs \(t.range)")
                #expect(Int64(s.bitDepth) == t.object["bitDepth"]?.int, "\(label) bitDepth")
                #expect(Int64(s.channelCount) == t.channels, "\(label) channels")
                checked += 1
            }
        }
        print("sourceTracks checked \(name): \(checked)")
        #expect(checked > 0)
    }
}
