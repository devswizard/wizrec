import Foundation
import TimelineEngine
import TSCProjKit

/// Original synthetic test signals and an ITU-R BS.1770-4 loudness meter, for the
/// AU2 normalisation experiment (`docs/specs/audio.md` §5).
public enum AudioSignals {
    /// Sample rate of every AU2 signal, Hz.
    public static let sampleRate = 48_000

    // MARK: Loudness

    /// Integrated loudness (LUFS) of a mono signal at 48 kHz, per BS.1770-4: K-weighting,
    /// 400 ms blocks with 75 % overlap, −70 LUFS absolute gate, −10 LU relative gate.
    /// Returns −∞ for silence.
    public static func integratedLUFS(_ x: [Float]) -> Double {
        // K-weighting at 48 kHz (BS.1770-4 Table 1 and 2).
        func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v
            }
            return y
        }
        var k = biquad(x.map(Double.init), [1.53512485958697, -2.69169618940638, 1.19839281085285],
                       [1, -1.69065929318241, 0.73248077421585])
        k = biquad(k, [1, -2, 1], [1, -1.99004745483398, 0.99007225036621])
        let block = sampleRate * 4 / 10, step = sampleRate / 10
        guard k.count >= block else { return -.infinity }
        var prefix = [Double](repeating: 0, count: k.count + 1)
        for i in k.indices { prefix[i + 1] = prefix[i] + k[i] * k[i] }
        let z = stride(from: 0, through: k.count - block, by: step).map { (prefix[$0 + block] - prefix[$0]) / Double(block) }
        func lufs(_ v: Double) -> Double { -0.691 + 10 * log10(v) }
        let abs = z.filter { $0 > 0 && lufs($0) > -70 }
        guard !abs.isEmpty else { return -.infinity }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Sample peak, dBFS.
    public static func peakDBFS(_ x: [Float]) -> Double {
        20 * log10(Double(x.map { Swift.abs($0) }.max() ?? 0))
    }

    static func scaled(_ x: [Float], by dB: Double) -> [Float] {
        let g = Float(pow(10, dB / 20))
        return x.map { $0 * g }
    }

    // MARK: Signals

    /// Deterministic xorshift64* uniform noise in [−1, 1).
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 2_685_821_657_736_338_717) >> 11) / Double(1 << 52) - 1
        }
    }

    /// Pink noise (Paul Kellet's refined filter on white noise), `seconds` long, at `lufs`.
    /// With `peakLimit` (dBFS) the signal is hard-clipped there and re-levelled until both hold.
    public static func pinkNoise(seconds: Double, lufs: Double, peakLimit: Double? = nil, seed: UInt64 = 0x5EED) -> [Float] {
        var rng = Noise(state: seed)
        var b = [Double](repeating: 0, count: 7)
        var x = (0..<Int(seconds * Double(sampleRate))).map { _ -> Float in
            let w = rng.next()
            b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
            let p = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            return Float(p * 0.11)
        }
        for _ in 0..<8 {
            x = scaled(x, by: lufs - integratedLUFS(x))
            guard let limit = peakLimit, peakDBFS(x) > limit else { break }
            let l = Float(pow(10, limit / 20))
            x = x.map { min(l, max(-l, $0)) }
        }
        return x
    }

    /// A click train: one-cycle 1 kHz sine clicks at `peak` dBFS, spaced so the train
    /// measures `lufs` (high crest factor).
    public static func clickTrain(seconds: Double, lufs: Double, peak: Double) -> [Float] {
        let n = Int(seconds * Double(sampleRate))
        let amp = Float(pow(10, peak / 20))
        let click = (0..<48).map { amp * Float(sin(2 * Double.pi * Double($0) / 48)) }
        func train(rate: Double) -> [Float] {
            var x = [Float](repeating: 0, count: n)
            let spacing = max(48, Int((Double(sampleRate) / rate).rounded()))
            var i = spacing / 2
            while i + 48 <= n { x.replaceSubrange(i..<(i + 48), with: click); i += spacing }
            return x
        }
        var rate = 10.0
        var x = train(rate: rate)
        for _ in 0..<6 {
            let l = integratedLUFS(x)
            guard abs(l - lufs) > 0.05 else { break }
            rate *= pow(10, (lufs - l) / 10)
            x = train(rate: rate)
        }
        return x
    }

    // MARK: WAV

    /// Writes mono 16-bit PCM WAV at 48 kHz (TPDF-free rounding; signals stay well above the LSB).
    public static func writeWAV(_ x: [Float], to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(x.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in x {
            let v = Int16(max(-32768, min(32767, (Double(s) * 32767).rounded())))
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        try d.write(to: url, options: .atomic)
    }
}

/// `au2.json`: the AU2 signals, as generated and measured by `AudioSignals`.
public struct AU2Manifest: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        /// `a` … `e2`.
        public var id: String
        public var file: String
        public var track: Int
        /// Timeline position, seconds.
        public var start: Double
        public var duration: Double
        /// Clip `attributes.loudnessNormalization`.
        public var normalize: Bool
        /// Measured by our BS.1770-4 meter / sample peak.
        public var lufs: Double
        public var peakDBFS: Double
        public var note: String
    }
    public var targetLoudness: Double
    public var segments: [Segment]
    public var generator: String

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

extension AudioSignals {
    /// Builds `<caseDir>/au2-generated.cmproj` (the user opens it and saves it as `au2.cmproj`)
    /// and `au2.json`. Track 0: a, b, c, d, a end to end (10 s each); track 1: c at 45–55 s,
    /// overlapping the last a for 5 s. Built with `ProjectBundle.create` + TimelineEngine
    /// commands; `d`'s clip gets `attributes.loudnessNormalization: false`.
    @MainActor @discardableResult
    public static func writeAU2(to caseDir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: caseDir, withIntermediateDirectories: true)
        let signalsDir = caseDir.appendingPathComponent("signals", isDirectory: true)
        try fm.createDirectory(at: signalsDir, withIntermediateDirectories: true)
        let a = pinkNoise(seconds: 10, lufs: -40, peakLimit: -20, seed: 0xA)
        let b = clickTrain(seconds: 10, lufs: -30, peak: -1)
        let c = pinkNoise(seconds: 10, lufs: -10, peakLimit: -0.5, seed: 0xC)
        let files: [(String, [Float], String)] = [
            ("au2-a-pink-40LUFS.wav", a, "pink noise, −40 LUFS, low crest"),
            ("au2-b-clicks-30LUFS.wav", b, "click train, −30 LUFS, peak −1 dBFS (normalising would clip)"),
            ("au2-c-pink-10LUFS.wav", c, "pink noise, −10 LUFS (normalisation lowers it)"),
        ]
        for f in files { try writeWAV(f.1, to: signalsDir.appendingPathComponent(f.0)) }

        let bundleURL = caseDir.appendingPathComponent("au2-generated.cmproj", isDirectory: true)
        try? fm.removeItem(at: bundleURL)
        let bundle = try ProjectBundle.create(at: bundleURL, width: 1920, height: 1080, fps: 30)
        let undo = UndoStack(project: bundle.project)
        var ids: [String: Int64] = [:]
        for f in files {
            let src = try bundle.importFile(signalsDir.appendingPathComponent(f.0))
            let add = AddSource(SourceDescriptor(src: src, lastModified: Date(), tracks: [
                .init(type: 2, editRate: Int64(sampleRate), rangeEnd: Int64(f.1.count), width: 0, height: 0,
                      sampleRate: Rational(Int64(sampleRate)), bitDepth: 16, channelCount: 1),
            ]))
            try undo.perform(add)
            ids[f.0] = add.sourceID
        }
        try undo.perform(AddTrack(at: 1))
        let sec: Int64 = 705_600_000
        // (id, file index, track, start s, normalise, note)
        let plan: [(String, Int, Int, Int64, Bool, String)] = [
            ("a", 0, 0, 0, true, files[0].2), ("b", 1, 0, 10, true, files[1].2), ("c", 2, 0, 20, true, files[2].2),
            ("d", 0, 0, 30, false, "copy of a with clip loudnessNormalization false"),
            ("e1", 0, 0, 40, true, "a again; overlaps e2 for 5 s (45–50 s)"),
            ("e2", 2, 1, 45, true, "c on track 1, overlapping e1 for 5 s: per clip or on the mix?"),
        ]
        var segments: [AU2Manifest.Segment] = []
        for p in plan {
            guard let sid = ids[files[p.1].0] else { continue }
            let insert = InsertClip(sourceID: sid, track: p.2, start: p.3 * sec)
            try undo.perform(insert)
            if !p.4, let id = insert.clipID,
               let clip = bundle.project.tracks[p.2].clips.first(where: { $0.id == id }) {
                clip.object["attributes"]?.object?["loudnessNormalization"] = .bool(false)
            }
            segments.append(.init(id: p.0, file: files[p.1].0, track: p.2, start: Double(p.3), duration: 10,
                                  normalize: p.4, lufs: (integratedLUFS(files[p.1].1) * 100).rounded() / 100,
                                  peakDBFS: (peakDBFS(files[p.1].1) * 100).rounded() / 100, note: p.5))
        }
        try bundle.saveWithBackup()
        try AU2Manifest(targetLoudness: bundle.project.root["targetLoudness"]?.double ?? -18, segments: segments,
                        generator: TestGen.version).write(to: caseDir.appendingPathComponent("au2.json"))
        return bundleURL
    }
}
