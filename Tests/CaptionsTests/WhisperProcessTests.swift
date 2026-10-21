import Foundation
import Testing
import WizRecTestSupport
@testable import Captions

/// `WhisperProcess` against `/bin/sh` one-liners: the stderr a process writes before it exits
/// must always reach `stderrTail`, however fast it exits (CAP12-1).
@Suite struct WhisperProcessTests {
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    private static func run(_ script: String) async throws -> WhisperProcess.Result {
        try await WhisperProcess.run(sh, arguments: ["-c", script], progress: nil)
    }

    /// A process that writes one line and exits at once raced its own stderr: the termination
    /// path could finish before the reader appended the line, and the error lost its reason.
    @Test func fastExitKeepsStderr() async throws {
        for i in 0..<200 {
            let r = try await Self.run("echo 'error: failed to open model \(i)' >&2; exit 3")
            #expect(r.status == 3)
            #expect(r.stderrTail.contains("failed to open model \(i)"), "run \(i): \(r.stderrTail.debugDescription)")
        }
    }

    /// Runs overlap, as several transcriptions may.
    @Test func concurrentFastExitsKeepStderr() async throws {
        try await withThrowingTaskGroup(of: (Int, WhisperProcess.Result).self) { g in
            for i in 0..<64 {
                g.addTask { (i, try await Self.run("echo 'boom \(i)' >&2; exit 7")) }
            }
            for try await (i, r) in g {
                #expect(r.status == 7)
                #expect(r.stderrTail.contains("boom \(i)"), "run \(i): \(r.stderrTail.debugDescription)")
            }
        }
    }

    /// A last line without a newline still counts.
    @Test func unterminatedLastLineKept() async throws {
        let r = try await Self.run("printf 'no newline here' >&2; exit 1")
        #expect(r.status == 1)
        #expect(r.stderrTail.contains("no newline here"))
    }

    /// Lots of stderr and stdout drain fully (no pipe-buffer deadlock); the tail keeps the end.
    @Test func largeOutputDrains() async throws {
        let script = "i=0; while [ $i -lt 3000 ]; do echo \"line $i\" >&2; echo out $i; i=$((i+1)); done; echo last >&2; exit 2"
        let r = try await Self.run(script)
        #expect(r.status == 2)
        #expect(r.stderrTail.hasSuffix("last"))
        #expect(r.stderrTail.contains("line 2999"))
    }

    /// A background child that inherits stderr keeps the pipe open after the tool exits: the
    /// result still arrives within the bounded drain wait, with what was written.
    @Test func inheritedStderrDoesNotHang() async throws {
        let started = Date()
        let r = try await Self.run("echo 'before exit' >&2; sleep 60 & exit 4")
        let took = Date().timeIntervalSince(started)
        #expect(r.status == 4)
        #expect(r.stderrTail.contains("before exit"))
        // Far below the child's 60 s, far above the 2 s drain bound: a loaded CI runner took
        // 9.5 s (run 36), and the old code waited for the child.
        #expect(took < 30, "returned without waiting for the child, took \(took) s")
    }

    /// Progress lines become callbacks, not tail text.
    @Test func progressLinesReported() async throws {
        let seen = Seen()
        let script = """
            echo 'whisper_print_progress_callback: progress =  40%' >&2
            echo 'whisper_print_progress_callback: progress = 80%' >&2
            exit 0
            """
        let r = try await WhisperProcess.run(Self.sh, arguments: ["-c", script], progress: { seen.add($0) })
        #expect(r.status == 0)
        #expect(!r.stderrTail.contains("progress"))
        #expect(seen.values == [0.4, 0.8])
    }
}

// @unchecked Sendable: `v` is read and written only under `lock`.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Double] = []
    func add(_ x: Double) { lock.lock(); v.append(x); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return v }
}
