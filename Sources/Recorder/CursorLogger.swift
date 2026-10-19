import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreMedia
import Foundation

/// Live cursor/click/keystroke logger of one recording.
///
/// - Position and cursor image: sampled on the main run loop at the capture frame rate
///   (`CGEvent(source:).location`, `NSCursor.currentSystem`); no permission needed.
/// - Buttons and scroll: a listen-only `CGEvent` tap; no permission needed for mouse events.
/// - Keystrokes: a second listen-only tap, installed only when `logKeystrokes` is true. It needs
///   Input Monitoring (or Accessibility) permission. Nothing is logged while secure event input
///   is on (password fields, `sudo` in Terminal…).
///
/// Every event is stamped with the host clock when it is seen and mapped through the shared
/// `RecordingClock`, so the log lines up with the video at t=0.
@MainActor
final class CursorLogger {
    private let clock: RecordingClock
    private let sampleRate: Int
    private let logKeystrokes: Bool
    private let directory: URL
    private let windowID: CGWindowID?
    private var builder: CursorLogBuilder
    private var registry: CursorImageRegistry
    private var timer: Timer?
    private var taps: [(CFMachPort, CFRunLoopSource)] = []
    private var tick = 0
    private var box: Unmanaged<CursorLogger>?
    /// Mouse events of interest were seen through the tap (false: the tap could not be created).
    private(set) var mouseTapInstalled = false
    private(set) var keyTapInstalled = false

    init(clock: RecordingClock, geometry: CaptureGeometry, windowID: CGWindowID?, sampleRate: Int,
         logKeystrokes: Bool, directory: URL) {
        self.clock = clock
        self.sampleRate = max(1, sampleRate)
        self.logKeystrokes = logKeystrokes
        self.directory = directory
        self.windowID = windowID
        self.builder = CursorLogBuilder(geometry: geometry)
        self.registry = CursorImageRegistry(directory: directory)
    }

    /// Starts sampling and the event taps. Events before the clock starts are dropped.
    func startMonitoring() throws {
        guard timer == nil else { return }
        if logKeystrokes, !Self.keystrokeAccessGranted(prompt: false) {
            throw RecorderError.permissionDenied("Input Monitoring (keystroke logging)")
        }
        box = Unmanaged.passRetained(self)
        let mouseMask: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                        .otherMouseDown, .otherMouseUp, .scrollWheel]
        mouseTapInstalled = installTap(mouseMask)
        if logKeystrokes { keyTapInstalled = installTap([.keyDown]) }
        sample()
        let t = Timer(timeInterval: 1.0 / Double(sampleRate), repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call right after the clock starts or resumes.
    func segmentStarted() {
        sample()
        builder.segmentStarted(timeline: clock.stitcher)
    }

    /// Stops monitoring and returns the finished log (images are already on disk).
    func finish(duration: CMTime) -> CursorLog {
        stopMonitoring()
        let g = builder.geometry
        return CursorLog(
            videoWidth: g.pixelWidth, videoHeight: g.pixelHeight, pixelsPerPoint: roundTime(g.pixelsPerPoint),
            sampleRate: sampleRate, duration: roundTime(duration.seconds), keystrokesLogged: keyTapInstalled,
            cursors: registry.images, events: builder.sortedEvents
        )
    }

    func stopMonitoring() {
        timer?.invalidate(); timer = nil
        for (port, source) in taps {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(port)
        }
        taps.removeAll()
        box?.release(); box = nil
    }

    /// Whether this process may observe keystrokes (Input Monitoring, or Accessibility trust).
    /// With `prompt`, asks the system to show its permission prompt.
    nonisolated static func keystrokeAccessGranted(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() || AXIsProcessTrusted() { return true }
        if prompt { _ = CGRequestListenEventAccess() }
        return false
    }

    // MARK: - Sampling

    private func sample() {
        let now = hostNow()
        tick += 1
        if let windowID, tick % 5 == 1, let frame = Self.windowFrame(windowID) {
            builder.geometry.sourceRect.origin = frame.origin
        }
        let timeline = clock.stitcher
        if let location = CGEvent(source: nil)?.location {
            builder.move(to: location, hostTime: now, timeline: timeline)
        }
        if let bitmap = CursorBitmap.currentSystemCursor(scale: builder.geometry.pixelsPerPoint) {
            let id = registry.id(for: bitmap)
            builder.cursor(id, hostTime: now, timeline: timeline)
        }
    }

    /// Current bounds of a window in global points, top-left origin.
    nonisolated static func windowFrame(_ id: CGWindowID) -> CGRect? {
        // The array holds raw CGWindowID values (not CFNumbers), so build it without callbacks.
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &value, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return rect
    }

    // MARK: - Event taps

    private func installTap(_ types: [CGEventType]) -> Bool {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let box, let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: cursorLoggerTapCallback, userInfo: box.toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        taps.append((port, source))
        return true
    }

    /// What the tap callback extracted from a `CGEvent` (which is not Sendable).
    fileprivate enum TapInput: Sendable {
        case reenable
        case down(MouseButton, CGPoint, Int)
        case up(MouseButton, CGPoint)
        case scroll(dx: Double, dy: Double, CGPoint)
        case key(CursorEvent.Kind)
    }

    /// Runs in the tap callback. Keyboard events yield nothing while secure input is on.
    nonisolated fileprivate static func decode(_ type: CGEventType, _ event: CGEvent) -> TapInput? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .reenable
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = MouseButton(cgButton: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
            return .down(button, event.location, max(1, Int(event.getIntegerValueField(.mouseEventClickState))))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return .up(MouseButton(cgButton: Int(event.getIntegerValueField(.mouseEventButtonNumber))), event.location)
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            return dx != 0 || dy != 0 ? .scroll(dx: round2(dx), dy: round2(dy), event.location) : nil
        case .keyDown:
            return IsSecureEventInputEnabled() ? nil : .key(keyKind(event))
        default:
            return nil
        }
    }

    fileprivate func handle(_ input: TapInput) {
        let now = hostNow()
        let timeline = clock.stitcher
        switch input {
        case .reenable:
            for (port, _) in taps { CGEvent.tapEnable(tap: port, enable: true) }
        case let .down(button, p, clicks):
            builder.event(at: p, hostTime: now, timeline: timeline) { .down(button: button, x: $0.x, y: $0.y, clickCount: clicks) }
        case let .up(button, p):
            builder.event(at: p, hostTime: now, timeline: timeline) { .up(button: button, x: $0.x, y: $0.y) }
        case let .scroll(dx, dy, p):
            builder.event(at: p, hostTime: now, timeline: timeline) { .scroll(dx: dx, dy: dy, x: $0.x, y: $0.y) }
        case let .key(kind):
            guard logKeystrokes, keyTapInstalled else { return }
            builder.key(kind, hostTime: now, timeline: timeline)
        }
    }

    nonisolated static func keyKind(_ event: CGEvent) -> CursorEvent.Kind {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let chars = NSEvent(cgEvent: event)?.characters
        return .key(keyCode: code, characters: chars?.isEmpty == false ? chars : nil,
                    modifiers: modifierNames(event.flags), isRepeat: isRepeat)
    }

    nonisolated static func modifierNames(_ f: CGEventFlags) -> [String] {
        var out: [String] = []
        if f.contains(.maskShift) { out.append("shift") }
        if f.contains(.maskControl) { out.append("control") }
        if f.contains(.maskAlternate) { out.append("option") }
        if f.contains(.maskCommand) { out.append("command") }
        if f.contains(.maskSecondaryFn) { out.append("function") }
        if f.contains(.maskAlphaShift) { out.append("capsLock") }
        return out
    }
}

/// C callback of the listen-only taps; runs on the main run loop.
private func cursorLoggerTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let logger = Unmanaged<CursorLogger>.fromOpaque(userInfo).takeUnretainedValue()
        if let input = CursorLogger.decode(type, event) {
            MainActor.assumeIsolated { logger.handle(input) }
        }
    }
    return Unmanaged.passUnretained(event)
}
