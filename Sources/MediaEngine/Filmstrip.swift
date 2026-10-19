// Filmstrip thumbnails on their own decoders (never the playback lanes), downscaled during
// colour conversion, cached in a small LRU.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One filmstrip picture.
// @unchecked: CGImage is immutable once created, so sharing it across actors is safe.
public struct Thumbnail: @unchecked Sendable {
    /// The time asked for (stream time).
    public let requestedTime: CMTime
    /// Stream time of the picture shown (a keyframe at or before `requestedTime` unless exact).
    public let presentationTime: CMTime
    /// sRGB image, longer side ≤ the requested `maxPixelSize` px.
    public let image: CGImage

    public init(requestedTime: CMTime, presentationTime: CMTime, image: CGImage) {
        self.requestedTime = requestedTime; self.presentationTime = presentationTime; self.image = image
    }
}

/// How exact filmstrip pictures are.
public enum ThumbnailAccuracy: Sendable, Equatable {
    /// The frame on screen at the time (decodes up to one GOP per picture).
    case exact
    /// The keyframe at or before the time: one picture decoded per thumbnail (filmstrips).
    case nearestKeyframe
}

/// Decodes thumbnails of one video stream on a private serial queue.
actor ThumbnailDecoder {
    private let queue: DispatchSerialQueue
    private let core: VideoDecodeCore
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(url: URL, streamIndex: Int) throws {
        queue = DispatchSerialQueue(label: "wizrec.media.thumbnail.\(streamIndex)", qos: .utility)
        core = try VideoDecodeCore(url: url, streamIndex: streamIndex, allowHardware: true)
    }

    func keyframeOrdinal(at time: CMTime) -> Int? { core.keyframeOrdinal(at: time) }

    func thumbnail(at time: CMTime, exact: Bool, maxPixelSize: Int) throws -> (CGImage, CMTime) {
        let (buf, pts) = try core.thumbnailFrame(at: time, exact: exact, maxPixelSize: maxPixelSize)
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buf, options: nil, imageOut: &img)
        guard let img else { throw MediaError.decodeFailed("cannot make thumbnail image") }
        return (img, pts)
    }
}

/// Thumbnail decoders and their cache, separate from a pool's playback decoders.
actor ThumbnailService {
    private struct DecoderKey: Hashable { let url: URL; let stream: Int }
    private struct CacheKey: Hashable {
        let url: URL, stream: Int, maxPixelSize: Int
        /// Keyframe ordinal (nearest-keyframe mode) or requested time in µs (exact / no index).
        let slot: Int64
        let exact: Bool
    }
    private struct Entry { let image: CGImage; let pts: CMTime; let bytes: Int; var lastUse: UInt64 }

    let limitBytes: Int
    private var decoders: [DecoderKey: ThumbnailDecoder] = [:]
    private var cache: [CacheKey: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    init(limitBytes: Int) { self.limitBytes = limitBytes }

    private func decoder(url: URL, stream: Int, containerIndex: Int) throws -> ThumbnailDecoder {
        let k = DecoderKey(url: url, stream: stream)
        if let d = decoders[k] { return d }
        let d = try ThumbnailDecoder(url: url, streamIndex: containerIndex)
        decoders[k] = d
        return d
    }

    func thumbnail(url: URL, stream: Int, containerIndex: Int, time: CMTime, maxPixelSize: Int,
                   accuracy: ThumbnailAccuracy) async throws -> Thumbnail {
        let d = try decoder(url: url, stream: stream, containerIndex: containerIndex)
        let exact = accuracy == .exact
        var slot = Int64(((time.isNumeric ? time.seconds : 0) * 1e6).rounded())
        if !exact, let k = await d.keyframeOrdinal(at: time) { slot = Int64(k) }
        let key = CacheKey(url: url, stream: stream, maxPixelSize: maxPixelSize, slot: slot, exact: exact)
        clock &+= 1
        if var e = cache[key] {
            e.lastUse = clock
            cache[key] = e
            return Thumbnail(requestedTime: time, presentationTime: e.pts, image: e.image)
        }
        let (img, pts) = try await d.thumbnail(at: time, exact: exact, maxPixelSize: maxPixelSize)
        let size = img.bytesPerRow * img.height
        if size <= limitBytes {
            cache[key] = Entry(image: img, pts: pts, bytes: size, lastUse: clock)
            bytes += size
            while bytes > limitBytes, let victim = cache.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                bytes -= victim.value.bytes
                cache[victim.key] = nil
            }
        }
        return Thumbnail(requestedTime: time, presentationTime: pts, image: img)
    }

    func purge() {
        decoders.removeAll()
        cache.removeAll()
        bytes = 0
    }

    var cachedCount: Int { cache.count }
}
