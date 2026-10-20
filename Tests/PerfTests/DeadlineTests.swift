import Foundation
import Testing
import WizRecTestSupport

/// `Deadline` and `TestProcess` themselves (always run; bounds of a second or less).
struct DeadlineTests {
    @Test func pollReturnsWhenConditionHolds() async throws {
        var n = 0
        try await Deadline.poll("n to reach 3", seconds: 5, interval: 0) {
            n += 1
            return n >= 3
        }
        #expect(n == 3)
    }

    @Test func pollTimesOut() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await Deadline.poll("never", seconds: 0.05, interval: 0.005) { false }
        }
    }

    @Test func valueReturnsTaskResult() async throws {
        let t = Task<Int, any Error> { 42 }
        #expect(try await Deadline.value(of: t, "answer", seconds: 5) == 42)
        let n = Task<String, Never> { "ok" }
        #expect(try await Deadline.value(of: n, "ok", seconds: 5) == "ok")
    }

    @Test func valuePassesTheTaskError() async {
        struct Boom: Error {}
        let t = Task<Int, any Error> { throw Boom() }
        await #expect(throws: Boom.self) { try await Deadline.value(of: t, "boom", seconds: 5) }
    }

    /// A stuck task: the wait gives up on time and cancels it.
    @Test func valueTimesOutAndCancels() async throws {
        let t = Task<Int, any Error> {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return 1
        }
        let start = Date()
        await #expect(throws: DeadlineExceeded.self) { try await Deadline.value(of: t, "sleeper", seconds: 0.1) }
        #expect(Date().timeIntervalSince(start) < 10)
        await #expect(throws: CancellationError.self) { try await t.value }
    }

    @Test func callbackResumesOnDone() async throws {
        try await Deadline.callback("immediate", seconds: 5) { done in done() }
        try await Deadline.callback("later", seconds: 5) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { done() }
        }
    }

    /// A completion handler that never fires (the CI `finishWriting` hang) fails instead of hanging;
    /// a late or repeated `done` afterwards is harmless.
    @Test func callbackTimesOut() async throws {
        nonisolated(unsafe) var saved: (@Sendable () -> Void)?
        await #expect(throws: DeadlineExceeded.self) {
            try await Deadline.callback("never", seconds: 0.05) { done in saved = done }
        }
        saved?()
        saved?()
    }

    @Test func blockingWaits() throws {
        try Deadline.blocking("async signal", seconds: 5) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { done() }
        }
        #expect(throws: DeadlineExceeded.self) { try Deadline.blocking("never", seconds: 0.05) { _ in } }
    }

    /// A completion that is delivered on the main queue (as `finishWriting` needs on the CI VM)
    /// still arrives while a main-actor test waits synchronously: no deadlock.
    @MainActor @Test func blockingOnMainKeepsMainQueueRunning() throws {
        try Deadline.blocking("main-queue completion", seconds: 5) { done in
            DispatchQueue.global().async { DispatchQueue.main.async { done() } }
        }
        let r = try TestProcess.run("/bin/sh", ["-c", "echo main"], seconds: 10)
        #expect(r.stdoutText == "main\n")
    }

    @Test func timeoutMessageNamesTheWait() {
        let e = DeadlineExceeded(what: "finishWriting a.mp4", seconds: 60)
        #expect(e.description.contains("finishWriting a.mp4") && e.description.contains("60 s"))
    }

    @Test func processCapturesOutputAndStatus() throws {
        let r = try TestProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], seconds: 10)
        #expect(r.status == 3)
        #expect(r.stdoutText == "out\n")
        #expect(r.stderrText == "err\n")
        let merged = try TestProcess.run("/bin/sh", ["-c", "echo a; echo b >&2"], stderr: .stdout, seconds: 10)
        #expect(merged.stdoutText.contains("a") && merged.stdoutText.contains("b"))
        #expect(merged.stderr.isEmpty)
    }

    /// Output larger than a pipe buffer (64 KB) does not block the tool.
    @Test func processDrainsLargeOutput() throws {
        let r = try TestProcess.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero"], seconds: 10)
        #expect(r.status == 0 && r.stdout.count == 1_000_000)
    }

    /// stdin is /dev/null, so a tool reading stdin sees EOF instead of waiting.
    @Test func processStdinIsEmpty() throws {
        let r = try TestProcess.run("/bin/cat", [], seconds: 10)
        #expect(r.status == 0 && r.stdout.isEmpty)
    }

    @Test func processTimesOutAndIsKilled() throws {
        let start = Date()
        #expect(throws: DeadlineExceeded.self) { try TestProcess.run("/bin/sleep", ["30"], seconds: 0.2) }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
