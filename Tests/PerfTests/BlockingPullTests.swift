import Foundation
import TestGenKit
import Testing

/// Thread-safe counter / flag for the pull thread and the test.
private final class Counter: @unchecked Sendable {
    // @unchecked: `n` is read and written under `lock`.
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// `BlockingPull` itself (always runs; bounds of a second or less), board QA11-1.
struct BlockingPullTests {
    @Test func drainsEveryItemInOrder() async throws {
        let source = Counter(), cancels = Counter()
        var seen: [Int] = []
        try await BlockingPull.drain("1…100", seconds: 60, buffer: 2,
                                     next: { let i = source.next(); return i <= 100 ? i : nil },
                                     cancel: { _ = cancels.next() }) { (i: Int) throws -> Bool in
            seen.append(i)
            return true
        }
        #expect(seen == Array(1...100))
        #expect(cancels.value == 0)
    }

    @Test func earlyStopCancels() async throws {
        let source = Counter(), cancels = Counter()
        var seen: [Int] = []
        try await BlockingPull.drain("first 3", seconds: 60, buffer: 2,
                                     next: { source.next() },
                                     cancel: { _ = cancels.next() }) { (i: Int) throws -> Bool in
            seen.append(i)
            return seen.count < 3
        }
        #expect(seen == [1, 2, 3])
        #expect(cancels.value == 1)
        // The producer has left `next` before `drain` returns (the caller may free its reader),
        // and stopped within its buffer.
        let atReturn = source.value
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.value == atReturn)
        #expect(atReturn <= 3 + 2 + 1)
    }

    @Test func bodyErrorPropagatesAndCancels() async {
        struct Boom: Error {}
        let source = Counter(), cancels = Counter()
        await #expect(throws: Boom.self) {
            try await BlockingPull.drain("boom", seconds: 60, next: { source.next() },
                                         cancel: { _ = cancels.next() }) { (i: Int) throws -> Bool in
                if i == 2 { throw Boom() }
                return true
            }
        }
        #expect(cancels.value == 1)
    }

    /// A pull that never returns (the CI `copyNextSampleBuffer` stall) fails on time; `cancel`
    /// is not called while the thread is still inside the pull (CoreMedia crashed on that).
    @Test func stalledPullTimesOutWithoutCancelling() async throws {
        let gate = DispatchSemaphore(value: 0), cancels = Counter(), source = Counter()
        var seen: [Int] = []
        let start = SuspendingClock.now
        await #expect(throws: PullStalled.self) {
            try await BlockingPull.drain("stuck reader", seconds: 0.1,
                                         next: { () -> Int? in
                                             let i = source.next()
                                             if i > 2 { gate.wait(); return nil }
                                             return i
                                         },
                                         cancel: { _ = cancels.next(); gate.signal() }) { (i: Int) throws -> Bool in
                seen.append(i)
                return true
            }
        }
        #expect(SuspendingClock.now - start < .seconds(10))
        #expect(seen == [1, 2])
        #expect(cancels.value == 0)
        gate.signal() // let the abandoned thread finish
    }

    /// An early stop while the thread is inside a slow (not stuck) pull: `cancel` runs only
    /// after the pull returned.
    @Test func cancelWaitsForTheInFlightPull() async throws {
        let inPull = Counter(), overlaps = Counter(), source = Counter()
        try await BlockingPull.drain("slow pulls", seconds: 60, buffer: 1,
                                     next: { () -> Int? in
                                         _ = inPull.next()
                                         Thread.sleep(forTimeInterval: 0.05)
                                         _ = inPull.next()
                                         return source.next()
                                     },
                                     cancel: { if inPull.value % 2 == 1 { _ = overlaps.next() } }) { (i: Int) throws -> Bool in
            i < 2
        }
        #expect(overlaps.value == 0)
    }

    /// The same stall inside a `@MainActor` test: the main thread is never blocked.
    @MainActor @Test func stallOnMainActorFails() async {
        let gate = DispatchSemaphore(value: 0)
        await #expect(throws: PullStalled.self) {
            try await BlockingPull.drain("stuck on main", seconds: 0.1,
                                         next: { () -> Int? in gate.wait(); return nil },
                                         cancel: {}) { (_: Int) throws -> Bool in true }
        }
        gate.signal()
    }

    @Test func stallMessageNamesTheLoop() {
        let e = PullStalled(what: "frames of a.mp4", seconds: 120)
        #expect(e.description.contains("frames of a.mp4") && e.description.contains("120 s"))
    }
}
