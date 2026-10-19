import Foundation
import Testing

/// `LoadGate` itself (always runs; no timing involved).
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
        LoadGate.expect(true, "never shown", load: 99)
        LoadGate.expect(true, "never shown", load: 0)
    }

    /// Under load a missed bound is a known issue: the test still passes.
    @Test func missedBoundUnderLoadIsKnownIssue() {
        LoadGate.expect(false, "synthetic: 1 fps < 120 fps", load: 31)
    }

    /// On a quiet machine a missed bound is a real issue.
    @Test func missedBoundWhenQuietFails() {
        withKnownIssue("expected: LoadGate records a failure when load is low") {
            LoadGate.expect(false, "synthetic: 1 fps < 120 fps", load: 1)
        }
    }
}
