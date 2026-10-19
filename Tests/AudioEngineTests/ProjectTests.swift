import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import AudioEngine

private func open(_ url: URL) throws -> (ProjectBundle, AudioScene)? {
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.tscproj").path) else { return nil }
    let b = try ProjectBundle(url: url)
    return (b, AudioScene(project: b.project, resolve: b.resolve))
}

@Test func demoProjectMixesSeamlessly() async throws {
    guard let (bundle, scene) = try open(demoBundleURL) else { return }
    let rate = Double(bundle.project.audioSampleRate)
    let fmt = MixFormat(sampleRate: rate, channels: 2)
    // The demo has one audible clip: the .trec microphone inside a group, with DFN3 noise removal.
    #expect(scene.tracks.flatMap(\.clips).count == 1)
    let d = scene.duration
    let whole = try await AudioMixer(scene: scene, pool: MediaPool(diskCacheDirectory: nil), format: fmt).render(0 ..< d)
    #expect(whole.frameCount == Int((Double(d) / Double(tick) * rate).rounded(.up)))
    #expect(rms(whole.channels[0][0...]) > 0.005)
    // Player-sized chunks on a fresh pool: identical samples.
    let mixer = AudioMixer(scene: scene, pool: MediaPool(diskCacheDirectory: nil), format: fmt)
    let step = Int64(Double(tick) * 0.25)
    var joined: [Float] = []
    var t: Int64 = 0
    while t < d {
        let b = try await mixer.render(t ..< min(d, t + step))
        joined += b.channels[0]
        t += step
    }
    #expect(joined == whole.channels[0])
}

/// Mix speed on the user's vlog (7 min, 4 tracks, stitched and sped-up clips). Needs ≥ 20× real
/// time in release builds; debug builds only report.
@Test func vlogMixesFasterThanRealTime() async throws {
    guard let (bundle, scene) = try open(vlogBundleURL) else { return }
    guard ProcessInfo.processInfo.environment["WIZREC_PERF"] == "1" else { return }
    let rate = Double(bundle.project.audioSampleRate)
    let mixer = AudioMixer(scene: scene, pool: MediaPool(diskCacheDirectory: nil),
                           format: MixFormat(sampleRate: rate, channels: 2))
    let d = scene.duration
    let step = Int64(Double(tick) * 0.25)
    let clock = ContinuousClock()
    var peak: Float = 0
    var clippedAt: [Double] = []   // seconds of chunks holding full-scale samples
    let elapsed = try await clock.measure {
        var t: Int64 = 0
        while t < d {
            let b = try await mixer.render(t ..< min(d, t + step))
            for c in b.channels { for x in c { peak = max(peak, abs(x)) } }
            if b.channels.contains(where: { $0.contains { abs($0) >= 1 } }) { clippedAt.append(Double(t) / Double(tick)) }
            t += step
        }
    }
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let speed = Double(d) / Double(tick) / seconds
    let clipped = await mixer.clippedSamples
    print("vlog mix: \(String(format: "%.1f", Double(d) / Double(tick))) s in \(String(format: "%.2f", seconds)) s = \(String(format: "%.1f", speed))× real time, peak \(peak)")
    print("vlog clipping: \(clipped) samples over ±1 in \(clippedAt.count) chunks; first at \(clippedAt.prefix(8).map { String(format: "%.2f", $0) }) s")
    #expect(peak > 0)
    #if !DEBUG
    #expect(speed >= 20)
    #endif
}
