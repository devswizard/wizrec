import CoreMedia
import Foundation
import Testing
@testable import MediaEngine

/// QA12-2 (audio12 merged): decoded samples are converted to Float through pointers now
/// (AUD12-2). Interleaved stereo WAVs in every packed sample format libav hands over for PCM
/// (u8, s16, s32, f32, f64) decode at their own rate to exactly the documented conversion of
/// each stored sample, on the right channel.
@Suite struct SampleFormatDecodeTests {
    /// A packed sample format: WAV format tag, bits per sample, encoder and expected decode.
    struct Format: Sendable, CustomStringConvertible {
        let name: String
        let tag: UInt16
        let bits: Int
        /// Bytes of sample value `v` (a fraction in −1…1) and the Float the decoder must return.
        let encode: @Sendable (Double) -> ([UInt8], Float)
        var description: String { name }
    }

    static let formats: [Format] = [
        Format(name: "u8", tag: 1, bits: 8) { v in
            let q = UInt8(max(0, min(255, (v * 127 + 128).rounded())))
            return ([q], (Float(q) - 128) / 128)
        },
        Format(name: "s16", tag: 1, bits: 16) { v in
            let q = Int16(max(-32768, min(32767, (v * 32767).rounded())))
            return (le(q), Float(q) / 32768)
        },
        Format(name: "s32", tag: 1, bits: 32) { v in
            let q = Int32(max(-2_147_483_648, min(2_147_483_647, (v * 2_147_483_000).rounded())))
            return (le(q), Float(Double(q) / 2_147_483_648))
        },
        Format(name: "f32", tag: 3, bits: 32) { v in
            let f = Float(v)
            return (le(f.bitPattern), f)
        },
        Format(name: "f64", tag: 3, bits: 64) { v in
            return (le(v.bitPattern), Float(v))
        },
    ]

    private static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.littleEndian) { (b: UnsafeRawBufferPointer) -> [UInt8] in Array(b) }
    }

    /// Left: a slow ramp −0.9…0.9; right: a 997 Hz sine at 0.6 (so a channel swap or a stride
    /// slip shows).
    private static func value(_ channel: Int, _ i: Int, count: Int, rate: Int) -> Double {
        channel == 0 ? -0.9 + 1.8 * Double(i) / Double(count - 1)
            : 0.6 * sin(2 * Double.pi * 997 * Double(i) / Double(rate))
    }

    @Test(arguments: formats)
    func packedStereoDecodesExactly(_ format: Format) async throws {
        let dir = try Synth.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (rate, count) = (48_000, 12_000)
        var body: [UInt8] = []
        var expected: [[Float]] = [[], []]
        for i in 0..<count {
            for c in 0..<2 {
                let (bytes, f) = format.encode(Self.value(c, i, count: count, rate: rate))
                body += bytes
                expected[c].append(f)
            }
        }
        let url = dir.appendingPathComponent("\(format.name).wav")
        try Self.wav(body, tag: format.tag, bits: format.bits, rate: rate).write(to: url)

        let src = try await MediaPool().source(for: url)
        let range = CMTimeRange(start: .zero, duration: CMTime(value: Int64(count), timescale: Int32(rate)))
        let buf = try await src.audio(stream: 0, range: range, format: PCMFormat(sampleRate: Double(rate), channels: 2))
        #expect(buf.frameCount == count && buf.channels.count == 2)
        for c in 0..<2 {
            let got = buf.channels[c]
            let firstDiff = zip(got, expected[c]).enumerated().first { $0.element.0 != $0.element.1 }
            #expect(got.count == count && firstDiff == nil,
                    "\(format) channel \(c): first difference at \(String(describing: firstDiff))")
        }
    }

    /// A canonical WAV file (`fmt ` with 16 bytes, then `data`), stereo.
    private static func wav(_ body: [UInt8], tag: UInt16, bits: Int, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { d.append(contentsOf: le(v)) }
        func u16(_ v: UInt16) { d.append(contentsOf: le(v)) }
        let block = 2 * bits / 8
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + body.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(tag); u16(2); u32(UInt32(rate))
        u32(UInt32(rate * block)); u16(UInt16(block)); u16(UInt16(bits))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(body.count))
        d.append(contentsOf: body)
        return d
    }
}
