import AVFoundation
import CoreMedia
import Foundation
import TestGenKit
import Testing

/// Presentation times (seconds) of every sample of the file's first track, and the file duration.
/// Samples are pulled on a private thread: a stuck reader fails the test with `PullStalled`
/// instead of hanging it (QA11-1).
func readBack(_ url: URL, type: AVMediaType) async throws -> (pts: [Double], duration: Double, size: CGSize) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: type).first)
    let size = type == .video ? try await track.load(.naturalSize) : .zero
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var pts: [Double] = []
    try await BlockingPull.samples("read back \(url.lastPathComponent)", reader: reader, output: output) { s in
        if CMSampleBufferGetNumSamples(s) > 0 { pts.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(s))) }
        return true
    }
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    return (pts.sorted(), duration, size)
}
