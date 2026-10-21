import Foundation
import Testing

/// Timing assertions that tolerate an overloaded machine (boards S4-QA-1, S4-QA-2).
///
/// A missed timing bound fails the test, unless the 1-minute load average (`getloadavg`) is
/// above `maxLoad`: then the measurement is recorded as a known issue, so it shows in the
/// test output without failing the run. Perf suites stay opt-in with `WIZREC_PERF=1`.
public enum LoadGate {
    /// 1-minute load average above which a missed timing bound is reported, not failed.
    public static let maxLoad = 30.0

    /// The 1-minute load average, or 0 when `getloadavg` fails.
    public static var loadAverage: Double {
        var l = [0.0, 0.0, 0.0]
        return getloadavg(&l, 3) >= 1 ? l[0] : 0
    }

    /// True when timing bounds are not representative (load average > `maxLoad`).
    public static func overloaded(_ load: Double = loadAverage) -> Bool { load > maxLoad }

    /// What `expect` does with one timing bound.
    public enum Verdict: Equatable, Sendable {
        /// The bound held: nothing recorded.
        case pass
        /// Missed on an overloaded machine: a known issue with this text (the test passes).
        case notEnforced(String)
        /// Missed on a quiet machine: a test issue with this text.
        case failure(String)
    }

    /// The verdict for the bound `ok` at 1-minute load average `load`; texts end with the load.
    public static func verdict(_ ok: Bool, _ measurement: @autoclosure () -> String,
                               load: Double = loadAverage) -> Verdict {
        guard !ok else { return .pass }
        let text = "\(measurement()) [load average \(String(format: "%.1f", load))]"
        return overloaded(load) ? .notEnforced(text) : .failure(text)
    }

    /// Expects the timing bound `ok`. `measurement` describes what was measured (with units).
    /// When `ok` is false and the machine is overloaded, records a known issue instead of failing.
    public static func expect(_ ok: Bool, _ measurement: @autoclosure () -> String,
                              load: Double = loadAverage, sourceLocation: SourceLocation = #_sourceLocation) {
        switch verdict(ok, measurement(), load: load) {
        case .pass:
            return
        case .notEnforced(let text):
            print("timing (not enforced, load average > \(Int(maxLoad))): \(text)")
            withKnownIssue(Comment(rawValue: "load average > \(Int(maxLoad)): timing bound not enforced"),
                           sourceLocation: sourceLocation) {
                Issue.record(Comment(rawValue: text), sourceLocation: sourceLocation)
            }
        case .failure(let text):
            Issue.record(Comment(rawValue: text), sourceLocation: sourceLocation)
        }
    }
}
