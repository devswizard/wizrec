// `sourceTracks` timing (editRate + range) as Camtasia records it: the AVFoundation track
// time range, exact (value / timescale). Matches every demo and vlog source [obs]:
// .trec 44100 (movie timescale, empty edits included), mp4 video 60000, mp4 audio 240000
// (AAC priming removed, lcm of 60000 and 48000), .m4a 48000 (gapless length), .mp3 44100.
// AVFoundation is used for metadata only; decoding stays on libav.

import AVFoundation
import CoreMedia
import Foundation

enum TrackTiming {
    /// Replaces `timescale`/`length` of each stream with AVFoundation's track time range when
    /// AVFoundation lists the same audio/video tracks in the same order; keeps libav's otherwise.
    static func apply(to info: inout MediaInfo) async {
        var options: [String: Any] = [:]
        // `.trec` is QuickTime; AVFoundation refuses the unknown extension without a hint.
        if info.url.pathExtension.lowercased() == Prober.recordingExtension {
            options[AVURLAssetOverrideMIMETypeKey] = "video/quicktime"
        }
        let asset = AVURLAsset(url: info.url, options: options)
        guard let all = try? await asset.load(.tracks) else { return }
        let tracks = all.filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard tracks.count == info.streams.count else { return }
        var ranges: [CMTimeRange] = []
        for (t, s) in zip(tracks, info.streams) {
            guard (t.mediaType == .video) == (s.kind == .video),
                  let r = try? await t.load(.timeRange),
                  r.duration.isNumeric, r.duration.timescale > 0, r.duration.value >= 0
            else { return }
            ranges.append(r)
        }
        for (i, r) in ranges.enumerated() {
            // `range[0]` is 0 in every project [obs]; the length includes any leading empty edit.
            let end = CMTimeRangeGetEnd(r)
            let e = end.timescale == r.duration.timescale ? end : CMTimeConvertScale(end, timescale: r.duration.timescale, method: .roundHalfAwayFromZero)
            info.streams[i].timescale = e.timescale
            info.streams[i].length = e.value
        }
    }
}
