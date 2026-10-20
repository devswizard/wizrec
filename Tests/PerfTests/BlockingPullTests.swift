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
        // The producer stops within its buffer, it does not run on.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(source.value <= 3 + 2 + 1)
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

    /// A pull that never returns (the CI `copyNextSampleBuffer` stall) fails on time, and
    /// `cancel` is what unblocks it.
    @Test func stalledPullTimesOutAndCancels() async throws {
        let gate = DispatchSemaphore(value: 0), cancels = Counter(), source = Counter()
        var seen: [Int] = []
        let start = Date()
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
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(seen == [1, 2])
        #expect(cancels.value == 1)
    }

    /// The same stall inside a `@MainActor` test: the main thread is never blocked.
    @MainActor @Test func stallOnMainActorFails() async {
        let gate = DispatchSemaphore(value: 0)
        await #expect(throws: PullStalled.self) {
            try await BlockingPull.drain("stuck on main", seconds: 0.1,
                                         next: { () -> Int? in gate.wait(); return nil },
                                         cancel: { gate.signal() }) { (_: Int) throws -> Bool in true }
        }
    }

    @Test func stallMessageNamesTheLoop() {
        let e = PullStalled(what: "frames of a.mp4", seconds: 120)
        #expect(e.description.contains("frames of a.mp4") && e.description.contains("120 s"))
    }
}
