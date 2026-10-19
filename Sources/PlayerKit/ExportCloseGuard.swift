import Foundation

/// Decides whether closing a document window, or quitting, must ask before cancelling running
/// exports. The confirmation is remembered so a quit that already asked does not ask again
/// for each window it closes.
@MainActor
public final class ExportCloseGuard {
    /// What the caller should do.
    public enum Decision: Equatable, Sendable {
        /// Close now: nothing is exporting, the user already agreed, or a scripted run owns the export.
        case proceed
        /// Ask first; `jobs` exports (waiting or running) would be cancelled.
        case ask(jobs: Int)
    }

    /// The user agreed to cancel this document's exports.
    public private(set) var isConfirmed = false
    /// An alert is on screen; further close requests wait for its answer.
    public private(set) var isAsking = false

    public init() {}

    /// `activeJobs`: `ExportQueue.activeJobCount`. `scripted`: the export came from `--export`,
    /// which manages its own lifetime.
    public func decide(activeJobs: Int, scripted: Bool = false) -> Decision {
        if activeJobs == 0 || isConfirmed || scripted { return .proceed }
        return .ask(jobs: activeJobs)
    }

    /// An alert was shown.
    public func beginAsking() { isAsking = true }

    /// The user answered: `cancelExports` true = cancel and close, false = keep exporting.
    public func answer(cancelExports: Bool) {
        isAsking = false
        isConfirmed = cancelExports
    }
}
