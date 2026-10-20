import Foundation

/// What a finished subprocess left: exit status and captured output (bytes; empty when not captured).
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    /// Standard output as UTF-8 text.
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// Standard error as UTF-8 text.
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a helper tool (ffmpeg, say, bash…) for a test with a wall-time bound (board QA10-1).
///
/// Replaces `Process.run()` + `waitUntilExit()`, which waits forever when the tool hangs. Output
/// pipes are drained on background threads (a full pipe cannot block the tool), stdin is
/// `/dev/null` (ffmpeg without `-nostdin` otherwise waits on a terminal), and on timeout the tool
/// gets SIGTERM, then SIGKILL, and `DeadlineExceeded` is thrown.
public enum TestProcess {
    /// Where one output stream goes.
    public enum Stream: Sendable {
        case discard, capture, inherit
        /// Standard error only: into the standard output capture (interleaved).
        case stdout
    }

    /// Runs `executable` with `arguments` and waits at most `seconds` (scaled by
    /// `Deadline.scale`) for it to exit. `environment` nil inherits the test's environment.
    /// Throws when it cannot launch or does not exit in time; a non-zero status is returned, not thrown.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           stdout: Stream = .capture, stderr: Stream = .capture,
                           seconds: Double = Deadline.defaultSeconds) throws -> ProcessOutput {
        let bound = seconds * Deadline.scale
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        let drained = DispatchGroup()
        let outBox = DataBox(), errBox = DataBox()
        let outPipe = attach(stdout, box: outBox, group: drained) { p.standardOutput = $0 }
        switch stderr {
        case .stdout:
            if let outPipe { p.standardError = outPipe } else { p.standardError = p.standardOutput }
        default:
            _ = attach(stderr, box: errBox, group: drained) { p.standardError = $0 }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        // Deadline.wait keeps the main run loop turning when a @MainActor test calls this.
        if !Deadline.wait(exited, seconds: bound) {
            p.terminate()
            if !Deadline.wait(exited, seconds: 2) {
                kill(p.processIdentifier, SIGKILL)
                _ = Deadline.wait(exited, seconds: 2)
            }
            let name = (executable as NSString).lastPathComponent
            throw DeadlineExceeded(what: "`\(name) \(arguments.prefix(4).joined(separator: " "))…` to exit",
                                   seconds: bound)
        }
        // The pipes close when the tool exits, unless a grandchild still holds them.
        let drainDone = DispatchSemaphore(value: 0)
        drained.notify(queue: .global()) { drainDone.signal() }
        _ = Deadline.wait(drainDone, seconds: 5)
        return ProcessOutput(status: p.terminationStatus, stdout: outBox.data, stderr: errBox.data)
    }

    /// Sets up one stream; for `.capture` returns the pipe after starting its reader.
    private static func attach(_ stream: Stream, box: DataBox, group: DispatchGroup,
                               set: (Any) -> Void) -> Pipe? {
        switch stream {
        case .discard, .stdout:
            set(FileHandle.nullDevice)
            return nil
        case .inherit:
            return nil
        case .capture:
            let pipe = Pipe()
            set(pipe)
            let reader = pipe.fileHandleForReading
            group.enter()
            DispatchQueue.global().async {
                box.data = reader.readDataToEndOfFile()
                group.leave()
            }
            return pipe
        }
    }
}

/// Output bytes filled by a reader thread.
final class DataBox: @unchecked Sendable {
    // @unchecked: `storage` is only touched under `lock`.
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
