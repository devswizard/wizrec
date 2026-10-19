import AppKit
import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut of the recorder HUD (works while other apps are frontmost).
public struct HUDHotKey: Sendable, Equatable {
    /// macOS virtual key code (`kVK_*`).
    public var keyCode: UInt32
    /// Any of command, shift, option, control.
    public var modifiers: NSEvent.ModifierFlags
    /// Key label for menus/tooltips, e.g. "2" or "P".
    public var label: String

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }

    /// ⌘⇧2: start / stop.
    public static let startStop = HUDHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: [.command, .shift], label: "2")
    /// ⌘⇧P: pause / resume.
    public static let pauseResume = HUDHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .shift], label: "P")

    /// "⌃⌥⇧⌘2" style text.
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + label
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}

/// System-wide hot keys through Carbon `RegisterEventHotKey` (no Accessibility permission needed).
@MainActor
final class GlobalHotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    fileprivate var actions: [UInt32: @MainActor () -> Void] = [:]
    private var box: Unmanaged<GlobalHotKeys>?
    nonisolated static let signature: OSType = 0x575A_5263 // 'WZRc'

    /// Registers `key`; returns false when another app already owns the combination.
    @discardableResult
    func register(_ key: HUDHotKey, action: @escaping @MainActor () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        box?.release(); box = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        let b = Unmanaged.passRetained(self)
        box = b
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, b.toOpaque(), &handler)
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }
}

private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr, hk.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
    let keys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
    let id = hk.id
    MainActor.assumeIsolated { keys.fire(id) }
    return noErr
}

/// Small pure helpers of the HUD.
public enum HUDFormat {
    /// "0:07", "12:34", "1:02:03" for a duration in seconds.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s / 60) % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Display-local rectangle (points, top-left origin) spanned by two drag points given in a
    /// view covering the display (points, bottom-left origin) of height `displayHeight`.
    public static func regionRect(from a: CGPoint, to b: CGPoint, displayHeight: CGFloat) -> CGRect {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let maxY = max(a.y, b.y), minY = min(a.y, b.y)
        return CGRect(x: minX.rounded(), y: (displayHeight - maxY).rounded(),
                      width: (maxX - minX).rounded(), height: (maxY - minY).rounded())
    }

    /// Default output folder name for a recording started at `date`: "Recording 2026-10-19 17-11-20".
    public static func folderName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "Recording " + f.string(from: date)
    }
}
