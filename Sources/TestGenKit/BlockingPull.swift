import AVFoundation
import Foundation

/// Hands a non-`Sendable` value to the private pull thread of `BlockingPull.drain`.
///
/// Wrap only values that are never used by two threads at once: `drain` runs `next` on its
/// thread and `cancel` on the caller only after that thread has returned.
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
/// `Deadline`) of the previous one, it abandons the thread and throws `PullStalled`.
/// Lives in TestGenKit (no Testing import) so `MovieFrameReader` can use it.
///
/// `cancel` (`reader.cancelReading()`) never runs while the thread is inside `next`: calling
/// `cancelReading` during a `copyNextSampleBuffer` on another thread crashed CoreMedia
/// (SIGSEGV, measured). An abandoned thread keeps its captures (reader, output) alive, so
/// nothing is freed under a pull that never returns.
public enum BlockingPull {
    /// Default stall bound, seconds (before `scale`).
    public static let defaultSeconds = 120.0

    /// Sleeps `seconds` on the suspending clock (stands still while the Mac sleeps, like the
    /// `systemUptime` the stall check reads).
    static func timerSleep(_ seconds: Double) async {
        let d = Duration.nanoseconds(Int64(max(seconds, 0) * 1e9))
        try? await Task.sleep(until: SuspendingClock.now + d, clock: SuspendingClock())
    }

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
    ///   - cancel: releases the source (`reader.cancelReading()`) when `body` stops early or
    ///     throws; runs on the caller once the thread has left `next` for good. Never called after
    ///     a normal end or on a stall.
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
        /// Stops the producer and waits (bounded) until it has left its in-flight pull and
        /// returned; then `cancel` runs here. Returns false if the thread is still inside `next`
        /// after the bound (then `cancel` is skipped and the thread abandoned).
        func shutDown() async -> Bool {
            channel.stop()
            guard await channel.waitForExit(seconds: bound) else { return false }
            cancel()
            return true
        }
        var last = ProcessInfo.processInfo.systemUptime
        while true {
            switch channel.take() {
            case .item(let item):
                last = ProcessInfo.processInfo.systemUptime
                let keepGoing: Bool
                do { keepGoing = try body(item) } catch {
                    _ = await shutDown()
                    throw error
                }
                if !keepGoing {
                    if await shutDown() { return }
                    throw PullStalled(what: "\(what) (stopping)", seconds: bound)
                }
            case .end:
                return
            case .empty:
                let remaining = bound - (ProcessInfo.processInfo.systemUptime - last)
                if remaining <= 0 {
                    channel.stop()
                    throw PullStalled(what: what, seconds: bound)
                }
                let timer = Task {
                    await BlockingPull.timerSleep(remaining)
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
    private var exited = false
    private var exitWoken = false
    private var exitWaiter: CheckedContinuation<Void, Never>?
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
        defer {
            lock.lock()
            exited = true
            let w = exitWaiter
            exitWaiter = nil
            lock.unlock()
            w?.resume()
        }
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

    /// Suspends until the producer loop has returned, at most `seconds`; returns whether it did.
    func waitForExit(seconds: Double) async -> Bool {
        let timer = Task { [weak self] in
            await BlockingPull.timerSleep(seconds)
            self?.wakeExit()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited || exitWoken {
                lock.unlock()
                c.resume()
                return
            }
            exitWaiter = c
            lock.unlock()
        }
        timer.cancel()
        return hasExited
    }

    private var hasExited: Bool { lock.withLock { exited } }

    private func wakeExit() {
        lock.lock()
        let w = exitWaiter
        exitWaiter = nil
        exitWoken = true
        lock.unlock()
        w?.resume()
    }
}

extension BlockingPull {
    /// `drain` for the usual `AVAssetReader` loop: pulls `output.copyNextSampleBuffer()` on the
    /// private thread and calls `body` with each sample until it returns false (then the reader
    /// is cancelled once the thread is out of its pull). A stall throws `PullStalled` and leaves
    /// the reader to the abandoned thread: do not cancel it afterwards. Call after
    /// `reader.startReading()`; check `reader.status` afterwards as before.
    public static func samples(_ what: String, reader: AVAssetReader, output: AVAssetReaderOutput,
                               seconds: Double = defaultSeconds,
                               isolation: isolated (any Actor)? = #isolation,
                               _ body: (CMSampleBuffer) throws -> Bool) async throws {
        // The output is used only by the pull thread from here on, `cancelReading` only after that
        // thread returned; each sample is handed to the consumer and not touched by the thread
        // again. `next` captures the reader too: the output must not outlive it while a pull runs.
        let pair = PullHandle((reader, output))
        try await drain(what, seconds: seconds,
                        next: { () -> PullHandle<CMSampleBuffer>? in
                            pair.value.1.copyNextSampleBuffer().map(PullHandle.init)
                        },
                        cancel: { pair.value.0.cancelReading() }) { (s: PullHandle<CMSampleBuffer>) throws -> Bool in
            try body(s.value)
        }
    }
}
