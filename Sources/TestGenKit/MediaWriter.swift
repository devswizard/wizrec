import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaWriterError: Error, CustomStringConvertible {
    case setup(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .setup(let s): "media writer setup failed: \(s)"
        case .writeFailed(let s): "media write failed: \(s)"
        }
    }
}

/// Writes synthetic media (H.264 MP4 and PNG) for tests and generated test projects.
public enum MediaWriter {
    /// What `writeH264` produced, for filling in `sourceBin.sourceTracks`.
    public struct MovieInfo: Sendable {
        public var width: Int
        public var height: Int
        /// Frames per second (constant).
        public var fps: Int
        public var frameCount: Int
        /// Track media timescale (units per second); sample `i` has PTS `i × timescale / fps`.
        public var timescale: Int32
    }

    /// Encodes `frameCount` frames of `width`×`height` H.264 (High profile, no B-frames,
    /// BT.709 colour tags) at a constant `fps` into an `.mp4` at `url`, replacing any file there.
    /// `draw(n, ctx)` paints frame `n` into a BGRA bitmap context with a bottom-left origin.
    /// `bitsPerSecond`: average video bitrate.
    @discardableResult
    public static func writeH264(to url: URL, width: Int, height: Int, fps: Int, frameCount: Int,
                                 bitsPerSecond: Int? = nil,
                                 draw: (Int, CGContext) -> Void) throws -> MovieInfo {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let timescale = Int32(fps * 1000)
        writer.movieTimeScale = CMTimeScale(timescale)
        let bitrate = bitsPerSecond ?? max(500_000, width * height * fps / 6)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = CMTimeScale(timescale)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw MediaWriterError.setup("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaWriterError.setup(writer.error.map { "\($0)" } ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        for n in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard writer.status == .writing else { break }
            guard let pool = adaptor.pixelBufferPool else { throw MediaWriterError.setup("no pixel buffer pool") }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw MediaWriterError.writeFailed("pixel buffer allocation") }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            if let ctx { draw(n, ctx) }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard ctx != nil else { throw MediaWriterError.writeFailed("bitmap context") }
            let pts = CMTime(value: CMTimeValue(n) * 1000, timescale: CMTimeScale(timescale))
            if !adaptor.append(pb, withPresentationTime: pts) {
                throw MediaWriterError.writeFailed(writer.error.map { "\($0)" } ?? "append frame \(n)")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount) * 1000, timescale: CMTimeScale(timescale)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw MediaWriterError.writeFailed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
        }
        return MovieInfo(width: width, height: height, fps: fps, frameCount: frameCount, timescale: timescale)
    }

    /// Renders `width`×`height` with `draw` (bottom-left origin, sRGB) and saves it as PNG at `url`.
    public static func writePNG(to url: URL, width: Int, height: Int, draw: (CGContext) -> Void) throws {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaWriterError.setup("bitmap context") }
        draw(ctx)
        guard let image = ctx.makeImage() else { throw MediaWriterError.writeFailed("makeImage") }
        try writePNG(image, to: url)
    }

    /// Saves `image` as a PNG file at `url`.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MediaWriterError.setup("image destination for \(url.path)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MediaWriterError.writeFailed(url.path) }
    }
}
