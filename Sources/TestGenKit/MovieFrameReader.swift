import AVFoundation
import CoreMedia
import Foundation

public enum MovieReadError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case readerFailed(String)
    case missingFrames([Int], frameCount: Int)

    public var description: String {
        switch self {
        case .noVideoTrack(let u): "no video track in \(u.path)"
        case .readerFailed(let s): "AVAssetReader failed: \(s)"
        case .missingFrames(let f, let n): "frames \(f) not in movie (it has \(n) frames)"
        }
    }
}

/// Exact frame extraction from a movie's first video track (reference exports, generated media).
///
/// Frames are counted in presentation order from the first decoded sample, so
/// "frame n" is the n-th picture the file shows, independent of timestamps and
/// edit lists. For a constant-frame-rate export that is the picture at `n / fps` s.
public enum MovieFrameReader {
    /// Basic facts about the first video track.
    public struct Info: Sendable {
        /// Pixel size of the track.
        public var width: Int, height: Int
        /// Nominal frames per second.
        public var fps: Double
        /// Track duration, seconds.
        public var duration: Double
    }

    public static func info(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MovieReadError.noVideoTrack(url)
        }
        let (size, fps, range) = try await track.load(.naturalSize, .nominalFrameRate, .timeRange)
        return Info(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                    fps: Double(fps), duration: range.duration.seconds)
    }

    /// Decodes the movie sequentially and calls `body(index, pts, frame)` for every frame,
    /// in presentation order, until `body` returns `false`.
    public static func forEachFrame(_ url: URL,
                                    _ body: (Int, CMTime, CVPixelBuffer) throws -> Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MovieReadError.noVideoTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MovieReadError.readerFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else {
            throw MovieReadError.readerFailed(reader.error.map { "\($0)" } ?? "startReading")
        }
        var index = 0
        // Decoded on a private thread: a stalled decoder fails with `PullStalled` (QA11-1). An early
        // stop cancels the reader there, once the thread is out of its pull; never cancel it here.
        try await BlockingPull.samples("frames of \(url.lastPathComponent)", reader: reader, output: output) { sample in
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { return true }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let keepGoing = try body(index, pts, pb)
            index += 1
            return keepGoing
        }
        if reader.status == .failed {
            throw MovieReadError.readerFailed(reader.error.map { "\($0)" } ?? "read")
        }
    }

    /// Frames `indices` (0-based, presentation order) as RGBA images. Throws if any index is past the end.
    public static func frames(_ url: URL, indices: [Int]) async throws -> [Int: RGBAImage] {
        let wanted = Set(indices)
        guard let last = wanted.max() else { return [:] }
        var out: [Int: RGBAImage] = [:]
        var count = 0
        try await forEachFrame(url) { i, _, pb in
            count = i + 1
            if wanted.contains(i), let img = RGBAImage(pixelBuffer: pb) { out[i] = img }
            return i < last
        }
        let missing = wanted.subtracting(out.keys).sorted()
        if !missing.isEmpty { throw MovieReadError.missingFrames(missing, frameCount: count) }
        return out
    }
}
