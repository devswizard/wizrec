import CoreMedia
import Foundation
import MediaEngine
import QuartzCore
import RenderEngine
import Testing
import TSCProjKit
@testable import PlayerKit

/// The M0 fixture (a bare `.tscproj` copied from the user's demo, without its media).
private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("TSCProjKitTests/Fixtures/demo.tscproj")

private let demoBundle = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/demo project.cmproj")

private var hasDemo: Bool { FileManager.default.fileExists(atPath: demoBundle.appendingPathComponent("project.tscproj").path) }

/// Directory listing with sizes and modification dates, to prove nothing was written.
private func snapshot(_ dir: URL) -> [String: String] {
    var out: [String: String] = [:]
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys)
    while let u = e?.nextObject() as? URL {
        let v = try? u.resourceValues(forKeys: Set(keys))
        out[u.path] = "\(v?.fileSize ?? -1) \(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    return out
}

@MainActor @Suite struct DocumentTests {
    @Test func bareFixtureLoadsAndReportsMissingMedia() throws {
        let doc = try PlayerDocumentModel(url: fixture)
        #expect(doc.scene.canvasSize == CGSize(width: 1920, height: 1080))
        #expect(doc.scene.frameRate == Rational(30))
        #expect(doc.missing.count == 2)              // media/ and recordings/ are not vendored
        #expect(doc.missing.map(\.id).sorted() == [1, 2])
        #expect(doc.audioSampleRate == 44100)
    }

    @Test func engineTransportOnFixture() throws {
        let doc = try PlayerDocumentModel(url: fixture)
        let e = doc.makeEngine(audio: false)
        let g = e.grid
        #expect(g.frameCount == 770)                 // 25.667 s at 30 fps
        #expect(e.currentFrame == 0)
        e.step(by: 3)
        #expect(e.currentFrame == 3)
        #expect(e.currentTicks == 3 * 23_520_000)
        e.step(by: -10)
        #expect(e.currentFrame == 0)
        e.goToEnd()
        #expect(e.currentFrame == g.lastFrame)
        e.seek(toTicks: Timebase.camtasia.ticks(seconds: 10.01))
        #expect(e.currentFrame == 300)
        // Missing media must not crash or block: the plan still has layers.
        #expect(!e.drawState().plan.layers.isEmpty)
    }

    @Test func playsOnHostClockWithoutAudio() throws {
        let doc = try PlayerDocumentModel(url: fixture)
        let e = doc.makeEngine(audio: false)
        e.play()
        #expect(e.isPlaying)
        let t0 = CACurrentMediaTime()
        e.tick(host: t0 + 1.0)
        #expect(abs(e.currentFrame - 30) <= 1)
        e.pause()
        let f = e.currentFrame
        e.tick(host: t0 + 5)
        #expect(e.currentFrame == f)
        e.play()
        e.tick(host: CACurrentMediaTime() + 100)     // past the end: stops on the last frame
        #expect(!e.isPlaying)
        #expect(e.currentFrame == e.grid.lastFrame)
    }

    @Test(.enabled(if: hasDemo, "~/Documents/demo project.cmproj not present"))
    func demoBundleLoadsFramesWithoutWriting() async throws {
        let before = snapshot(demoBundle)
        let doc = try PlayerDocumentModel(url: demoBundle)
        #expect(doc.missing.isEmpty)
        let e = doc.makeEngine(audio: false)
        e.seek(toTicks: Timebase.camtasia.ticks(seconds: 5))
        let wanted = e.drawState().plan.frameRequests
        #expect(wanted.count >= 2)                   // screen + camera
        var state = e.drawState()
        for _ in 0..<250 where state.frames.count < wanted.count || state.stale > 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            e.tick(host: CACurrentMediaTime())
            state = e.drawState()
        }
        #expect(state.frames.count == wanted.count)
        #expect(state.stale == 0)
        for r in wanted {
            let f = try #require(state.frames[r])
            #expect(f.presentationTime <= r.time)
        }
        e.shutdown()
        #expect(snapshot(demoBundle) == before)
    }

    @Test(.enabled(if: hasDemo, "~/Documents/demo project.cmproj not present"))
    func demoAudioChunkHasSignal() async throws {
        let doc = try PlayerDocumentModel(url: demoBundle)
        guard let audio = AudioPlayback(scene: doc.scene, pool: doc.pool, sampleRate: doc.audioSampleRate) else { return }
        // 2–3 s into the demo: the screen recording's microphone track.
        let chunk = AudioChunk(originTicks: Timebase.camtasia.ticks(seconds: 2), startSample: 0, frameCount: 44100)
        let pcm = await audio.render(chunk)
        #expect(pcm.count == 2)
        #expect(pcm[0].count == 44100)
        #expect(audio.failedReads == 0)
        let peak = pcm[0].map(abs).max() ?? 0
        #expect(peak > 0.001)
    }
}
