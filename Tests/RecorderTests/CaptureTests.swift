import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Recorder

@Suite struct CapturePlanTests {
    let display = CGRect(x: 1512, y: -200, width: 1512, height: 982)

    @Test func wholeDisplayAtRetinaScale() {
        let p = CapturePlan.display(frame: display, scale: 2)
        #expect(p.pixelWidth == 3024 && p.pixelHeight == 1964)
        #expect(p.displayLocalRect == nil)
        #expect(p.geometry.pixelsPerPoint == 2)
    }

    @Test func regionIsClampedSnappedAndEven() throws {
        let p = try #require(CapturePlan.region(CGRect(x: -10, y: 100.3, width: 401, height: 2000), displayFrame: display, scale: 2))
        #expect(p.displayLocalRect == CGRect(x: 0, y: 100.5, width: 391, height: 881))
        #expect(p.pixelWidth == 782 && p.pixelHeight == 1762)
        #expect(p.globalRect.origin == CGPoint(x: 1512, y: -99.5))
        #expect(CapturePlan.region(CGRect(x: 5000, y: 0, width: 10, height: 10), displayFrame: display, scale: 2) == nil)
    }

    @Test func oddSizesRoundToEven() {
        #expect(CapturePlan.even(1001) == 1000)
        #expect(CapturePlan.even(1.2) == 2)
        #expect(CapturePlan.window(frame: CGRect(x: 0, y: 0, width: 333, height: 222), scale: 1).pixelWidth == 332)
    }

    @MainActor @Test func stopWhenIdleThrows() async {
        let s = RecordingSession(options: RecordingOptions(target: .display(CGMainDisplayID()), outputDirectory: tempDir()))
        await #expect(throws: RecorderError.self) { _ = try await s.stop() }
        #expect(s.state == .idle)
        #expect(s.elapsed == 0)
    }

    @MainActor @Test func displaysEnumerateWithoutPermission() {
        let d = CaptureSources.displays()
        #expect(d.isEmpty || d[0].isMain)
        #expect(d.allSatisfy { $0.pixelWidth > 0 && $0.frame.width > 0 })
    }
}

/// Real capture. Needs Screen Recording permission for the test runner (Terminal / Xcode):
/// `WIZREC_CAPTURE_TESTS=1 swift test --filter RealCaptureTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_CAPTURE_TESTS"] == "1"), .serialized)
@MainActor struct RealCaptureTests {
    @Test func recordsMainDisplayWithPauseAndCursorLog() async throws {
        let dir = tempDir()
        defer { if ProcessInfo.processInfo.environment["WIZREC_KEEP"] != "1" { try? FileManager.default.removeItem(at: dir) } }
        var o = RecordingOptions(target: .display(CGMainDisplayID()), outputDirectory: dir)
        o.captureSystemAudio = true
        let s = RecordingSession(options: o)
        var states: [RecorderState] = []
        s.onStateChange = { states.append($0) }
        try await s.start(countdown: 1)
        #expect(s.state == .recording)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        s.pause()
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(abs(s.elapsed - 1) < 0.15)
        s.resume()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let r = try await s.stop()
        #expect(abs(r.duration.seconds - 2) < 0.2)
        #expect(states.contains(.paused) && states.last == .idle)
        let back = try await readBack(r.screen, type: .video)
        #expect(abs(back.duration - r.duration.seconds) < 0.05)
        #expect(back.pts.first == 0)
        let log = try CursorLog.decode(Data(contentsOf: try #require(r.cursorLog)))
        #expect(log.events.first?.t == 0)
        #expect(!log.cursors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(log.cursors[0].file).path))
        print("capture: \(r) warnings: \(s.warnings) frames: \(back.pts.count)")
    }

    @Test func recordsARegion() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = RecordingOptions(target: .region(CGMainDisplayID(), CGRect(x: 0, y: 0, width: 640, height: 360)), outputDirectory: dir)
        o.codec = .hevc
        o.logCursor = false
        let s = RecordingSession(options: o)
        try await s.start(countdown: 0)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let r = try await s.stop()
        #expect(r.cursorLog == nil)
        let back = try await readBack(r.screen, type: .video)
        let backingScale: Double = CaptureSources.displays().first.map { (d) -> Double in
            Double(d.pixelWidth) / Double(d.frame.width)
        } ?? 1
        let expectedWidth: Double = 640 * backingScale
        #expect(Double(back.size.width) == expectedWidth)
    }

    @Test func enumeratesWindows() async throws {
        let w = try await CaptureSources.windows()
        print("windows: \(w.count), cameras: \(CaptureSources.cameras().map(\.name)), mics: \(CaptureSources.microphones().map(\.name))")
    }
}
