// M2 additions to ProjectBundle (writing side), frozen by coordination/CONTRACTS.md.
// Stub bodies throw until agent "timeline" implements them.

import Foundation

public enum BundleWriteError: Error, Equatable {
    case notImplemented
    case exists(URL)
    case copyFailed(String)
}

extension ProjectBundle {
    /// Creates a new empty `.cmproj` at `url`: format `10.0`, editRate 705600000,
    /// canvas `width`×`height` px at `fps`, one empty track. Fails if `url` exists.
    public static func create(at url: URL, width: Int = 1920, height: Int = 1080,
                              fps: Int = 30) throws -> ProjectBundle {
        throw BundleWriteError.notImplemented
    }

    /// Copies `file` into `media/<unix-ts>/` inside the bundle and returns its
    /// project-relative `src` (e.g. `"./media/1792376869.292854/clip.mp4"`).
    /// Bare `.tscproj` projects return a path relative to the project's folder without copying.
    public func importFile(_ file: URL) throws -> String {
        throw BundleWriteError.notImplemented
    }

    /// Saves atomically and keeps the previous `project.tscproj` as
    /// `project.tscproj.wizrec-backup` (overwritten on each save).
    public func saveWithBackup() throws {
        throw BundleWriteError.notImplemented
    }
}
