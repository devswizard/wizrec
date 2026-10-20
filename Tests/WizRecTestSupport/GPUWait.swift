import Metal

/// Bounded replacement for `MTLCommandBuffer.commit()` + `waitUntilCompleted()` in tests (QA10-1).
public enum GPUWait {
    /// Default bound for one command buffer, in seconds (before `Deadline.scale`).
    public static let defaultSeconds = 60.0

    /// Commits `cb` and blocks at most `seconds` (scaled) until it completes. Throws
    /// `DeadlineExceeded` on timeout, or the command buffer's own error if it failed.
    public static func commitAndWait(_ cb: any MTLCommandBuffer, _ what: String = "GPU command buffer",
                                     seconds: Double = defaultSeconds) throws {
        try Deadline.blocking(what, seconds: seconds) { done in
            cb.addCompletedHandler { _ in done() }
            cb.commit()
        }
        if let error = cb.error { throw error }
    }
}
