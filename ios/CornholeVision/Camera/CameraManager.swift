import AVFoundation
import UIKit

/// Owns the capture session. Frames are delivered in the sensor's native
/// (landscape) orientation; the preview layer is rotated for display via
/// AVCaptureDevice.RotationCoordinator so coordinate conversion between the
/// two goes through `layerPointConverted(fromCaptureDevicePoint:)`.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let frameQueue = DispatchQueue(label: "cornhole.camera.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// Called on the capture queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private(set) var isConfigured = false

    enum SetupError: Error { case denied, noCamera, cannotAddIO }

    func configure() async throws {
        if isConfigured { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var granted = status == .authorized
        if status == .notDetermined {
            granted = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard granted else { throw SetupError.denied }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw SetupError.noCamera
        }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else { session.commitConfiguration(); throw SetupError.cannotAddIO }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw SetupError.cannotAddIO }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            // Keep the data output in sensor-native orientation (no rotation).
            if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = false }
        }

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            // Prefer 30 fps for a steady tracker cadence.
            let thirty = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = thirty
                device.activeVideoMaxFrameDuration = thirty
            }
            device.unlockForConfiguration()
        } catch {
            // Non-fatal.
        }

        session.commitConfiguration()
        isConfigured = true
        await MainActor.run { self.attachRotationIfPossible() }
    }

    /// The SwiftUI preview calls this once its layer exists.
    func attachPreview(layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        attachRotationIfPossible()
    }

    private func attachRotationIfPossible() {
        guard let device, let layer = previewLayer, rotationCoordinator == nil else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak layer] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                if let conn = layer?.connection, conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
            }
        }
    }

    func start() {
        frameQueue.async { [self] in
            if isConfigured && !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        frameQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Once the board is locked we freeze focus, exposure and white balance: the background
    /// model compares colours against a reference, so the camera must stop re-deciding them.
    func lockFocus() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
        } catch {}
    }

    func unlockFocus() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
