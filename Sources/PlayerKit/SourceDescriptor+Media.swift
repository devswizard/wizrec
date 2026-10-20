import CoreMedia
import Foundation
import MediaEngine
import TimelineEngine
import TSCProjKit

extension SourceDescriptor {
    /// Maps a probe result to the `sourceBin` fields TimelineEngine writes
    /// (`docs/specs/media-streams.md` §3).
    ///
    /// - `src`: project-relative path from `ProjectBundle.importFile`, or an absolute path.
    /// - `lastModified`: the file's modification date (`lastMod`).
    ///
    /// Each audio/video stream becomes one track (other streams are skipped, so the index
    /// stays equal to `trackNumber`): `type` = `trackType`, `editRate` = `timescale`,
    /// `rangeEnd` = `length`, `bitDepth` as MediaEngine reports it. Video `sampleRate` is the
    /// average fps rounded to 1/100 (59.94 → `2997/50`), 1/10000 for recordings; audio `sampleRate` is in Hz.
    /// Streams without that metadata fall back to: video = duration timescale/value, audio =
    /// sample rate/samples, images 600/[0, 1], shaders 30/[0, 2^63 − 1].
    public init(info: MediaInfo, src: String, lastModified: Date) {
        var tracks: [Track] = []
        for s in info.streams where s.kind != .other {
            let isImage = s.trackType == 1 || info.kind == .image
            let type = isImage ? 1 : (s.kind == .audio ? 2 : 0)
            var rate = Int64(s.timescale)
            var end = s.length
            if rate <= 0 || end <= 0 {
                switch type {
                case 1: (rate, end) = (600, 1)
                case 2:
                    let hz = Int64(s.sampleRate.rounded())
                    rate = hz > 0 ? hz : 48000
                    end = Int64(((s.duration.isNumeric ? max(0, s.duration.seconds) : 0) * Double(rate)).rounded())
                default:
                    if info.kind == .shader { (rate, end) = (30, Int64.max) }
                    else { (rate, end) = Self.unitsAndLength(s.duration, fallbackRate: 600) }
                }
            }
            let sampleRate: Rational = switch type {
            case 1: Rational(0)
            case 2: Rational(max(1, Int64(s.sampleRate.rounded())))
            default: Self.frameRate(s.frameRate?.double ?? s.nominalFrameRate, decimals: info.kind == .recording ? 4 : 2)
            }
            tracks.append(Track(type: type, editRate: rate, rangeEnd: end,
                                width: type == 2 ? 0 : Int(s.pixelSize.width), height: type == 2 ? 0 : Int(s.pixelSize.height),
                                sampleRate: sampleRate, bitDepth: s.bitDepth,
                                channelCount: type == 2 ? max(1, s.channelCount) : 0))
        }
        if tracks.isEmpty, info.kind == .shader {
            tracks = [Track(type: 0, editRate: 30, rangeEnd: Int64.max, width: 1920, height: 1080,
                            sampleRate: Rational(30), bitDepth: 32, channelCount: 0)]
        }
        self.init(src: src, lastModified: lastModified, tracks: tracks)
    }

    /// Reads the file's modification date, then maps `info` (see `init(info:src:lastModified:)`).
    public init(info: MediaInfo, src: String) {
        let date = (try? info.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        self.init(info: info, src: src, lastModified: date ?? Date())
    }

    /// Timeline length of this source when placed at speed 1, ticks at `editRate`.
    /// Images have no natural length: `stillSeconds` (Camtasia's default image duration is [?]; 5 s).
    /// Shader backgrounds (an endless video track) get `shaderSeconds`, 60 s [obs, shader-backgrounds.md SH2].
    public func naturalDuration(editRate: Int64, stillSeconds: Double = 5, shaderSeconds: Double = 60) -> Int64 {
        let seconds = tracks.compactMap { t -> Double? in
            guard t.type != 1, t.editRate > 0, t.rangeEnd > 0, t.rangeEnd < Int64.max / 2 else { return nil }
            return Double(t.rangeEnd) / Double(t.editRate)
        }.max()
        let endless = tracks.contains { $0.type == 0 && $0.rangeEnd >= Int64.max / 2 }
        return Int64(((seconds ?? (endless ? shaderSeconds : stillSeconds)) * Double(editRate)).rounded())
    }

    /// `(units per second, length in units)` for a stream duration; exact when the CMTime is.
    static func unitsAndLength(_ d: CMTime, fallbackRate: Int64) -> (Int64, Int64) {
        guard d.isNumeric, d.timescale > 0, d.value >= 0 else { return (fallbackRate, 0) }
        return (Int64(d.timescale), d.value)
    }

    /// Average fps rounded to `decimals` places as a reduced rational: 2 for movies
    /// (60000/1001 → 2997/50), 4 for `.trec` recordings (5.33524 → 6669/1250) [obs, media-streams.md §3].
    /// Whole rates stay whole.
    static func frameRate(_ fps: Double, decimals: Int = 2) -> Rational {
        guard fps.isFinite, fps > 0 else { return Rational(0) }
        if abs(fps - fps.rounded()) < 1e-6 { return Rational(Int64(fps.rounded())) }
        var den: Int64 = 1
        for _ in 0..<max(0, decimals) { den *= 10 }
        return Rational(Int64((fps * Double(den)).rounded()), den)
    }
}
