import CoreMedia
import Foundation

/// Mixes an export's audio on its own task, chunk by chunk in order, up to `capacity` chunks
/// ahead of the consumer, so the mix runs in parallel with video rendering and encoding.
///
/// The chunks (ranges, order, samples) are exactly those of pulling `AudioFeed.nextChunk()`
/// inline, so the written audio is identical to the serial path.
final class AudioPrefetch: Sendable {
    private let queue: ChunkQueue<AudioChunk>
    private let task: Task<Void, Never>

    init(feed: AudioFeed, capacity: Int) {
        let q = ChunkQueue<AudioChunk>(capacity: capacity)
        queue = q
        // Detached: the mix must not run on (and serialise with) the export session's actor.
        task = Task.detached(priority: .userInitiated) {
            var f = feed
            do {
                while let c = try await f.nextChunk() {
                    try Task.checkCancellation()
                    let sb = try AudioFeed.sampleBuffer(planes: c.channels, start: c.start, sampleRate: f.sampleRate)
                    guard await q.put(AudioChunk(buffer: sb, samples: Int64(c.channels.first?.count ?? 0))) else {
                        return
                    }
                }
                await q.finish(nil)
            } catch {
                await q.finish(error)
            }
        }
    }

    /// The next chunk in order; nil once the feed is exhausted. Rethrows a mix failure.
    func next() async throws -> AudioChunk? { try await queue.take() }

    /// Stops the mix task and wakes it if it waits for space.
    func cancel() {
        task.cancel()
        let q = queue
        Task { await q.close() }
    }
}

/// One mixed chunk ready for the writer.
struct AudioChunk: @unchecked Sendable {
    // @unchecked: the sample buffer is created ready and never mutated after creation; it only
    // moves from the mix task to the writer loop.
    let buffer: CMSampleBuffer
    /// Sample frames in `buffer`.
    let samples: Int64
}

/// A bounded FIFO between one producer and one consumer task.
actor ChunkQueue<Element: Sendable> {
    private let capacity: Int
    private var items: [Element] = []
    private var head = 0
    private var finished = false
    private var closed = false
    private var failure: (any Error)?
    private var consumer: CheckedContinuation<Void, Never>?
    private var producer: CheckedContinuation<Void, Never>?

    init(capacity: Int) { self.capacity = max(1, capacity) }

    private var count: Int { items.count - head }

    /// Waits for space, then enqueues `x`. Returns false (dropping `x`) once the queue is closed.
    func put(_ x: Element) async -> Bool {
        while count >= capacity && !closed {
            await withCheckedContinuation { producer = $0 }
        }
        guard !closed else { return false }
        items.append(x)
        consumer?.resume(); consumer = nil
        return true
    }

    /// Marks the end of the stream (with the producer's error, if any).
    func finish(_ error: (any Error)?) {
        finished = true
        failure = error
        consumer?.resume(); consumer = nil
    }

    /// Next element in order; nil at the end; throws the producer's error after the elements before it.
    func take() async throws -> Element? {
        while count == 0 && !finished && !closed {
            await withCheckedContinuation { consumer = $0 }
        }
        if count > 0 {
            let x = items[head]
            head += 1
            if head > 64 { items.removeFirst(head); head = 0 }
            producer?.resume(); producer = nil
            return x
        }
        if let failure { throw failure }
        return nil
    }

    /// Releases a waiting producer and makes further puts fail.
    func close() {
        closed = true
        producer?.resume(); producer = nil
        consumer?.resume(); consumer = nil
    }
}
