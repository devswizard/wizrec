import Foundation

/// A bounded wait in a test ran out of time. `what` names the wait, `seconds` the bound.
public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let what: String
    public let seconds: Double
    public init(what: String, seconds: Double) {
        self.what = what
        self.seconds = seconds
    }
    public var description: String {
        "timed out after \(String(format: "%.0f", seconds)) s waiting for \(what)"
            + " [load average \(String(format: "%.1f", LoadGate.loadAverage))]"
    }
}

/// Bounded replacements for the blocking waits tests used to make (board QA10-1).
///
/// A small CI VM (3 cores) can stall a wait forever: an `AVAssetWriter.finishWriting` callback
/// that never comes, a progress value that never moves because the job failed, a subprocess that
/// never exits. A blocked main thread then stalls every `@MainActor` test. Every wait here throws
/// `DeadlineExceeded` after its bound, so the test fails with a message instead of hanging the
/// run. Bounds are seconds of wall time, scaled by `WIZREC_WAIT_SCALE` (default 1).
public enum Deadline {
    /// Default bound for one wait, in seconds (before `scale`).
    public static let defaultSeconds = 120.0

    /// Multiplier for every bound, from `WIZREC_WAIT_SCALE` (e.g. 3 on a very slow machine).
    public static var scale: Double {
        ProcessInfo.processInfo.environment["WIZREC_WAIT_SCALE"].flatMap(Double.init).map { max($0, 0.01) } ?? 1
    }

    static func nanoseconds(_ seconds: Double) -> UInt64 { UInt64(max(seconds, 0) * 1e9) }

    /// Polls `condition` every `interval` seconds until it returns true. Throws `DeadlineExceeded`
    /// after `seconds` (scaled). `interval` 0 yields instead of sleeping.
    public static func poll(_ what: String, seconds: Double = defaultSeconds, interval: Double = 0.002,
                            isolation: isolated (any Actor)? = #isolation,
                            until condition: () async throws -> Bool) async throws {
        let bound = seconds * scale
        let start = Date()
        while try await !condition() {
            if Date().timeIntervalSince(start) > bound { throw DeadlineExceeded(what: what, seconds: bound) }
            if interval > 0 { try await Task.sleep(nanoseconds: nanoseconds(interval)) } else { await Task.yield() }
        }
    }

    /// The value of `task`. After `seconds` (scaled) cancels the task and throws `DeadlineExceeded`
    /// without waiting for it any longer.
    public static func value<T: Sendable>(of task: Task<T, any Error>, _ what: String,
                                          seconds: Double = defaultSeconds) async throws -> T {
        let bound = seconds * scale
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
                once.arm(c)
                Task { once.resume(await task.result) }
                once.setTimer(Task {
                    try? await Task.sleep(nanoseconds: Deadline.nanoseconds(bound))
                    if once.resume(.failure(DeadlineExceeded(what: what, seconds: bound))) { task.cancel() }
                })
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The value of a non-throwing `task`; see `value(of:_:seconds:)`.
    public static func value<T: Sendable>(of task: Task<T, Never>, _ what: String,
                                          seconds: Double = defaultSeconds) async throws -> T {
        let wrapped = Task<T, any Error> { await task.value }
        return try await value(of: wrapped, what, seconds: seconds)
    }

    /// Bridges a completion-handler API: `start` receives a `done` callback to call once.
    /// Throws `DeadlineExceeded` if `done` is not called within `seconds` (scaled).
    public static func callback(_ what: String, seconds: Double = defaultSeconds,
                                isolation: isolated (any Actor)? = #isolation,
                                _ start: (@escaping @Sendable () -> Void) -> Void) async throws {
        let bound = seconds * scale
        let once = Once<Void>()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            once.arm(c)
            once.setTimer(Task {
                try? await Task.sleep(nanoseconds: Deadline.nanoseconds(bound))
                once.resume(.failure(DeadlineExceeded(what: what, seconds: bound)))
            })
            start { once.resume(.success(())) }
        }
    }

    /// Synchronous variant of `callback` for non-async tests: waits at most `seconds` (scaled).
    /// On the main thread the run loop keeps turning while it waits (see `wait(_:seconds:)`).
    public static func blocking(_ what: String, seconds: Double = defaultSeconds,
                                _ start: (@escaping @Sendable () -> Void) -> Void) throws {
        let bound = seconds * scale
        let done = DispatchSemaphore(value: 0)
        start { done.signal() }
        if !wait(done, seconds: bound) { throw DeadlineExceeded(what: what, seconds: bound) }
    }

    /// Waits for `semaphore` at most `seconds` (not scaled); returns false on timeout.
    ///
    /// Off the main thread this is a plain timed wait. On the main thread it polls the semaphore
    /// every millisecond and runs the main run loop in between, so run-loop sources, perform
    /// blocks and `performSelector(onMainThread:)` still fire. It cannot run `DispatchQueue.main`
    /// blocks: inside a `@MainActor` test the main queue is busy with the test itself (measured,
    /// QA10). Work that completes on the main queue (on the CI VM `AVAssetWriter.finishWriting`)
    /// therefore times out here; a `@MainActor` test must `await` such work instead.
    public static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        guard Thread.isMainThread else { return semaphore.wait(timeout: .now() + seconds) == .success }
        let end = Date().addingTimeInterval(seconds)
        while semaphore.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
            if Date() >= end { return false }
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.002, true)
        }
        return true
    }
}

/// Resumes a continuation exactly once, from whichever side (work or timer) gets there first.
final class Once<T: Sendable>: @unchecked Sendable {
    // @unchecked: every stored property is read and written under `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var timer: Task<Void, Never>?
    private var resumed = false

    func arm(_ c: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let pending { lock.unlock(); c.resume(with: pending); return }
        continuation = c
        lock.unlock()
    }

    func setTimer(_ t: Task<Void, Never>) {
        lock.lock()
        let already = resumed
        if !already { timer = t }
        lock.unlock()
        if already { t.cancel() }
    }

    /// Resumes with `result` if nothing resumed yet; returns whether this call did.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        lock.lock()
        guard !resumed else { lock.unlock(); return false }
        resumed = true
        let c = continuation, t = timer
        continuation = nil; timer = nil
        if c == nil { pending = result }
        lock.unlock()
        t?.cancel()
        c?.resume(with: result)
        return true
    }
}
