import Foundation
import Observation
import TSCProjKit

/// Output file naming for exports.
public enum ExportNaming {
    /// `<dir>/<base>.<ext>`, or `<base> 2.<ext>`, `<base> 3.<ext>`… when taken (by an existing
    /// file or by `reserved`, e.g. earlier jobs of the same batch).
    public static func uniqueURL(directory: URL, base: String, ext: String, reserved: Set<URL> = [],
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let clean = sanitized(base)
        var n = 1
        while true {
            let name = n == 1 ? "\(clean).\(ext)" : "\(clean) \(n).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !exists(url), !reserved.contains(url.standardizedFileURL) { return url }
            n += 1
        }
    }

    /// `base` without path separators or a leading dot; "Untitled" when empty.
    public static func sanitized(_ base: String) -> String {
        var s = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Untitled" : s
    }
}

/// Export jobs run one after another (batch export), with per-job progress and cancel.
/// The work itself is injected (`Runner`), so the queue is testable without encoding.
@MainActor @Observable
public final class ExportQueue {
    /// What a job is doing.
    public enum State: Equatable, Sendable {
        case waiting
        /// Fraction done, 0–1.
        case running(Double)
        case done
        case failed(String)
        case cancelled
    }

    /// One output file.
    public struct Job: Identifiable, Equatable, Sendable {
        public let id: Int
        /// Preset or user-visible description.
        public var name: String
        public var output: URL
        public var state: State = .waiting
    }

    /// Performs job `id` writing `output`; reports progress 0–1 (any thread) and checks
    /// `Task.isCancelled`. Throwing `CancellationError` marks the job cancelled.
    public typealias Runner = @MainActor (_ id: Int, _ output: URL, _ progress: @escaping @Sendable (Double) -> Void)
        async throws -> Void

    public private(set) var jobs: [Job] = []
    public var isRunning: Bool { task != nil }
    /// Mean progress over the current batch, 0–1.
    public var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        return jobs.map { j -> Double in
            switch j.state {
            case .waiting: 0
            case .running(let p): p
            case .done, .failed, .cancelled: 1
            }
        }.reduce(0, +) / Double(jobs.count)
    }

    private var nextID = 1
    private var task: Task<Void, Never>?
    private var cancelHooks: [Int: @MainActor () -> Void] = [:]
    private let runner: Runner

    public init(runner: @escaping Runner) { self.runner = runner }

    /// Adds a waiting job and returns its id. Starts the queue when idle.
    @discardableResult
    public func add(name: String, output: URL) -> Int {
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, name: name, output: output))
        startIfNeeded()
        return id
    }

    /// Outputs of jobs that have not finished (for unique naming).
    public var pendingOutputs: Set<URL> {
        Set(jobs.filter { $0.state == .waiting || { if case .running = $0.state { true } else { false } }($0) }
            .map { $0.output.standardizedFileURL })
    }

    /// Jobs still to finish (waiting or running). Closing the window or quitting asks first when > 0.
    public var activeJobCount: Int {
        jobs.filter { if case .running = $0.state { true } else { $0.state == .waiting } }.count
    }

    /// Cancels every active job and waits until the queue is idle, so partial outputs are
    /// removed before the window closes. Returns at once when nothing is active.
    public func cancelAllAndWait() async {
        cancelAll()
        await waitUntilIdle()
    }

    /// Called when job `id` is cancelled while running (e.g. `ExportSession.cancel()`).
    public func onCancel(_ id: Int, _ hook: @escaping @MainActor () -> Void) { cancelHooks[id] = hook }

    /// Cancels job `id` (waiting → skipped; running → stopped).
    public func cancel(_ id: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[i].state {
        case .waiting: jobs[i].state = .cancelled
        case .running:
            cancelHooks[id]?()
            current?.cancel()
        default: break
        }
    }

    /// Cancels the running job and every waiting one.
    public func cancelAll() {
        for j in jobs where j.state == .waiting { cancel(j.id) }
        if let r = jobs.first(where: { if case .running = $0.state { true } else { false } }) { cancel(r.id) }
    }

    /// Removes finished jobs from the list.
    public func clearFinished() {
        jobs.removeAll { [.done, .cancelled].contains($0.state) || { if case .failed = $0.state { true } else { false } }($0) }
    }

    /// Waits until the queue is idle (tests, scripted export).
    public func waitUntilIdle() async {
        while let t = task { await t.value }
    }

    private var current: Task<Void, Error>?

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, let i = self.jobs.firstIndex(where: { $0.state == .waiting }) {
                await self.runJob(at: i)
            }
            self?.task = nil
        }
    }

    private func runJob(at index: Int) async {
        let job = jobs[index]
        jobs[index].state = .running(0)
        let id = job.id
        let runner = self.runner
        let work = Task { @MainActor [weak self] in
            try await runner(id, job.output) { p in
                Task { @MainActor in self?.update(id, progress: p) }
            }
        }
        current = work
        let result = await work.result
        current = nil
        cancelHooks[id] = nil
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success: jobs[i].state = work.isCancelled ? .cancelled : .done
        case .failure(let e):
            jobs[i].state = (e is CancellationError || work.isCancelled) ? .cancelled : .failed(Self.describe(e))
        }
    }

    private func update(_ id: Int, progress p: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), case .running = jobs[i].state else { return }
        jobs[i].state = .running(min(max(p, 0), 1))
    }

    static func describe(_ e: any Error) -> String {
        if let l = e as? LocalizedError, let d = l.errorDescription { return d }
        return String(describing: e)
    }
}

/// Timeline ranges offered by the export sheet.
public enum ExportRange {
    /// Span of the selected top-level clips (ticks), or nil when none is selected.
    public static func selection(in project: Project, clipIDs: Set<Int64>) -> Range<Int64>? {
        let clips = project.tracks.flatMap(\.clips).filter { clipIDs.contains($0.id) }
        guard let lo = clips.map(\.start).min(), let hi = clips.map(\.end).max(), hi > lo else { return nil }
        return lo..<hi
    }
}
