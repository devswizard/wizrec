import CoreGraphics
import Foundation
import Testing
import TestGenKit

/// Main-thread state the encode thread reports into.
private final class EncodeProbe: @unchecked Sendable {
    // @unchecked: every stored property is read and written under `lock`.
    private let lock = NSLock()
    private var _drawOnMain = false
    private var _mainQueueRan = false
    var drawOnMain: Bool { lock.withLock { _drawOnMain } }
    var mainQueueRan: Bool { lock.withLock { _mainQueueRan } }
    func sawDraw(onMain: Bool) { lock.withLock { _drawOnMain = _drawOnMain || onMain } }
    func sawMainQueue() { lock.withLock { _mainQueueRan = true } }
}

/// QA10: a `@MainActor` test writes media through the async `MediaWriter` API. The encode runs
/// on a private thread while the main actor is suspended, so the main queue stays free: on the CI
/// VM `AVAssetWriter.finishWriting` needs it, and a main thread blocked in a writer deadlocked
/// the run.
@MainActor struct MediaWriterAsyncTests {
    @Test func writeCompletesWhileMainActorIsSuspended() async throws {
        let dir = try scratchDir("writer-async")
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = EncodeProbe()
        let info = try await MediaWriter.writeH264(to: dir.appendingPathComponent("a.mp4"), width: 64, height: 32,
                                                   fps: 30, frameCount: 10) { n, ctx in
            probe.sawDraw(onMain: Thread.isMainThread)
            if n == 0 {
                // The main queue must run while the encode is in progress (bounded: 10 s).
                let ran = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { probe.sawMainQueue(); ran.signal() }
                _ = ran.wait(timeout: .now() + 10)
            }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        #expect(info.frameCount == 10)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.mp4").path))
        #expect(!probe.drawOnMain, "the encode ran on the main thread")
        #expect(probe.mainQueueRan, "the main queue was blocked during the write")
        let pro = try await MediaWriter.writeProRes(to: dir.appendingPathComponent("b.mov"), width: 64, height: 32,
                                                    fps: 30, frameCount: 3) { _, _ in }
        #expect(pro.frameCount == 3)
    }

    @Test func makeMediaRunsOffTheMainActor() async throws {
        let dir = try scratchDir("writer-async-media")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try await TestGen.makeMedia(in: dir, scale: 0.05)
        #expect(media.movies.count == 2)
    }
}
