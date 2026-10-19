/// Whether a document differs from its last save, derived from undo history.
///
/// `position` counts history steps from the open/save baseline: perform and redo add
/// one, undo subtracts one. The document is clean when `position` is the saved
/// position. Performing a new command while the saved state sits in the redo list
/// makes that state unreachable, so the document stays dirty until the next save.
public struct ChangeTracker: Sendable, Equatable {
    /// History steps from the baseline (may go negative after undoing past it).
    public private(set) var position = 0
    /// Position of the saved state, or nil when no reachable history state equals it.
    public private(set) var savedPosition: Int? = 0

    public init() {}

    public var isDirty: Bool { savedPosition != position }

    public mutating func performed(count: Int = 1) {
        guard count > 0 else { return }
        if let s = savedPosition, s > position { savedPosition = nil }
        position += count
    }

    public mutating func undid() { position -= 1 }
    public mutating func redid() { position += 1 }

    /// The current state was written to disk.
    public mutating func saved() { savedPosition = position }

    /// Forces dirty (e.g. a change that bypasses the undo stack).
    public mutating func markUnsaveable() { savedPosition = nil }
}
