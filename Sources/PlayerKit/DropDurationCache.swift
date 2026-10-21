import Foundation

/// Clip durations (ticks) of Finder files dragged over the timeline, for the landing preview
/// (`TimelineModel.fileClipDuration`). The first ask for a file starts one asynchronous probe and
/// answers nil; later asks answer the probed duration (nil for files that are no media). Each
/// file is probed at most once per cache.
@MainActor
public final class DropDurationCache {
    /// Probes one file: the clip duration in ticks, or nil when it would not import.
    public typealias Probe = @MainActor (URL) async -> Int64?

    private let probe: Probe
    /// Probed files; a nil value = probed, no usable media.
    private var known: [URL: Int64?] = [:]
    private var running: [URL: Task<Void, Never>] = [:]

    public init(probe: @escaping Probe) { self.probe = probe }

    /// The duration of `url` when probed, else nil (and the probe starts if it has not).
    public func duration(of url: URL) -> Int64? {
        let key = url.standardizedFileURL
        if let k = known[key] { return k }
        if running[key] == nil {
            running[key] = Task { [weak self, probe] in
                let d = await probe(key)
                guard let self else { return }
                self.known[key] = .some(d)
                self.running[key] = nil
            }
        }
        return nil
    }

    /// Waits for the probes started so far (tests).
    public func settle() async {
        while let t = running.values.first { await t.value }
    }

    /// Forgets every probed duration (e.g. after the project's frame rate changed).
    public func reset() {
        known = [:]
    }
}
