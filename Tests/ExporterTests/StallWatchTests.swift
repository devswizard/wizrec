import Foundation
import Testing
@testable import Exporter

/// A scripted Mac clock: wall time and awake time, advanced by the test. Asleep, only wall time
/// moves (the way `Date()` and `systemUptime` behave across a system sleep).
final class ScriptedClock: @unchecked Sendable {
    // @unchecked: both counters are only touched under `lock`.
    private let lock = NSLock()
    private var wallSeconds = 0.0
    private var awakeSeconds = 0.0
    /// Time passes with the Mac awake: both clocks move.
    func run(_ s: Double) { lock.withLock { wallSeconds += s; awakeSeconds += s } }
    /// The Mac sleeps: only wall time moves.
    func sleep(_ s: Double) { lock.withLock { wallSeconds += s } }
    var wall: Double { lock.withLock { wallSeconds } }
    var awake: Double { lock.withLock { awakeSeconds } }
}

/// EXP16-1 (QA19-F1): the stall watch measures awake time, so a system sleep mid-export is not a stall.
struct StallWatchTests {
    @Test func sleepDoesNotTripTheWatch() throws {
        let clock = ScriptedClock()
        var watch = StallWatch(limit: 30, now: { clock.awake })
        clock.run(2)
        watch.progressed()
        clock.sleep(3600)          // an hour asleep, as in a Maintenance Sleep / DarkWake cycle
        clock.run(0.5)
        #expect(clock.wall - 2 > 30) // a wall-clock watch would have thrown here
        try watch.check()
        clock.run(1)
        watch.progressed()
        try watch.check()
    }

    @Test func awakeStallStillTrips() {
        let clock = ScriptedClock()
        var watch = StallWatch(limit: 30, now: { clock.awake })
        clock.run(29)
        #expect(throws: Never.self) { try watch.check() }
        clock.sleep(600)
        clock.run(2)               // 31 s awake without progress
        #expect(throws: ExportError.encoderStalled(seconds: 30)) { try watch.check() }
        watch.progressed()
        #expect(throws: Never.self) { try watch.check() }
    }

    /// Production reads `systemUptime`, the clock that stands still while the Mac sleeps.
    @Test func defaultTimeSourceIsAwakeTime() {
        let before = ProcessInfo.processInfo.systemUptime
        let read = StallWatch.awakeTime()
        let after = ProcessInfo.processInfo.systemUptime
        #expect(read >= before && read <= after)
        let watch = StallWatch(limit: 30)
        #expect(watch.last >= before && watch.last <= ProcessInfo.processInfo.systemUptime)
    }
}
