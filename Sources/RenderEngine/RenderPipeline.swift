import CoreVideo
import Foundation
import MediaEngine

/// One frame delivered by `RenderPipeline`, in frame order.
// @unchecked: CVPixelBuffer is not `Sendable`. The pipeline writes `pixelBuffer` only inside the
// frame's draw task and stops touching it before the frame is delivered; from then on the consumer
// owns it exclusively, so there is never concurrent access.
public struct PipelineFrame: @unchecked Sendable {
    /// Position in the pipeline's `ticks` list.
    public let index: Int
    /// Timeline time of the frame, ticks.
    public let ticks: Int64
    /// The buffer the frame was rendered into (the one `makeBuffer(index)` returned).
    public let pixelBuffer: CVPixelBuffer
}

/// Evaluated plan plus decoded source frames for one output frame.
struct PreparedFrame: Sendable {
    let plan: RenderPlan
    let frames: [FrameRequest: VideoFrame]
}

/// Caller-owned output buffer passed between pipeline stages.
// @unchecked: a buffer belongs to exactly one in-flight frame; only that frame's render task
// writes it, and it is handed to the consumer after the GPU has finished.
struct OutputBox: @unchecked Sendable { let buffer: CVPixelBuffer }

/// Renders a list of timeline times with several frames in flight, for export.
///
/// Stages per frame: evaluate → fetch source frames → GPU composite into the caller's buffer.
/// Fetches run strictly in frame order, one frame after another (so decoders only move forward
/// and never seek back), while earlier frames are still on the GPU; up to `maxInFlight` frames
/// are fetched, drawing or waiting for the consumer at once. `next()` returns frames strictly in
/// order. Pixels are identical to `OfflineRenderer.render(at:into:)` for the same time and buffer
/// (same plan, same source frames, same compositor).
///
/// Single consumer: call `next()` from one task at a time. Errors from any frame are thrown by
/// `next()` in order (frames before the failing one are still delivered) and end the pipeline.
public actor RenderPipeline {
    /// Timeline times to render, ticks, in output order.
    public nonisolated let ticks: [Int64]
    /// Most frames started but not yet returned by `next()` (fetching, drawing or done), ≥ 1.
    /// Also the most output buffers the pipeline holds at once.
    public nonisolated let maxInFlight: Int
    private let renderer: OfflineRenderer
    private let makeBuffer: @Sendable (Int) throws -> CVPixelBuffer

    private struct Slot {
        let fetch: Task<PreparedFrame, any Error>
        let draw: Task<PipelineFrame, any Error>
    }
    private var pending: [Slot] = []
    private var started = 0
    /// The fetch of the most recently started frame; the next fetch waits for it.
    private var lastFetch: Task<PreparedFrame, any Error>?
    private var finished = false

    /// `makeBuffer(i)` supplies the output buffer for frame `i` (32BGRA or 420v/420f BT.709,
    /// IOSurface-backed, Metal-compatible), called in order when the frame starts.
    public init(renderer: OfflineRenderer, ticks: [Int64], maxInFlight: Int = 4,
                makeBuffer: @escaping @Sendable (Int) throws -> CVPixelBuffer) {
        self.renderer = renderer
        self.ticks = ticks
        self.maxInFlight = max(1, maxInFlight)
        self.makeBuffer = makeBuffer
    }

    /// The next frame in order, or nil after the last one. Throws the first error of the
    /// frame being returned (or `CancellationError` if the calling task is cancelled).
    public func next() async throws -> PipelineFrame? {
        if finished { return nil }
        if Task.isCancelled { await cancel(); throw CancellationError() }
        do {
            try fill()
            guard !pending.isEmpty else { finished = true; return nil }
            let slot = pending.removeFirst()
            let frame = try await slot.draw.value
            try fill()
            return frame
        } catch {
            await cancel()
            throw error
        }
    }

    /// Stops the pipeline: frames in flight are cancelled, and `next()` returns nil from now on.
    /// Returns once every started frame has stopped (a fetch or GPU pass already running is let
    /// finish, so decoders stay consistent), after which the pipeline holds no output buffer.
    public func cancel() async {
        finished = true
        let slots = pending
        pending.removeAll()
        lastFetch = nil
        for s in slots { s.fetch.cancel(); s.draw.cancel() }
        for s in slots { _ = await s.draw.result; _ = await s.fetch.result }
    }

    /// Starts frames until `maxInFlight` are pending.
    private func fill() throws {
        while !finished, pending.count < maxInFlight, started < ticks.count {
            let i = started, t = ticks[i]
            let box = OutputBox(buffer: try makeBuffer(i))
            let previous = lastFetch
            let renderer = renderer
            let fetch = Task<PreparedFrame, any Error> {
                _ = await previous?.result   // fetch in frame order
                try Task.checkCancellation()
                return try await renderer.prepare(at: t)
            }
            let draw = Task<PipelineFrame, any Error> {
                let prepared = try await fetch.value
                try Task.checkCancellation()
                nonisolated(unsafe) let target = box.buffer
                try await renderer.draw(prepared, into: target)
                return PipelineFrame(index: i, ticks: t, pixelBuffer: box.buffer)
            }
            pending.append(Slot(fetch: fetch, draw: draw))
            lastFetch = fetch
            started += 1
        }
    }
}

extension OfflineRenderer {
    /// A pipeline rendering timeline times `ticks` (ticks) in order with up to `maxInFlight`
    /// frames in flight. See `RenderPipeline`.
    public nonisolated func pipeline(ticks: [Int64], maxInFlight: Int = 4,
                                     makeBuffer: @escaping @Sendable (Int) throws -> CVPixelBuffer)
        -> RenderPipeline {
        RenderPipeline(renderer: self, ticks: ticks, maxInFlight: maxInFlight, makeBuffer: makeBuffer)
    }

    /// Evaluates the scene at `ticks` and fetches its source frames (missing/unsupported files
    /// are left out, other decode errors thrown). Runs off the actor.
    nonisolated func prepare(at ticks: Int64) async throws -> PreparedFrame {
        let plan = scene.evaluate(at: ticks)
        return PreparedFrame(plan: plan, frames: try await OfflineGPU.fetch(plan.frameRequests, using: frames))
    }
}
