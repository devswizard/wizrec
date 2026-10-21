import Foundation
import Metal
import MetalKit
import PlayerKit
import Testing
import WizRecTestSupport

/// `CanvasRenderer.renderImage` (snapshots) awaits the GPU instead of blocking the main thread (APP11-1).
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct CanvasRendererTests {
    @Test func renderImageLetsTheMainActorRunWhileTheGPUWorks() async throws {
        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, fps: 30)
        defer { doc.discardUntitled() }
        let engine = doc.makeEngine(audio: false)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), device: MTLCreateSystemDefaultDevice())
        let renderer = try #require(CanvasRenderer(view: view))
        renderer.engine = engine

        // A main-actor heartbeat: it can only advance while the main actor is free. A renderer that
        // waited for the GPU synchronously would leave `ticks` unchanged across the call.
        let ticks = Heartbeat()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks.count += 1
                await Task.yield()
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()

        let render = Task { @MainActor () -> (CGImage?, Int) in
            let before = ticks.count
            let image = await renderer.renderImage(size: CGSize(width: 64, height: 36))
            return (image, ticks.count - before)
        }
        let (image, ticksDuringRender) = try await Deadline.value(of: render, "offscreen canvas render",
                                                                  seconds: GPUWait.defaultSeconds)
        let cg = try #require(image)
        #expect(cg.width == 64 && cg.height == 36)
        #expect(ticksDuringRender > 0, "the main actor ran no other work while the GPU rendered")
    }

    @Test func renderImageWithoutAnEngineOrSizeIsNil() async throws {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let renderer = try #require(CanvasRenderer(view: view))
        #expect(await renderer.renderImage(size: CGSize(width: 10, height: 10)) == nil)
        let doc = try EditorDocumentModel.untitled(width: 320, height: 180, fps: 30)
        defer { doc.discardUntitled() }
        let engine = doc.makeEngine(audio: false)
        renderer.engine = engine
        #expect(await renderer.renderImage(size: .zero) == nil)
    }
}

/// Main-actor counter shared by the heartbeat task and the render task.
@MainActor private final class Heartbeat {
    var count = 0
}
