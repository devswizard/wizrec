import AVFoundation
import Foundation
import MediaEngine
import Testing
import WizRecTestSupport
@testable import Exporter

/// Thread-safe call counter.
final class CallCount: @unchecked Sendable {
    // @unchecked: `n` is only touched under `lock`.
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// Stands in for an AVAssetWriter stuck in CoreMedia: forwards status, error and cancel to the
/// real writer, but `finishWriting` never calls back.
final class NeverFinishingWriter: FinishableWriter {
    let base: AVAssetWriter
    let cancels: CallCount
    init(_ base: AVAssetWriter, cancels: CallCount) { self.base = base; self.cancels = cancels }
    var status: AVAssetWriter.Status { base.status }
    var error: (any Error)? { base.error }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {}
    func cancelWriting() { cancels.hit(); base.cancelWriting() }
}

/// A scripted writer for `WriterWait` unit tests (no AVFoundation).
final class FakeWriter: FinishableWriter, @unchecked Sendable {
    // @unchecked: immutable after init except through the thread-safe `CallCount`/semaphore.
    /// Delay before `finishWriting` calls back, seconds; nil = never.
    let finishAfter: TimeInterval?
    /// `cancelWriting` blocks until this is signalled (nil = returns at once).
    let cancelGate: DispatchSemaphore?
    let finishCallbacks = CallCount()
    init(finishAfter: TimeInterval?, cancelGate: DispatchSemaphore? = nil) {
        self.finishAfter = finishAfter; self.cancelGate = cancelGate
    }
    var status: AVAssetWriter.Status { .writing }
    var error: (any Error)? { nil }
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {
        guard let finishAfter else { return }
        let calls = finishCallbacks
        DispatchQueue.global().asyncAfter(deadline: .now() + finishAfter) { calls.hit(); handler() }
    }
    func cancelWriting() { cancelGate?.wait() }
}

/// Short bounds so a stuck writer fails fast in tests (production: finish 60 s, stall 30 s).
private let fast = WriterTimeouts(finish: 0.5, stall: 0.3, cancel: 2)

/// Runs `session` with the given writer hooks and fast timeouts on its own task.
private func start(_ session: ExportSession, hooks: WriterHooks) -> Task<Void, any Error> {
    ExportSession.$writerHooks.withValue(hooks) {
        ExportSession.$writerTimeouts.withValue(fast) {
            Task { try await session.run() }
        }
    }
}

/// Runs the export and expects `ExportError.encoderStalled(seconds: 1)` well before the test bound;
/// then the output must be absent, nothing left in `dir`, and the writer cancelled.
private func expectStall(_ session: ExportSession, hooks: WriterHooks, dir: URL, cancels: CallCount?) async throws {
    let clock = ContinuousClock()
    let began = clock.now
    let run = start(session, hooks: hooks)
    await #expect(throws: ExportError.encoderStalled(seconds: 1)) {
        try await Deadline.value(of: run, "stuck export to fail", seconds: 60)
    }
    let took = clock.now - began
    #expect(took < .seconds(30), "stall took \(took)")
    if let cancels {
        try await Deadline.poll("abandoned writer to be cancelled", seconds: 10, interval: 0.01) { cancels.value > 0 }
    }
    let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(left.isEmpty, "\(left)")
}

@Suite(.serialized) struct WriterWaitTests {
    @Test func finishThatNeverCallsBackTimesOut() async throws {
        let w = FakeWriter(finishAfter: nil)
        let task = Task { await WriterWait.finish(w, timeout: 0.2) }
        #expect(try await Deadline.value(of: task, "bounded finish", seconds: 10) == false)
    }

    @Test func finishInTimeSucceeds() async throws {
        let w = FakeWriter(finishAfter: 0.01)
        let task = Task { await WriterWait.finish(w, timeout: 10) }
        #expect(try await Deadline.value(of: task, "bounded finish", seconds: 20) == true)
    }

    /// A callback after the timeout is ignored (no second resume of the continuation).
    @Test func lateCallbackIsIgnored() async throws {
        let w = FakeWriter(finishAfter: 0.3)
        let task = Task { await WriterWait.finish(w, timeout: 0.05) }
        #expect(try await Deadline.value(of: task, "bounded finish", seconds: 10) == false)
        try await Deadline.poll("late callback", seconds: 10, interval: 0.01) { w.finishCallbacks.value == 1 }
    }

    /// `cancelWriting` blocked inside AVFoundation does not block the export.
    @Test func blockedCancelIsBounded() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let w = FakeWriter(finishAfter: nil, cancelGate: gate)
        let task = Task { await WriterWait.cancel(w, timeout: 0.2) }
        #expect(try await Deadline.value(of: task, "bounded cancel", seconds: 10) == false)
    }

    @Test func stallErrorReadsAsASentence() {
        let e: any Error = ExportError.encoderStalled(seconds: 60)
        let text = (e as? LocalizedError)?.errorDescription
        #expect(text == "The encoder stopped responding for 60 s. The export was stopped and the partial file removed.")
        #expect(e.localizedDescription == text)
        #expect((ExportError.failed("disk full") as LocalizedError).errorDescription == "disk full")
        #expect(WriterTimeouts() == WriterTimeouts(finish: 60, stall: 30, cancel: 10))
    }
}

/// EXP11-1: an AVAssetWriter that stops responding ends the export with `encoderStalled`.
@Suite(.enabled(if: hasGPU), .serialized) struct WriterStallTests {
    @Test func movieFinishThatNeverReturnsFails() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await movingProject(frames: 6)
        var s = ExportSettings(format: .mp4(codec: "h264", bitrate: nil))
        s.includeAudio = false
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(), settings: s,
                                    output: dir.appendingPathComponent("f.mp4"))
        let cancels = CallCount()
        let hooks = WriterHooks(wrapWriter: { NeverFinishingWriter($0, cancels: cancels) })
        try await expectStall(session, hooks: hooks, dir: dir, cancels: cancels)
    }

    @Test func movieWriterThatTakesNothingFails() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(),
                                    settings: ExportSettings(format: .mp4(codec: "h264", bitrate: nil)),
                                    output: dir.appendingPathComponent("r.mp4"))
        let cancels = CallCount()
        let hooks = WriterHooks(wrapWriter: { NeverFinishingWriter($0, cancels: cancels) }, inputReady: { false })
        try await expectStall(session, hooks: hooks, dir: dir, cancels: cancels)
    }

    @Test func audioReadyLoopStalls() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(),
                                    settings: ExportSettings(format: .audio(container: "m4a")),
                                    output: dir.appendingPathComponent("a.m4a"))
        let cancels = CallCount()
        let hooks = WriterHooks(wrapWriter: { NeverFinishingWriter($0, cancels: cancels) }, inputReady: { false })
        try await expectStall(session, hooks: hooks, dir: dir, cancels: cancels)
    }

    @Test func audioFinishThatNeverReturnsFails() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = try await avProject()
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(),
                                    settings: ExportSettings(format: .audio(container: "wav")),
                                    output: dir.appendingPathComponent("a.wav"))
        let cancels = CallCount()
        let hooks = WriterHooks(wrapWriter: { NeverFinishingWriter($0, cancels: cancels) })
        try await expectStall(session, hooks: hooks, dir: dir, cancels: cancels)
    }

    /// A stuck export keeps an existing file at the output path.
    @Test func stallKeepsPreviousOutput() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("keep.wav")
        try Data("previous export".utf8).write(to: out)
        let p = try await avProject()
        let session = ExportSession(scene: p.scene, audio: p.audio, pool: MediaPool(),
                                    settings: ExportSettings(format: .audio(container: "wav")), output: out)
        let cancels = CallCount()
        let run = start(session, hooks: WriterHooks(wrapWriter: { NeverFinishingWriter($0, cancels: cancels) }))
        await #expect(throws: ExportError.encoderStalled(seconds: 1)) {
            try await Deadline.value(of: run, "stuck export to fail", seconds: 60)
        }
        #expect(try Data(contentsOf: out) == Data("previous export".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["keep.wav"])
    }
}
