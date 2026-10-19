import CoreMedia
import Foundation
import MediaEngine
import TSCProjKit
@testable import AudioEngine

let tick: Int64 = 705_600_000
/// Ticks per sample at 48 kHz.
let tps48: Int64 = 14_700

/// Synthesized test media: Float32 WAV files from closures.
enum Synth {
    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Writes an IEEE-float WAV; `sample(channel, index)` gives each sample.
    static func wav(_ url: URL, rate: Int, channels: Int, frames: Int, _ sample: (Int, Int) -> Float) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = frames * channels * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 4)); u16(UInt16(channels * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var samples = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames { for c in 0..<channels { samples[i * channels + c] = sample(c, i) } }
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }

    static func sine(freq: Double, amp: Double, rate: Int, phase: Double = 0) -> (Int, Int) -> Float {
        { _, i in Float(amp * sin(2 * Double.pi * freq * Double(i) / Double(rate) + phase)) }
    }
}

/// Small hand-written projects (test input only; parsed with `Project(data:)` like any file).
enum P {
    static func project(tracks: [[String: Any]], sources: [[String: Any]], trackAttributes: [[String: Any]]? = nil,
                        normalise: Bool = false, target: Double = -18, timelineGain: Double? = nil) throws -> Project {
        var timeline: [String: Any] = ["id": 1, "sceneTrack": ["scenes": [["csml": ["tracks": tracks]]]]]
        timeline["trackAttributes"] = trackAttributes ?? tracks.map { _ in ["audioMuted": false, "solo": false] }
        if let timelineGain { timeline["gain"] = timelineGain }
        let root: [String: Any] = [
            "version": "10.0", "editRate": tick, "width": 1920, "height": 1080, "videoFormatFrameRate": 30,
            "audioFormatSampleRate": 48000, "targetLoudness": target, "shouldApplyLoudnessNormalization": normalise,
            "sourceBin": sources, "timeline": timeline,
        ]
        return try Project(data: JSONSerialization.data(withJSONObject: root))
    }

    static func source(_ id: Int, _ url: URL, channels: Int = 1, lufs: Double = 100.0, peak: Double = -1.0) -> [String: Any] {
        ["id": id, "src": url.path, "rect": [0, 0, 0, 0], "loudnessNormalization": true,
         "sourceTracks": [["type": 2, "editRate": 48000, "range": [0, 48000], "numChannels": channels,
                           "trackRect": [0, 0, 0, 0], "integratedLUFS": lufs, "peakLevel": peak]]]
    }

    static func track(_ index: Int, _ medias: [[String: Any]], extra: [String: Any] = [:],
                      transitions: [[String: Any]]? = nil) -> [String: Any] {
        var t: [String: Any] = ["trackIndex": index, "medias": medias, "parameters": [String: Any]()]
        if let transitions { t["transitions"] = transitions }
        for (k, v) in extra { t[k] = v }
        return t
    }

    static func clip(_ type: String, id: Int, src: Int? = nil, trackNumber: Int = 0, start: Int64, duration: Int64,
                     mediaStart: Any = 0, mediaDuration: Any? = nil, scalar: Any = 1,
                     parameters: [String: Any] = [:], effects: [[String: Any]] = [],
                     attributes: [String: Any] = [:], channelNumber: String? = nil,
                     extra: [String: Any] = [:]) -> [String: Any] {
        var c: [String: Any] = [
            "id": id, "_type": type, "start": start, "duration": duration, "mediaStart": mediaStart,
            "mediaDuration": mediaDuration ?? duration, "scalar": scalar, "parameters": parameters,
            "effects": effects, "attributes": attributes, "metadata": [String: Any](),
        ]
        if let src { c["src"] = src; c["trackNumber"] = trackNumber }
        if let channelNumber { c["channelNumber"] = channelNumber }
        for (k, v) in extra { c[k] = v }
        return c
    }

    static func keyframed(_ base: Double, _ kfs: [(time: Int64, end: Int64, value: Double)],
                          interp: String = "linr") -> [String: Any] {
        ["type": "double", "defaultValue": base, "interp": interp,
         "keyframes": kfs.map { ["time": $0.time, "endTime": $0.end, "duration": $0.end - $0.time,
                                 "value": $0.value, "interp": interp] }]
    }

    static func scene(_ p: Project) -> AudioScene {
        AudioScene(project: p) { URL(fileURLWithPath: $0.src) }
    }

    static func mixer(_ p: Project, rate: Double = 48_000, channels: Int = 2) -> AudioMixer {
        AudioMixer(scene: scene(p), pool: MediaPool(diskCacheDirectory: nil),
                   format: MixFormat(sampleRate: rate, channels: channels))
    }
}

/// Ticks of `s` seconds.
func sec(_ s: Double) -> Int64 { Int64((s * Double(tick)).rounded()) }

/// Index of the sample at `s` seconds in a 48 kHz render that starts at tick 0.
func idx(_ s: Double) -> Int { Int((s * 48_000).rounded()) }

func rms(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
}

/// Frequency estimate from positive-going zero crossings.
func frequency(_ x: ArraySlice<Float>, rate: Double) -> Double {
    var crossings: [Double] = []
    var prev = x.first ?? 0
    var i = x.startIndex + 1
    while i < x.endIndex {
        let v = x[i]
        if prev < 0 && v >= 0 {
            let frac = Double(-prev) / Double(v - prev)
            crossings.append(Double(i - 1) + frac)
        }
        prev = v
        i += 1
    }
    guard crossings.count > 2, let f = crossings.first, let l = crossings.last else { return 0 }
    return Double(crossings.count - 1) / ((l - f) / rate)
}

let demoBundleURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/demo project.cmproj")
let vlogBundleURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Moheshkali Dwip Vlog.cmproj")

func ffmpegPath() -> String? {
    ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
}
