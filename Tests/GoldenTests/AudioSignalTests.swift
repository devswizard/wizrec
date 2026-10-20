import Foundation
import TestGenKit
import Testing
import TSCProjKit
import WizRecTestSupport

@Suite struct AudioSignalTests {
    /// BS.1770 reference point: a 0 dBFS 997 Hz sine in one channel reads −3.01 LUFS.
    @Test func sineReference() {
        let x = (0..<(3 * 48_000)).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48_000)) }
        #expect(abs(AudioSignals.integratedLUFS(x) - -3.01) < 0.05)
        #expect(AudioSignals.integratedLUFS([Float](repeating: 0, count: 48_000)) == -.infinity)
    }

    @Test func signalsHitTheirTargets() {
        let a = AudioSignals.pinkNoise(seconds: 3, lufs: -40, peakLimit: -20)
        #expect(abs(AudioSignals.integratedLUFS(a) - -40) < 0.05 && AudioSignals.peakDBFS(a) <= -20)
        let c = AudioSignals.pinkNoise(seconds: 3, lufs: -10, peakLimit: -0.5, seed: 7)
        #expect(abs(AudioSignals.integratedLUFS(c) - -10) < 0.1 && AudioSignals.peakDBFS(c) <= -0.49)
        let b = AudioSignals.clickTrain(seconds: 3, lufs: -30, peak: -1)
        #expect(abs(AudioSignals.integratedLUFS(b) - -30) < 0.15 && abs(AudioSignals.peakDBFS(b) - -1) < 0.01)
    }

    /// Our meter agrees with FFmpeg's `ebur128` filter (when ffmpeg is installed).
    @Test func agreesWithFFmpeg() throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { return }
        let dir = try scratchDir("lufs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = AudioSignals.pinkNoise(seconds: 5, lufs: -23, seed: 42)
        let wav = dir.appendingPathComponent("p.wav")
        try AudioSignals.writeWAV(x, to: wav)
        let out = try TestProcess.run(ffmpeg, ["-nostdin", "-nostats", "-hide_banner", "-i", wav.path,
                                               "-af", "ebur128", "-f", "null", "-"], stdout: .discard).stderrText
        let line = try #require(out.split(separator: "\n").last { $0.contains(" I:") && $0.contains("LUFS") })
        let value = try #require(line.split(separator: " ").compactMap { Double($0) }.first)
        #expect(abs(value - AudioSignals.integratedLUFS(x)) < 0.1, "ffmpeg \(value)")
    }

    @Test @MainActor func au2ProjectLayout() throws {
        let dir = try scratchDir("au2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundleURL = try AudioSignals.writeAU2(to: dir)
        let bytes = try Data(contentsOf: bundleURL.appendingPathComponent("project.tscproj"))
        let project = try Project(data: bytes)
        #expect(project.serialized() == bytes)
        #expect(project.sourceBin.count == 3)
        let t0 = project.tracks[0].clips, t1 = project.tracks[1].clips
        let second: Int64 = 705_600_000
        let starts0: [Int64] = [0, 10, 20, 30, 40].map { (s: Int64) -> Int64 in s * second }
        let starts1: [Int64] = [45 * second]
        #expect(t0.map(\.start) == starts0)
        #expect(t1.map(\.start) == starts1)
        #expect(t0.allSatisfy { $0.kind == ClipKind("AMFile") && $0.duration == 10 * 705_600_000 })
        let norm = t0.map { $0.attributes?["loudnessNormalization"]?.bool }
        #expect(norm == [true, true, true, false, true])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("au2.json").path))
    }
}
