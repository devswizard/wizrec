import AVFoundation
import CoreMedia
import Foundation

/// Camera and/or microphone capture through one `AVCaptureSession`. Sample times are converted
/// from the session's synchronization clock to the host clock, the clock of the screen stream.
// @unchecked Sendable: the session is configured in `init` and only started/stopped afterwards
// (AVCaptureSession is thread-safe for that); callbacks arrive on our serial queues.
final class DeviceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias Sink = @Sendable (CMSampleBuffer, CMTime) -> Void

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoQueue = DispatchQueue(label: "WizRec.Recorder.camera", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "WizRec.Recorder.microphone", qos: .userInteractive)
    private let onCamera: Sink?
    private let onMicrophone: Sink?

    init(cameraID: String?, microphoneID: String?, onCamera: Sink?, onMicrophone: Sink?) throws {
        self.onCamera = cameraID == nil ? nil : onCamera
        self.onMicrophone = microphoneID == nil ? nil : onMicrophone
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let id = cameraID {
            guard RecorderPermissions.camera == .authorized else { throw RecorderError.permissionDenied("Camera") }
            guard let device = AVCaptureDevice(uniqueID: id) else { throw RecorderError.deviceUnavailable("camera \(id)") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.deviceUnavailable("camera \(id)") }
            session.addInput(input)
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { throw RecorderError.deviceUnavailable("camera output") }
            session.addOutput(videoOutput)
        }
        if let id = microphoneID {
            guard RecorderPermissions.microphone == .authorized else { throw RecorderError.permissionDenied("Microphone") }
            guard let device = AVCaptureDevice(uniqueID: id) else { throw RecorderError.deviceUnavailable("microphone \(id)") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.deviceUnavailable("microphone \(id)") }
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(audioOutput) else { throw RecorderError.deviceUnavailable("microphone output") }
            session.addOutput(audioOutput)
        }
    }

    var isEmpty: Bool { onCamera == nil && onMicrophone == nil }

    /// Starts the devices (blocking, ~100–500 ms); call off the main thread.
    func start() { if !isEmpty { session.startRunning() } }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        videoQueue.sync {}
        audioQueue.sync {}
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        if output === videoOutput { onCamera?(sampleBuffer, host) } else { onMicrophone?(sampleBuffer, host) }
    }
}
