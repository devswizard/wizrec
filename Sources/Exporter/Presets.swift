import CoreGraphics
import Foundation
import AudioEngine
import MediaEngine
import RenderEngine

/// The built-in export presets. Sizes are boxes the canvas is aspect-fitted into.
enum ExportPresets {
    static func preset(_ name: String, _ format: ExportFormat, size: CGSize? = nil, audio: Bool = true)
        -> ExportPreset {
        var s = ExportSettings(format: format)
        s.size = size
        s.includeAudio = audio
        return ExportPreset(name: name, settings: s)
    }

    static let all: [ExportPreset] = [
        preset("MP4 1080p (H.264)", .mp4(codec: "h264", bitrate: nil), size: CGSize(width: 1920, height: 1080)),
        preset("MP4 720p (H.264)", .mp4(codec: "h264", bitrate: nil), size: CGSize(width: 1280, height: 720)),
        preset("MP4 4K (H.264)", .mp4(codec: "h264", bitrate: nil), size: CGSize(width: 3840, height: 2160)),
        preset("MP4 1080p (HEVC)", .mp4(codec: "hevc", bitrate: nil), size: CGSize(width: 1920, height: 1080)),
        preset("MP4 4K (HEVC)", .mp4(codec: "hevc", bitrate: nil), size: CGSize(width: 3840, height: 2160)),
        preset("MP4 Project size (H.264)", .mp4(codec: "h264", bitrate: nil)),
        preset("MOV ProRes 422", .mov(profile: "422")),
        preset("MOV ProRes 422 HQ", .mov(profile: "422HQ")),
        preset("MOV ProRes 4444 (alpha)", .mov(profile: "4444")),
        preset("GIF 640 px, 15 fps", .gif(fps: 15), size: CGSize(width: 640, height: 640), audio: false),
        preset("GIF 480 px, 10 fps", .gif(fps: 10), size: CGSize(width: 480, height: 480), audio: false),
        preset("Audio M4A (AAC)", .audio(container: "m4a")),
        preset("Audio WAV (16-bit)", .audio(container: "wav")),
        preset("Audio MP3 (192 kbit/s)", .audio(container: "mp3")),
    ]
}

/// File extension for a format's output file (without the dot).
public extension ExportFormat {
    var fileExtension: String {
        switch self {
        case .mp4: "mp4"
        case .mov: "mov"
        case .gif: "gif"
        case .audio(let c): c.lowercased() == "aac" ? "m4a" : c.lowercased()
        }
    }
}

/// Runs several exports of one project one after another (batch export).
/// Overall progress 0–1 is the mean over jobs; `cancel()` stops the current job and skips the rest.
public actor ExportBatch {
    /// One output of the batch.
    public struct Job: Sendable, Equatable {
        public var settings: ExportSettings
        public var output: URL
        public init(settings: ExportSettings, output: URL) { self.settings = settings; self.output = output }
    }

    /// What happened to one job.
    public enum Outcome: Sendable, Equatable {
        case completed(URL)
        case failed(URL, ExportError)
        case skipped(URL)
    }

    public let jobs: [Job]
    private let scene: SceneModel
    private let audio: AudioScene
    private let pool: MediaPool
    private var current: ExportSession?
    private var cancelled = false

    /// Fraction of the whole batch done, 0–1.
    public private(set) var progress: Double = 0

    public init(scene: SceneModel, audio: AudioScene, pool: MediaPool, jobs: [Job]) {
        self.scene = scene; self.audio = audio; self.pool = pool; self.jobs = jobs
    }

    /// Runs every job in order; a failed job does not stop the others. Returns one outcome per job.
    public func run() async -> [Outcome] {
        var out: [Outcome] = []
        for (i, job) in jobs.enumerated() {
            if cancelled || Task.isCancelled { out.append(.skipped(job.output)); continue }
            let session = ExportSession(scene: scene, audio: audio, pool: pool, settings: job.settings,
                                        output: job.output)
            current = session
            let n = Double(jobs.count)
            await session.setProgressHandler { [weak self] p in
                Task { await self?.setProgress((Double(i) + p) / n) }
            }
            do {
                try await session.run()
                out.append(.completed(job.output))
            } catch let e as ExportError {
                out.append(e == .cancelled ? .skipped(job.output) : .failed(job.output, e))
            } catch {
                out.append(.failed(job.output, .failed(String(describing: error))))
            }
            current = nil
            setProgress(Double(i + 1) / n)
        }
        return out
    }

    public func cancel() async {
        cancelled = true
        await current?.cancel()
    }

    private func setProgress(_ p: Double) { progress = max(progress, min(p, 1)) }
}
