// Synthesized test media. Each video frame shows its index as `bitCount` vertical
// stripes (white = 1, MSB first), which survives lossy compression.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import MediaEngine

enum Synth {
    static let bitCount = 10

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Fills a BGRA buffer with the stripe code for `index`.
    static func fill(_ buf: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let bit = x * bitCount / w
            let on = (index >> (bitCount - 1 - bit)) & 1 == 1
            let v: UInt8 = on ? 255 : 0
            for y in 0..<h {
                let o = y * bpr + x * 4
                p[o] = v; p[o + 1] = v; p[o + 2] = v; p[o + 3] = 255
            }
        }
    }

    /// Reads the stripe code back from a decoded frame.
    static func index(of buf: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return -1 }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var v = 0
        for bit in 0..<bitCount {
            let x = (bit * w + w / 2) / bitCount
            let o = (h / 2) * bpr + x * 4
            let lum = (Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])) / 3
            v = (v << 1) | (lum > 128 ? 1 : 0)
        }
        return v
    }

    /// BGRA value at (x, y).
    static func pixel(_ buf: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return (0, 0, 0, 0) }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let o = y * CVPixelBufferGetBytesPerRow(buf) + x * 4
        return (p[o], p[o + 1], p[o + 2], p[o + 3])
    }

    /// Writes a movie whose frame `i` (at `times[i]` seconds) shows code `i`.
    static func writeMovie(to url: URL, times: [Double], width: Int = 320, height: Int = 64,
                           codec: AVVideoCodecType = .h264, keyInterval: Int = 12,
                           fileType: AVFileType = .mp4) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalKey: keyInterval]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoAllowFrameReorderingKey] = true
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaError.decodeFailed("startWriting") }
        writer.startSession(atSourceTime: .zero)
        for (i, t) in times.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw MediaError.decodeFailed("no adaptor pool") }
            var b: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b)
            guard let buf = b else { throw MediaError.decodeFailed("no buffer") }
            fill(buf, index: i)
            guard adaptor.append(buf, withPresentationTime: CMTime(value: Int64((t * 600).rounded()), timescale: 600)) else {
                throw writer.error ?? MediaError.decodeFailed("append")
            }
        }
        input.markAsFinished()
        if let last = times.last { writer.endSession(atSourceTime: CMTime(seconds: last + 1.0 / 30, preferredTimescale: 600)) }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? MediaError.decodeFailed("finishWriting") }
    }

    /// 16-bit PCM WAV of a sine (`frequency` Hz, amplitude 0.5) on every channel.
    static func writeWAV(to url: URL, seconds: Double, sampleRate: Double = 44100, channels: Int = 1,
                         frequency: Double = 441) throws {
        let n = Int(seconds * sampleRate)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * channels * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * UInt32(channels * 2)); u16(UInt16(channels * 2)); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * channels * 2))
        for i in 0..<n {
            let v = Int16((0.5 * sin(2 * Double.pi * frequency * Double(i) / sampleRate) * 32767).rounded())
            for _ in 0..<channels { u16(UInt16(bitPattern: v)) }
        }
        try data.write(to: url)
    }

    /// Writes a PNG of a solid colour.
    static func writePNG(to url: URL, width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) throws {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaError.decodeFailed("ctx") }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(rgba.0) / 255, green: CGFloat(rgba.1) / 255,
                                 blue: CGFloat(rgba.2) / 255, alpha: CGFloat(rgba.3) / 255))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MediaError.decodeFailed("png") }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw MediaError.decodeFailed("png finalize") }
    }

    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs ffmpeg with `args`; throws on failure.
    static func ffmpeg(_ args: [String]) throws {
        guard let path = ffmpegPath else { throw MediaError.unsupported("ffmpeg missing") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw MediaError.decodeFailed("ffmpeg exit \(p.terminationStatus)") }
    }
}

/// The user's demo recording (read-only). Tests using it skip when it is absent.
enum Demo {
    static let trec = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/demo project.cmproj/recordings/1792376869.293257/Rec 10-19-2026.trec")
    static var available: Bool { FileManager.default.fileExists(atPath: trec.path) }
}
