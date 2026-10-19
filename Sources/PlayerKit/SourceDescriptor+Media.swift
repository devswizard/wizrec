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
    /// Rules (until MediaEngine reports stream timescale, length and bit depth):
    /// - Images: one type-1 track, `editRate` 600, `range` [0, 1], `sampleRate` 0.
    /// - Shaders: one type-0 track, `editRate` 30, endless `range` (2^63 − 1), bit depth 32.
    /// - Video: `editRate` = the duration's timescale (the container's own unit), `rangeEnd`
    ///   its value; `sampleRate` = average fps rounded to 1/100 [?]; bit depth 24.
    /// - Audio: `editRate` = the sample rate, `rangeEnd` = length in samples; bit depth 16.
    /// - Other streams are skipped, so the index stays equal to `trackNumber`.
    public init(info: MediaInfo, src: String, lastModified: Date) {
        var tracks: [Track] = []
        switch info.kind {
        case .image:
            let size = info.streams.first?.pixelSize ?? .zero
            tracks = [Track(type: 1, editRate: 600, rangeEnd: 1, width: Int(size.width), height: Int(size.height),
                            sampleRate: Rational(0), bitDepth: 24, channelCount: 0)]
        case .shader:
            let size = info.streams.first?.pixelSize ?? CGSize(width: 1920, height: 1080)
            tracks = [Track(type: 0, editRate: 30, rangeEnd: Int64.max, width: Int(size.width), height: Int(size.height),
                            sampleRate: Rational(30), bitDepth: 32, channelCount: 0)]
        default:
            for s in info.streams {
                switch s.kind {
                case .video:
                    let (rate, end) = Self.unitsAndLength(s.duration, fallbackRate: 600)
                    tracks.append(Track(type: 0, editRate: rate, rangeEnd: end,
                                        width: Int(s.pixelSize.width), height: Int(s.pixelSize.height),
                                        sampleRate: Self.frameRate(s.nominalFrameRate), bitDepth: 24, channelCount: 0))
                case .audio:
                    let hz = Int64(s.sampleRate.rounded())
                    let rate = hz > 0 ? hz : 48000
                    let seconds = s.duration.isNumeric ? max(0, s.duration.seconds) : 0
                    tracks.append(Track(type: 2, editRate: rate, rangeEnd: Int64((seconds * Double(rate)).rounded()),
                                        width: 0, height: 0, sampleRate: Rational(rate), bitDepth: 16,
                                        channelCount: max(1, s.channelCount)))
                case .other:
                    continue
                }
            }
        }
        self.init(src: src, lastModified: lastModified, tracks: tracks)
    }

    /// Reads the file's modification date, then maps `info` (see `init(info:src:lastModified:)`).
    public init(info: MediaInfo, src: String) {
        let date = (try? info.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        self.init(info: info, src: src, lastModified: date ?? Date())
    }

    /// Timeline length of this source when placed at speed 1, ticks at `editRate`.
    /// Images and shaders have no natural length: `stillSeconds` (Camtasia's default image duration is [?]; 5 s).
    public func naturalDuration(editRate: Int64, stillSeconds: Double = 5) -> Int64 {
        let seconds = tracks.compactMap { t -> Double? in
            guard t.type != 1, t.editRate > 0, t.rangeEnd > 0, t.rangeEnd < Int64.max / 2 else { return nil }
            return Double(t.rangeEnd) / Double(t.editRate)
        }.max()
        return Int64(((seconds ?? stillSeconds) * Double(editRate)).rounded())
    }

    /// `(units per second, length in units)` for a stream duration; exact when the CMTime is.
    static func unitsAndLength(_ d: CMTime, fallbackRate: Int64) -> (Int64, Int64) {
        guard d.isNumeric, d.timescale > 0, d.value >= 0 else { return (fallbackRate, 0) }
        return (Int64(d.timescale), d.value)
    }

    /// Average fps as a rational with denominator 100, reduced (59.94 → 2997/50). Whole rates stay whole.
    static func frameRate(_ fps: Double) -> Rational {
        guard fps.isFinite, fps > 0 else { return Rational(0) }
        if abs(fps - fps.rounded()) < 1e-6 { return Rational(Int64(fps.rounded())) }
        return Rational(Int64((fps * 100).rounded()), 100)
    }
}
