import Foundation
import TSCProjKit

/// Sets a flag on a track inside a `Group` (`groupID`, inner track `track`).
///
/// Group tracks carry `audioMuted`, `videoHidden`, `magnetic` and `solo`
/// inline on the track object [obs, demo]. They have no lock state in any
/// observed file; `locked` is written as `metadata.IsLocked` ("True"/"False")
/// on the track, mirroring `trackAttributes` [inf]. Turning `magnetic` on
/// packs the track in the same command.
@MainActor
public final class SetGroupTrackFlag: EditCommand {
    public var name: String { "Change Track" }
    public let groupID: Int64
    public let track: Int
    public let flag: TrackFlag
    public let value: Bool
    private var swap = TrackSwap()

    public init(group groupID: Int64, track: Int, _ flag: TrackFlag, _ value: Bool) {
        self.groupID = groupID; self.track = track; self.flag = flag; self.value = value
    }

    public func apply(to project: Project) throws {
        let loc = try Locator.locate(groupID, in: project)
        guard loc.clip.clipType == "Group" else { throw EditError.invalid("clip \(groupID) is not a group") }
        let path = loc.clipPath.appending(.key("tracks"), .index(track))
        guard path.resolve(in: project.root)?.object != nil else { throw EditError.trackNotFound(track) }
        var edits = TrackEdits(project)
        let t = try edits.track(at: path)
        switch flag {
        case .locked:
            if t["metadata"]?.object == nil { t["metadata"] = J.emptyObject }
            t["metadata"]?.object?["IsLocked"] = .string(value ? "True" : "False")
        default:
            t[flag.rawValue] = .bool(value)
        }
        if flag == .magnetic, value { Magnetic.pack(t) }
        try edits.commit(&swap)
    }

    public func revert(on project: Project) throws { try swap.restore(in: project) }
}
