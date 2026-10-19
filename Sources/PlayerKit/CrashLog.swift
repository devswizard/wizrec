import Darwin
import Foundation

/// Opt-in, local-only crash reports: when enabled, fatal signals and uncaught Objective-C
/// exceptions write a plain-text report (app version, macOS version, signal or exception,
/// backtrace) to `~/Library/Logs/WizRec/crash-*.log`. Nothing is ever sent anywhere; the
/// user opens the folder from Settings. Reports never include project content or paths.
public enum CrashLog {
    /// Fatal signals that produce a report.
    public static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]
    /// Reports kept; older ones are deleted at install.
    public static let keep = 20

    /// `~/Library/Logs/WizRec`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/WizRec", isDirectory: true)
    }

    /// File name of this process's report: `crash-<yyyyMMdd-HHmmss>-<pid>.log` (launch time, UTC).
    public static func fileName(launch: Date, pid: Int32) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "crash-\(f.string(from: launch))-\(pid).log"
    }

    /// Report header: app, OS and launch time, one `key: value` per line.
    public static func header(appVersion: String, osVersion: String, launch: Date) -> String {
        let iso = ISO8601DateFormatter().string(from: launch)
        return "WizRec crash report (local only; never sent)\napp: \(appVersion)\nmacOS: \(osVersion)\nlaunched: \(iso)\n"
    }

    /// Text for an uncaught exception.
    public static func exceptionReport(header: String, name: String, reason: String?, stack: [String]) -> String {
        header + "exception: \(name)\nreason: \(reason ?? "-")\n\nbacktrace:\n" + stack.joined(separator: "\n") + "\n"
    }

    /// Reports in `directory`, newest first.
    public static func reports(in directory: URL = defaultDirectory) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes all but the newest `keep` reports.
    public static func prune(in directory: URL = defaultDirectory, keep: Int = keep) {
        for u in reports(in: directory).dropFirst(max(0, keep)) { try? FileManager.default.removeItem(at: u) }
    }

    /// Deletes every report.
    public static func deleteAll(in directory: URL = defaultDirectory) { prune(in: directory, keep: 0) }

    /// Turns reporting on (installs the handlers once) or off (handlers stay but write nothing).
    public static func setEnabled(_ on: Bool, directory: URL = defaultDirectory,
                                  appVersion: String = Self.bundleVersion,
                                  osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        if on {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            prune(in: directory)
            let launch = Date()
            let path = directory.appendingPathComponent(fileName(launch: launch, pid: getpid())).path
            State.prepare(path: path, header: header(appVersion: appVersion, osVersion: osVersion, launch: launch))
            installHandlers()
        }
        State.enabled = on
    }

    public static var isEnabled: Bool { State.enabled }

    /// `CFBundleShortVersionString (CFBundleVersion)`, or "dev" outside an app bundle.
    public static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "dev" }
        return "\(v) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Writes the signal report for `sig` to this process's report file (what the signal
    /// handler does, minus re-raising). Async-signal-safe: only `open`/`write`/`close` and
    /// `backtrace_symbols_fd` on buffers prepared at `setEnabled(true)`. Returns false when off.
    @discardableResult
    public static func writeSignalReport(_ sig: Int32) -> Bool {
        guard State.enabled, let path = State.path, let header = State.header else { return false }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        _ = header.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
        writeSignalLine(fd, sig)
        let stack = State.stack
        let n = backtrace(stack, Int32(State.stackCapacity))
        backtrace_symbols_fd(stack, n, fd)
        close(fd)
        return true
    }

    /// `signal: <n>\n\nbacktrace:\n` without allocating.
    private static func writeSignalLine(_ fd: Int32, _ sig: Int32) {
        var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &buf) { b in
            var i = 0
            func put(_ c: UInt8) { if i < b.count { b[i] = c; i += 1 } }
            for c in "signal: ".utf8 { put(c) }
            var v = Int(sig), digits = 0, tmp = v
            repeat { digits += 1; tmp /= 10 } while tmp > 0
            var j = digits
            while j > 0 { j -= 1; let p = i + j; if p < b.count { b[p] = UInt8(48 + v % 10) }; v /= 10 }
            i += digits
            for c in "\n\nbacktrace:\n".utf8 { put(c) }
            _ = write(fd, b.baseAddress, min(i, b.count))
        }
    }

    private static func installHandlers() {
        guard !State.installed else { return }
        State.installed = true
        for s in signals { signal(s, crashSignalHandler) }
        NSSetUncaughtExceptionHandler { e in
            guard CrashLog.isEnabled, let path = State.path, let header = State.headerString else { return }
            let text = CrashLog.exceptionReport(header: header, name: e.name.rawValue, reason: e.reason,
                                                stack: e.callStackSymbols)
            try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Process-wide handler state, written once before handlers can run.
    fileprivate enum State {
        // nonisolated(unsafe): read from signal handlers, which cannot take locks. Each value
        // is written on the main thread in `setEnabled` before any handler that reads it is
        // installed or enabled, and is never freed while the process runs.
        nonisolated(unsafe) static var enabled = false
        nonisolated(unsafe) static var installed = false
        nonisolated(unsafe) static var path: String?
        nonisolated(unsafe) static var header: [CChar]?
        nonisolated(unsafe) static var headerString: String?
        static let stackCapacity = 128
        nonisolated(unsafe) static let stack = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

        static func prepare(path p: String, header h: String) {
            path = p
            header = h.utf8CString.map { $0 }
            headerString = h
        }
    }
}

/// Signal handler: write the report once, restore the default action and re-raise so the
/// system's own crash handling still runs.
private func crashSignalHandler(_ sig: Int32) {
    CrashLog.writeSignalReport(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
