import AVFoundation
import Foundation

/// Hands a non-`Sendable` value to the private pull thread of `BlockingPull.drain`.
///
/// Wrap only values that, after the hand-off, the pull thread alone touches (an
/// `AVAssetReaderTrackOutput`), or whose methods are safe from any thread
/// (`AVAssetReader.cancelReading`).
public struct PullHandle<Value>: @unchecked Sendable {
    // @unchecked: the caller promises the single-owner / thread-safe use described above.
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// A blocking pull loop got no item within its stall bound. `what` names the loop, `seconds` the bound.
public struct PullStalled: Error, CustomStringConvertible {
    public let what: String
    public let seconds: Double
    public init(what: String, seconds: Double) {
        self.what = what
        self.seconds = seconds
    }
    public var description: String {
        "timed out after \(String(format: "%.0f", seconds)) s waiting for the next item of \(what)"
    }
}

/// Bounded replacement for a test's `while let s = output.copyNextSampleBuffer() { … }` loop
/// (board QA11-1).
///
/// `copyNextSampleBuffer` blocks its thread until the next sample is decoded. On a stalled
/// CoreMedia (seen on GitHub's 3-core VMs) it never returns: inline in a test it blocks a
/// cooperative thread, or the main thread inside a `@MainActor` test, and hangs the run.
/// `drain` calls `next` on a private thread and feeds the items to `body` on the caller.
/// If no item arrives within `seconds` (scaled by `WIZREC_WAIT_SCALE`, like the tests'
/// `Deadline`) of the previous one, it calls `cancel`, abandons the thread and throws
/// `PullStalled`. Lives in TestGenKit (no Testing import) so `MovieFrameReader` can use it.
public enum BlockingPull {
    /// Default stall bound, seconds (before `scale`).
    public static let defaultSeconds = 120.0

    /// Multiplier for every bound, from `WIZREC_WAIT_SCALE` (default 1).
    public static var scale: Double {
        ProcessInfo.processInfo.environment["WIZREC_WAIT_SCALE"].flatMap(Double.init).map { max($0, 0.01) } ?? 1
    }

    /// Calls `next` on a private thread until it returns nil and `body` with each item, in order,
    /// on the caller, until `body` returns false.
    ///
    /// - Parameters:
    ///   - seconds: stall bound, seconds of wall time between two items (not for the whole loop).
    ///   - buffer: items decoded ahead of `body` (decoders own a small pool of buffers: keep it small).
    ///   - next: the blocking pull; nil ends the stream. Runs on the private thread only.
    ///   - cancel: unblocks `next` (`reader.cancelReading()`); called when the wait times out,
    ///     `body` throws or `body` stops early, never after a normal end.
    public static func drain<T: Sendable>(_ what: String, seconds: Double = defaultSeconds,
                                          buffer: Int = 4,
                                          next: @escaping @Sendable () -> T?,
                                          cancel: @escaping @Sendable () -> Void,
                                          isolation: isolated (any Actor)? = #isolation,
                                          _ body: (T) throws -> Bool) async throws {
        let bound = seconds * scale
        let channel = PullChannel<T>(capacity: max(buffer, 1))
        let thread = Thread { channel.produce(next) }
        thread.name = "wizrec-test-pull: \(what)"
        thread.stackSize = 4 << 20
        thread.start()
        var last = Date()
        while true {
            switch channel.take() {
            case .item(let item):
                last = Date()
                let keepGoing: Bool
                do { keepGoing = try body(item) } catch {
                    channel.stop(); cancel()
                    throw error
                }
                if !keepGoing { channel.stop(); cancel(); return }
            case .end:
                return
            case .empty:
                let remaining = bound - Date().timeIntervalSince(last)
                if remaining <= 0 {
                    channel.stop(); cancel()
                    throw PullStalled(what: what, seconds: bound)
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1e9))
                    channel.wake()
                }
                await channel.waitForData()
                timer.cancel()
            }
        }
    }
}

/// Single-producer, single-consumer queue between the pull thread and `drain`.
final class PullChannel<T: Sendable>: @unchecked Sendable {
    // @unchecked: every stored var is read and written under `lock`; `space` is thread-safe.
    enum Taken { case item(T), end, empty }

    private let lock = NSLock()
    private var items: [T] = []
    private var ended = false
    private var stopped = false
    private var woken = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// Free slots; the producer takes one before each pull.
    private let space: DispatchSemaphore

    init(capacity: Int) {
        // Start at 0 and signal: libdispatch traps when a semaphore is freed below its initial
        // value, which happens whenever the consumer stops with slots in use.
        space = DispatchSemaphore(value: 0)
        for _ in 0..<capacity { space.signal() }
    }

    /// Producer loop (pull thread): pulls until `next` returns nil or the consumer stops.
    func produce(_ next: () -> T?) {
        while true {
            space.wait()
            lock.lock()
            let quit = stopped
            lock.unlock()
            if quit { return }
            let item = next()
            lock.lock()
            if let item { items.append(item) } else { ended = true }
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume()
            if item == nil { return }
        }
    }

    /// Consumer gives up: the producer exits at its next free slot (or stays blocked in `next`
    /// until `cancel` unblocks it).
    func stop() {
        lock.lock()
        stopped = true
        items.removeAll()
        lock.unlock()
        space.signal()
    }

    func take() -> Taken {
        lock.lock()
        if !items.isEmpty {
            let item = items.removeFirst()
            lock.unlock()
            space.signal()
            return .item(item)
        }
        let result: Taken = ended ? .end : .empty
        lock.unlock()
        return result
    }

    /// Suspends until an item or the end arrives, or `wake` is called (spurious returns are fine:
    /// the consumer checks again).
    func waitForData() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !items.isEmpty || ended || woken {
                woken = false
                lock.unlock()
                c.resume()
                return
            }
            waiter = c
            lock.unlock()
        }
    }

    /// Timer side: resumes the waiting consumer, or makes its next `waitForData` return at once.
    func wake() {
        lock.lock()
        let w = waiter
        waiter = nil
        if w == nil { woken = true }
        lock.unlock()
        w?.resume()
    }
}

extension BlockingPull {
    /// `drain` for the usual `AVAssetReader` loop: pulls `output.copyNextSampleBuffer()` on the
    /// private thread and calls `body` with each sample until it returns false. A stall cancels
    /// the reader and throws `PullStalled`. Call after `reader.startReading()`; check
    /// `reader.status` afterwards as before.
    public static func samples(_ what: String, reader: AVAssetReader, output: AVAssetReaderOutput,
                               seconds: Double = defaultSeconds,
                               isolation: isolated (any Actor)? = #isolation,
                               _ body: (CMSampleBuffer) throws -> Bool) async throws {
        // The output is used only by the pull thread from here on; `cancelReading` is safe from
        // any thread; each sample is handed to the consumer and not touched by the thread again.
        let out = PullHandle(output), rd = PullHandle(reader)
        try await drain(what, seconds: seconds,
                        next: { () -> PullHandle<CMSampleBuffer>? in out.value.copyNextSampleBuffer().map(PullHandle.init) },
                        cancel: { rd.value.cancelReading() }) { (s: PullHandle<CMSampleBuffer>) throws -> Bool in
            try body(s.value)
        }
    }
}
