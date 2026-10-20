import Foundation
import Testing
import WizRecTestSupport
@testable import PlayerKit

private struct Boom: Error {}

@Suite @MainActor struct ExportQueueTests {
    private let dir = URL(fileURLWithPath: "/tmp/out")

    @Test func namesAreUniqueAndClean() {
        let taken: Set<String> = ["/tmp/out/demo.mp4", "/tmp/out/demo 2.mp4"]
        let u = ExportNaming.uniqueURL(directory: dir, base: "demo", ext: "mp4") { taken.contains($0.path) }
        #expect(u.lastPathComponent == "demo 3.mp4")
        let r = ExportNaming.uniqueURL(directory: dir, base: "demo", ext: "gif",
                                       reserved: [dir.appendingPathComponent("demo.gif")]) { _ in false }
        #expect(r.lastPathComponent == "demo 2.gif")
        #expect(ExportNaming.sanitized(" ../a/b:c ") == "-a-b-c")
        #expect(ExportNaming.sanitized("  ") == "Untitled")
    }

    @Test func runsJobsInOrderWithProgressAndFailures() async {
        var order: [Int] = []
        let q = ExportQueue { id, _, progress in
            order.append(id)
            progress(0.5)
            await Task.yield()
            if id == 2 { throw Boom() }
            progress(1)
        }
        let a = q.add(name: "A", output: dir.appendingPathComponent("a.mp4"))
        let b = q.add(name: "B", output: dir.appendingPathComponent("b.mp4"))
        let c = q.add(name: "C", output: dir.appendingPathComponent("c.gif"))
        #expect(q.isRunning)
        await q.waitUntilIdle()
        #expect(order == [a, b, c])
        #expect(q.jobs.map(\.state) == [.done, .failed(String(describing: Boom())), .done])
        #expect(q.overallProgress == 1)
        #expect(!q.isRunning)
        q.clearFinished()
        #expect(q.jobs.isEmpty)
    }

    @Test func cancelStopsRunningAndSkipsWaiting() async throws {
        var hooked = false
        let q = ExportQueue { _, _, progress in
            progress(0.1)
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let a = q.add(name: "A", output: dir.appendingPathComponent("a.mp4"))
        _ = q.add(name: "B", output: dir.appendingPathComponent("b.mp4"))
        q.onCancel(a) { hooked = true }
        #expect(q.pendingOutputs.count == 2)
        try await Deadline.poll("first export job to start", seconds: 30, interval: 0) { q.jobs.first?.state != .waiting }
        q.cancelAll()
        await q.waitUntilIdle()
        #expect(q.jobs.map(\.state) == [.cancelled, .cancelled])
        #expect(hooked)
        #expect(q.pendingOutputs.isEmpty)
    }
}

@Suite @MainActor struct ExportCloseGuardTests {
    private let dir = URL(fileURLWithPath: "/tmp/out")

    @Test func asksOnlyWhileExportsAreActive() {
        let g = ExportCloseGuard()
        #expect(g.decide(activeJobs: 0) == .proceed)
        #expect(g.decide(activeJobs: 2) == .ask(jobs: 2))
        #expect(g.decide(activeJobs: 2, scripted: true) == .proceed)
        g.beginAsking()
        #expect(g.isAsking)
        g.answer(cancelExports: false)
        #expect(!g.isAsking)
        #expect(g.decide(activeJobs: 1) == .ask(jobs: 1))
        g.answer(cancelExports: true)
        #expect(g.decide(activeJobs: 1) == .proceed)
    }

    @Test func activeCountAndCancelAllAndWait() async throws {
        let q = ExportQueue { _, _, progress in
            progress(0.1)
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        #expect(q.activeJobCount == 0)
        await q.cancelAllAndWait()
        _ = q.add(name: "A", output: dir.appendingPathComponent("a.mp4"))
        _ = q.add(name: "B", output: dir.appendingPathComponent("b.mp4"))
        #expect(q.activeJobCount == 2)
        try await Deadline.poll("first export job to start", seconds: 30, interval: 0) { q.jobs.first?.state != .waiting }
        #expect(q.activeJobCount == 2)
        await q.cancelAllAndWait()
        #expect(!q.isRunning)
        #expect(q.activeJobCount == 0)
        #expect(q.jobs.map(\.state) == [.cancelled, .cancelled])
    }
}
