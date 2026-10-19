import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Pure geometry of a capture: what part of the screen, at what pixel size.
struct CapturePlan: Equatable {
    /// Captured area in global points, top-left origin.
    var globalRect: CGRect
    /// `SCStreamConfiguration.sourceRect` (display-local points) for a region, else nil.
    var displayLocalRect: CGRect?
    var pixelWidth: Int
    var pixelHeight: Int

    var geometry: CaptureGeometry { CaptureGeometry(sourceRect: globalRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }

    /// Even pixel count (4:2:0 video needs even sizes), at least 2.
    static func even(_ v: Double) -> Int { max(2, Int(v.rounded()) & ~1) }

    /// Whole display `frame` (global points) at `scale` pixels per point.
    static func display(frame: CGRect, scale: Double) -> CapturePlan {
        CapturePlan(globalRect: frame, displayLocalRect: nil,
                    pixelWidth: even(Double(frame.width) * scale), pixelHeight: even(Double(frame.height) * scale))
    }

    /// `region` (display-local points, top-left origin) of a display, clamped to it and snapped
    /// to whole pixels. Nil when the clamped region is empty.
    static func region(_ region: CGRect, displayFrame: CGRect, scale: Double) -> CapturePlan? {
        let local = CGRect(origin: .zero, size: displayFrame.size).intersection(region.standardized)
        guard !local.isNull, local.width >= 1, local.height >= 1 else { return nil }
        let s = max(scale, 1e-6)
        let w = even(Double(local.width) * s), hgt = even(Double(local.height) * s)
        let x = (Double(local.minX) * s).rounded() / s, y = (Double(local.minY) * s).rounded() / s
        let snapped = CGRect(x: x, y: y, width: Double(w) / s, height: Double(hgt) / s)
        return CapturePlan(globalRect: snapped.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY),
                           displayLocalRect: snapped, pixelWidth: w, pixelHeight: hgt)
    }

    /// A window with `frame` (global points) at `scale`.
    static func window(frame: CGRect, scale: Double) -> CapturePlan {
        CapturePlan(globalRect: frame, displayLocalRect: nil,
                    pixelWidth: even(Double(frame.width) * scale), pixelHeight: even(Double(frame.height) * scale))
    }
}

/// ScreenCaptureKit stream of one target. Delivers complete video frames and (optionally)
/// system-audio buffers with host-clock PTS on its own serial queues.
// @unchecked Sendable: `stream` and `failure` are set before start / read after stop or under
// `lock`; SCK calls the output methods on our serial queues only.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias Sink = @Sendable (CMSampleBuffer, CMTime) -> Void

    let plan: CapturePlan
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let onVideo: Sink
    private let onAudio: Sink?
    private let videoQueue = DispatchQueue(label: "WizRec.Recorder.screen", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "WizRec.Recorder.systemAudio", qos: .userInteractive)
    private var stream: SCStream?
    private let lock = NSLock()
    private var failure: Error?

    /// Resolves `options.target` against the shareable content (needs Screen Recording permission).
    static func make(options: RecordingOptions, onVideo: @escaping Sink, onAudio: Sink?) async throws -> ScreenCapture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied("Screen Recording")
        }
        let excluded = RecorderExclusions.windowIDs
        let excludedWindows = content.windows.filter { excluded.contains($0.windowID) }
        let filter: SCContentFilter
        let plan: CapturePlan
        switch options.target {
        case let .display(id), let .region(id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError.deviceUnavailable("display \(id)")
            }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let scale = Double(filter.pointPixelScale)
            if case let .region(_, rect) = options.target {
                guard let p = CapturePlan.region(rect, displayFrame: display.frame, scale: scale) else {
                    throw RecorderError.deviceUnavailable("empty region")
                }
                plan = p
            } else {
                plan = CapturePlan.display(frame: display.frame, scale: scale)
            }
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.deviceUnavailable("window \(id)")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            plan = CapturePlan.window(frame: window.frame, scale: Double(filter.pointPixelScale))
        }
        let c = SCStreamConfiguration()
        c.width = plan.pixelWidth
        c.height = plan.pixelHeight
        if let r = plan.displayLocalRect { c.sourceRect = r }
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.frameRate)))
        c.showsCursor = options.cursorInVideo
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.colorSpaceName = CGColorSpace.sRGB
        c.queueDepth = 6
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.capturesAudio = options.captureSystemAudio
        c.sampleRate = 48_000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        c.streamName = "WizRec"
        // Window capture: frame = window bounds without its shadow, so cursor coordinates match.
        c.ignoreShadowsSingleWindow = true
        return ScreenCapture(plan: plan, filter: filter, configuration: c, onVideo: onVideo,
                             onAudio: options.captureSystemAudio ? onAudio : nil)
    }

    private init(plan: CapturePlan, filter: SCContentFilter, configuration: SCStreamConfiguration,
                 onVideo: @escaping Sink, onAudio: Sink?) {
        self.plan = plan; self.filter = filter; self.configuration = configuration
        self.onVideo = onVideo; self.onAudio = onAudio
    }

    func start() async throws {
        let s = SCStream(filter: filter, configuration: configuration, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if onAudio != nil { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        stream = s
        do {
            try await s.startCapture()
        } catch {
            stream = nil
            throw RecorderError.permissionDenied("Screen Recording (\(error.localizedDescription))")
        }
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        // Drain callbacks already queued.
        videoQueue.sync {}
        audioQueue.sync {}
    }

    /// The stream error, if SCK stopped the stream on its own (display unplugged, window closed…).
    var streamFailure: Error? { lock.withLock { failure } }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) // host clock (mach time)
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            onVideo(sampleBuffer, pts)
        case .audio:
            onAudio?(sampleBuffer, pts)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = error }
    }

    /// SCK sends idle/blank status buffers without pixels when nothing changed; skip them.
    static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete && CMSampleBufferGetImageBuffer(sample) != nil
    }
}
