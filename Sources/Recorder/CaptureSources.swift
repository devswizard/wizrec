import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// A display that can be recorded.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public var id: CGDirectDisplayID
    /// Localised name ("Built-in Retina Display"), or "Display <id>".
    public var name: String
    /// Bounds in global display points, top-left origin (`CGDisplayBounds`).
    public var frame: CGRect
    /// Native pixel size of the current mode.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isMain: Bool
}

/// An on-screen window that can be recorded.
public struct WindowInfo: Sendable, Equatable, Identifiable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    public var bundleID: String
    /// Frame in global display points, top-left origin.
    public var frame: CGRect
}

/// A camera or microphone (`AVCaptureDevice`).
public struct CaptureDeviceInfo: Sendable, Equatable, Identifiable {
    /// `AVCaptureDevice.uniqueID`, the value for `RecordingOptions.cameraID` / `microphoneID`.
    public var id: String
    public var name: String
    /// The system default device of its kind.
    public var isDefault: Bool
}

/// Enumerates what can be recorded. Display and device lists need no permission; window titles
/// need Screen Recording permission.
public enum CaptureSources {
    /// Active displays, main display first.
    @MainActor public static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(
                id: id, name: names[id] ?? "Display \(id)", frame: CGDisplayBounds(id),
                pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)),
                pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)), isMain: id == main
            )
        }.sorted { $0.isMain && !$1.isMain }
    }

    /// Normal-level on-screen windows of other apps, front to back. Throws when Screen Recording
    /// permission is missing.
    public static func windows() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { w in
            guard w.windowLayer == 0, w.frame.width >= 40, w.frame.height >= 40,
                  let app = w.owningApplication, app.processID != me else { return nil }
            return WindowInfo(id: w.windowID, title: w.title ?? "", appName: app.applicationName,
                              bundleID: app.bundleIdentifier, frame: w.frame)
        }
    }

    public static func cameras() -> [CaptureDeviceInfo] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        let def = AVCaptureDevice.default(for: .video)?.uniqueID
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == def) }
    }

    public static func microphones() -> [CaptureDeviceInfo] {
        let def = AVCaptureDevice.default(for: .audio)?.uniqueID
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == def) }
    }
}

/// Permission checks and prompts. Grants are per binary (the app bundle, or Terminal/Xcode when
/// run from there).
public enum RecorderPermissions {
    /// Screen Recording ("Screen & System Audio Recording"), needed for any capture.
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt once; the user must then enable the app in System Settings and
    /// relaunch it. Returns the current state.
    @discardableResult public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    public static var camera: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    public static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    public static func requestCamera() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
    public static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    /// Input Monitoring (or Accessibility), needed only for keystroke logging.
    public static var keystrokeMonitoring: Bool { CursorLogger.keystrokeAccessGranted(prompt: false) }
    @discardableResult public static func requestKeystrokeMonitoring() -> Bool { CursorLogger.keystrokeAccessGranted(prompt: true) }
}

/// Window numbers that every recording leaves out of the captured pixels (the HUD and its
/// overlays register here).
public enum RecorderExclusions {
    private static let ids = OSAllocatedUnfairLock(initialState: Set<CGWindowID>())
    public static func exclude(windowNumber: Int) { ids.withLock { _ = $0.insert(CGWindowID(clamping: windowNumber)) } }
    public static func include(windowNumber: Int) { ids.withLock { _ = $0.remove(CGWindowID(clamping: windowNumber)) } }
    static var windowIDs: Set<CGWindowID> { ids.withLock { $0 } }
}
