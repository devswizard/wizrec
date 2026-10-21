import Foundation
import Testing
import WizRecTestSupport

/// `LoadGate` itself (always runs; no timing involved). The verdicts are checked directly, so
/// these self-tests add no known issues to the run (QA14-3): CI's "Known issues" annotation then
/// lists only real ones (timing missed under load, unrecorded audio digests).
struct LoadGateTests {
    @Test func loadAverageIsReadable() {
        let l = LoadGate.loadAverage
        #expect(l >= 0 && l.isFinite)
    }

    @Test func threshold() {
        #expect(!LoadGate.overloaded(30))
        #expect(LoadGate.overloaded(30.1))
    }

    @Test func passingBoundRecordsNothing() {
        #expect(LoadGate.verdict(true, "never shown", load: 99) == .pass)
        #expect(LoadGate.verdict(true, "never shown", load: 0) == .pass)
        LoadGate.expect(true, "never shown", load: 99)
        LoadGate.expect(true, "never shown", load: 0)
    }

    /// Under load a missed bound is not enforced (a known issue: the test still passes).
    @Test func missedBoundUnderLoadIsNotEnforced() {
        #expect(LoadGate.verdict(false, "synthetic: 1 fps < 120 fps", load: 31)
                == .notEnforced("synthetic: 1 fps < 120 fps [load average 31.0]"))
    }

    /// On a quiet machine a missed bound is a real issue.
    @Test func missedBoundWhenQuietFails() {
        #expect(LoadGate.verdict(false, "synthetic: 1 fps < 120 fps", load: 1)
                == .failure("synthetic: 1 fps < 120 fps [load average 1.0]"))
        #expect(LoadGate.verdict(false, "x", load: 30) == .failure("x [load average 30.0]"), "30 is not overloaded")
    }

    /// The measurement text is built only for a missed bound.
    @Test func measurementIsLazy() {
        var built = 0
        func text() -> String { built += 1; return "m" }
        _ = LoadGate.verdict(true, text(), load: 1)
        #expect(built == 0)
        _ = LoadGate.verdict(false, text(), load: 1)
        #expect(built == 1)
    }
}
