import AVFoundation
import Foundation

/// The parts of `AVAssetWriter` an export uses to watch, finish and cancel a file. Production
/// code passes the real writer; tests inject one whose `finishWriting` never calls back.
protocol FinishableWriter: AnyObject {
    var status: AVAssetWriter.Status { get }
    var error: (any Error)? { get }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void)
    func cancelWriting()
}

extension AVAssetWriter: FinishableWriter {}

/// Bounds of the waits on AVFoundation an export makes, seconds of awake time (system sleep does
/// not count: `StallWatch` reads `systemUptime`, and Dispatch timers run on the uptime clock).
struct WriterTimeouts: Sendable, Equatable {
    /// `finishWriting` must call back within this.
    var finish: TimeInterval = 60
    /// The writer must accept a sample at least this often while the export feeds it.
    var stall: TimeInterval = 30
    /// `cancelWriting` after a failure is awaited at most this long, then left running.
    var cancel: TimeInterval = 10
}

/// Test seam for the AVFoundation calls that can hang (board EXP11-1).
struct WriterHooks: Sendable {
    /// Wraps the export's writer, e.g. in one whose `finishWriting` never completes.
    var wrapWriter: (@Sendable (AVAssetWriter) -> any FinishableWriter)?
    /// Replaces `isReadyForMoreMediaData` of every writer input (false = the encoder never takes more).
    var inputReady: (@Sendable () -> Bool)?

    /// The writer the export talks to: `writer` itself unless a test wraps it.
    func writer(_ writer: AVAssetWriter) -> any FinishableWriter { wrapWriter?(writer) ?? writer }

    /// Whether `input` takes another sample now.
    func isReady(_ input: AVAssetWriterInput) -> Bool { inputReady?() ?? input.isReadyForMoreMediaData }
}

/// Waits on `AVAssetWriter` callbacks with a time bound, so a stuck encoder session ends the
/// export with `ExportError.encoderStalled` instead of hanging it. The timer runs on a Dispatch
/// queue, so it fires even when the Swift cooperative pool is starved.
enum WriterWait {
    /// Calls `finishWriting` and waits at most `timeout` seconds for its callback. Returns true
    /// when the callback came in time. After a timeout the caller should `abandon` the writer
    /// (never `cancelWriting` it synchronously: a stuck writer may block that call too).
    nonisolated(nonsending) static func finish(_ writer: any FinishableWriter, timeout: TimeInterval) async -> Bool {
        nonisolated(unsafe) let w = writer
        return await bounded(timeout) { finished in w.finishWriting { finished() } }
    }

    /// Cancels `writer` on a background queue and waits at most `timeout` seconds for it.
    /// Returns true when `cancelWriting` returned in time.
    @discardableResult
    nonisolated(nonsending) static func cancel(_ writer: any FinishableWriter, timeout: TimeInterval) async -> Bool {
        nonisolated(unsafe) let w = writer
        return await bounded(timeout) { finished in
            DispatchQueue.global(qos: .utility).async {
                w.cancelWriting()
                finished()
            }
        }
    }

    /// Cancels `writer` on a background queue without waiting.
    static func abandon(_ writer: any FinishableWriter) {
        nonisolated(unsafe) let w = writer
        DispatchQueue.global(qos: .utility).async { w.cancelWriting() }
    }

    /// Runs `start`, which must call its argument once when the work completes. Returns true
    /// when that happened within `timeout` seconds, false otherwise (late calls are ignored).
    nonisolated(nonsending) static func bounded(_ timeout: TimeInterval,
                        _ start: (@escaping @Sendable () -> Void) -> Void) async -> Bool {
        let once = OnceFlag()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.arm(c)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0)) {
                once.resume(false)
            }
            start { once.resume(true) }
        }
    }
}

/// Resumes a continuation exactly once, from the work or the timer, whichever comes first.
// @unchecked Sendable: every stored property is read and written under `lock`.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resumed = false

    func arm(_ c: CheckedContinuation<Bool, Never>) {
        lock.withLock { continuation = c }
    }

    func resume(_ value: Bool) {
        let c: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
