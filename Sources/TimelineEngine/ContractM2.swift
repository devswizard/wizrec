// M2/M3 public interface of TimelineEngine, frozen by coordination/CONTRACTS.md (M2 section).
// Stub bodies throw until agent "timeline" implements them.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import Foundation
import TSCProjKit

/// Everything needed to write a `sourceBin` entry, independent of MediaEngine.
/// The app fills it from `MediaPool.probe` (see `SourceDescriptor(info:src:)` in PlayerKit).
public struct SourceDescriptor: Sendable, Equatable {
    /// One `sourceTracks[]` entry.
    public struct Track: Sendable, Equatable {
        /// 0 = video, 1 = image, 2 = audio (FORMAT.md).
        public var type: Int
        /// Units per second of `rangeEnd` (stream timescale, e.g. 44100, 30, 600).
        public var editRate: Int64
        /// Stream length in `editRate` units (`range = [0, rangeEnd]`).
        public var rangeEnd: Int64
        /// Frame size, px (0 for audio).
        public var width: Int
        public var height: Int
        /// fps for video (exact rational string allowed, e.g. "30000/1001"), Hz for audio.
        public var sampleRate: Rational
        public var bitDepth: Int
        public var channelCount: Int
        public init(type: Int, editRate: Int64, rangeEnd: Int64, width: Int, height: Int,
                    sampleRate: Rational, bitDepth: Int, channelCount: Int) {
            self.type = type; self.editRate = editRate; self.rangeEnd = rangeEnd; self.width = width
            self.height = height; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.channelCount = channelCount
        }
    }

    /// Project-relative path, e.g. `"./media/1792376869.292854/clip.mp4"`.
    public var src: String
    /// File modification date (written as `lastMod`).
    public var lastModified: Date
    /// Audio/video tracks in container order (index = `trackNumber`).
    public var tracks: [Track]

    public init(src: String, lastModified: Date, tracks: [Track]) {
        self.src = src; self.lastModified = lastModified; self.tracks = tracks
    }
}

/// Track UI flags stored in `trackAttributes` (top level) or inline (inside groups).
public enum TrackFlag: String, Sendable, CaseIterable {
    case audioMuted, videoHidden, magnetic, solo, locked
}

/// Adds a `sourceBin` entry with an id above `Project.maxID`. `sourceID` is set after apply.
@MainActor public final class AddSource: EditCommand {
    public let name = "Import Media"
    public let descriptor: SourceDescriptor
    public private(set) var sourceID: Int64?
    public init(_ descriptor: SourceDescriptor) { self.descriptor = descriptor }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Places a source on a track at `start` (ticks) as the clip type its tracks imply
/// (`UnifiedMedia` for video+audio, `VMFile`, `AMFile`, `IMFile`). Overlap throws.
@MainActor public final class InsertClip: EditCommand {
    public let name = "Add to Timeline"
    public let sourceID: Int64
    public let track: Int
    public let start: Int64
    public private(set) var clipID: Int64?
    public init(sourceID: Int64, track: Int, start: Int64) {
        self.sourceID = sourceID; self.track = track; self.start = start
    }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Deletes clips; with `ripple`, later clips on the same tracks close the gap.
@MainActor public final class DeleteClips: EditCommand {
    public let name: String
    public let clipIDs: [Int64]
    public let ripple: Bool
    public init(clipIDs: [Int64], ripple: Bool = false) {
        self.clipIDs = clipIDs; self.ripple = ripple; name = ripple ? "Ripple Delete" : "Delete"
    }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Inserts an empty top-level track at `index` (plus its `trackAttributes` entry).
@MainActor public final class AddTrack: EditCommand {
    public let name = "Add Track"
    public let index: Int
    public init(at index: Int) { self.index = index }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Removes a top-level track and its clips.
@MainActor public final class RemoveTrack: EditCommand {
    public let name = "Remove Track"
    public let index: Int
    public init(at index: Int) { self.index = index }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Sets a top-level track flag (mute, hide, magnetic, solo, lock).
@MainActor public final class SetTrackFlag: EditCommand {
    public let name: String
    public let index: Int
    public let flag: TrackFlag
    public let value: Bool
    public init(track index: Int, _ flag: TrackFlag, _ value: Bool) {
        self.index = index; self.flag = flag; self.value = value; name = "Change Track"
    }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Sets a clip parameter: constant when `keyframeAt` is nil, else adds/updates a keyframe
/// at that clip media time (ticks, time-mapping.md §6).
@MainActor public final class SetParameter: EditCommand {
    public let name = "Change Property"
    public let clipID: Int64
    public let parameter: String
    public let value: Double
    public let keyframeAt: Int64?
    public init(clipID: Int64, parameter: String, value: Double, keyframeAt: Int64? = nil) {
        self.clipID = clipID; self.parameter = parameter; self.value = value; self.keyframeAt = keyframeAt
    }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}

/// Points a source at another file (cross-device relink); updates `src`, `lastMod`, `sourceTracks`.
@MainActor public final class RelinkSource: EditCommand {
    public let name = "Relink Media"
    public let sourceID: Int64
    public let descriptor: SourceDescriptor
    public init(sourceID: Int64, to descriptor: SourceDescriptor) {
        self.sourceID = sourceID; self.descriptor = descriptor
    }
    public func apply(to project: Project) throws { throw EditError.invalid("not implemented") }
    public func revert(on project: Project) throws { throw EditError.invalid("not implemented") }
}
