import AVFoundation
import AudioEngine
import CoreGraphics
import Foundation
import MediaEngine
import RenderEngine
import TSCProjKit

/// Settings resolved against the scene: what `run()` actually writes.
struct ResolvedExport: Sendable {
    /// Timeline span, ticks (clamped to ≥ 1 tick).
    var range: Range<Int64>
    /// Output frame grid (video formats and GIF).
    var timing: FrameTiming
    /// Output frame size, px.
    var size: CGSize
}

extension ExportSession {
    /// Resolves defaults: range = whole timeline, fps = project rate (GIF: its own), size = canvas fit.
    func resolve() throws -> ResolvedExport {
        let editRate = scene.timebase.editRate
        let whole = 0..<max(scene.duration, 0)
        let range = settings.range ?? whole
        guard range.upperBound > range.lowerBound else { throw ExportError.failed("empty export range") }
        var fps = settings.frameRate ?? scene.frameRate
        if case .gif(let gfps) = settings.format {
            // GIF delays are centiseconds and viewers clamp delays < 2 cs: cap at 50 fps.
            fps = Rational(Int64(min(max(gfps, 1), 50)))
        }
        let timing = FrameTiming(editRate: editRate, fps: fps, range: range)
        let even: Bool
        switch settings.format {
        case .mp4, .mov: even = true
        default: even = false
        }
        let box = settings.size ?? scene.canvasSize
        let size = CGSize.aspectFit(scene.canvasSize, in: box, even: even)
        return ResolvedExport(range: range, timing: timing, size: size)
    }

    func perform() async throws {
        let r = try resolve()
        let work = Self.workDirectory(for: output)
        Self.sweepStaleWorkDirectories(near: output)
        let partial = work.appendingPathComponent(output.lastPathComponent)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            switch settings.format {
            case .mp4(let codec, let bitrate):
                let c: VideoCodec
                switch codec.lowercased() {
                case "h264", "avc", "avc1": c = .h264(bitrate: bitrate)
                case "hevc", "h265", "hvc1": c = .hevc(bitrate: bitrate)
                default: throw ExportError.failed("unsupported MP4 codec \(codec)")
                }
                try await writeMovie(to: partial, fileType: .mp4, codec: c, resolved: r)
            case .mov(let profile):
                let c: VideoCodec
                switch profile.uppercased() {
                case "422": c = .proRes422
                case "422HQ": c = .proRes422HQ
                case "4444": c = .proRes4444
                default: throw ExportError.failed("unsupported ProRes profile \(profile)")
                }
                try await writeMovie(to: partial, fileType: .mov, codec: c, resolved: r)
            case .gif:
                try await writeGIF(to: partial, resolved: r)
            case .audio(let container):
                switch container.lowercased() {
                case "m4a", "aac": try await writeAudioFile(to: partial, kind: .m4a, range: r.range)
                case "wav", "wave": try await writeAudioFile(to: partial, kind: .wav, range: r.range)
                case "mp3": try await writeMP3(to: partial, range: r.range)
                default: throw ExportError.failed("unsupported audio container \(container)")
                }
            }
            if isCancelled { throw ExportError.cancelled }
            try Self.moveIntoPlace(partial, output)
        } catch {
            if isCancelled { throw ExportError.cancelled }
            if let e = error as? ExportError { throw e }
            if error is CancellationError { throw ExportError.cancelled }
            throw ExportError.failed(String(describing: error))
        }
    }

    /// Hidden sibling directory of `output` that receives the file (and any writer temp files)
    /// while it is written; removed afterwards whatever happens. Same volume, so the final move is atomic.
    /// Named `.wizrec-export-<pid>-<uuid>` so `sweepStaleWorkDirectories` can tell live ones apart.
    static func workDirectory(for output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(
            "\(workPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    }

    static let workPrefix = ".wizrec-export-"

    /// Removes work directories next to `output` left by exports whose process no longer runs
    /// (a crash or hard kill). Directories of live processes, this one included, are kept.
    static func sweepStaleWorkDirectories(near output: URL) {
        let fm = FileManager.default
        let parent = output.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(workPrefix) {
            let rest = name.dropFirst(workPrefix.count)
            guard let pid = rest.split(separator: "-", maxSplits: 1).first.flatMap({ Int32($0) }), pid > 0 else {
                continue  // pre-pid name or not ours: leave it
            }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? fm.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    static func moveIntoPlace(_ partial: URL, _ output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: output)
        }
    }

    /// The project mix (48 kHz stereo), or nil when `includeAudio` is off.
    func makeMixer() -> AudioMixer? {
        settings.includeAudio ? requireMixer() : nil
    }

    /// The project mix for audio-only formats (they ignore `includeAudio`).
    func requireMixer() -> AudioMixer {
        AudioMixer(scene: audioScene, pool: pool, format: MixFormat(sampleRate: 48_000, channels: 2))
    }

    /// Sleeps briefly while the writer drains (AVAssetWriter has no async readiness API).
    func pause() async throws {
        if isCancelled { throw ExportError.cancelled }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
