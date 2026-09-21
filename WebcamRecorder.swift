import Foundation
import AVFoundation
import SwiftUI
import AppKit

/// Everything that touches the AVCaptureSession, on one serial queue.
///
/// This exists because `AVCaptureSession` is not safe to reconfigure while it is starting:
/// changing inputs on the main thread while `startRunning()` enumerates them on another
/// crashes inside AVFoundation. Funnelling every call through `queue` removes that class
/// of bug entirely.
final class CameraEngine: NSObject, @unchecked Sendable {

    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "local.videoeditor.camera")
    private var attachedCameraID: String?
    private var micAttached = false
    private var finishContinuation: CheckedContinuation<Bool, Never>?

    var isRunning: Bool { session.isRunning }

    /// Rebuilds the inputs if the camera or microphone choice changed.
    func configure(camera: AVCaptureDevice, includeMicrophone: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if attachedCameraID == camera.uniqueID, micAttached == includeMicrophone, !session.inputs.isEmpty {
                    continuation.resume()
                    return
                }
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                do {
                    let videoInput = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(videoInput) else { throw RecordingError.noCamera }
                    session.addInput(videoInput)

                    micAttached = false
                    if includeMicrophone, let mic = AVCaptureDevice.default(for: .audio) {
                        let audioInput = try AVCaptureDeviceInput(device: mic)
                        if session.canAddInput(audioInput) {
                            session.addInput(audioInput)
                            micAttached = true
                        }
                    }
                    if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                        session.addOutput(movieOutput)
                    }
                    session.sessionPreset = .high
                    session.commitConfiguration()
                    attachedCameraID = camera.uniqueID
                    continuation.resume()
                } catch {
                    session.commitConfiguration()
                    attachedCameraID = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRunning() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stopRunning() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    func startRecording(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard session.isRunning else {
                    continuation.resume(throwing: SimpleError("The camera session would not start."))
                    return
                }
                guard movieOutput.connection(with: .video) != nil else {
                    continuation.resume(throwing: SimpleError("The camera produced no video connection to record."))
                    return
                }
                movieOutput.startRecording(to: url, recordingDelegate: self)
                continuation.resume()
            }
        }
    }

    /// Returns true once the file is closed and was written successfully.
    func stopRecording() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard movieOutput.isRecording else {
                    continuation.resume(returning: false)
                    return
                }
                finishContinuation = continuation
                movieOutput.stopRecording()
            }
        }
    }

    /// Set by the delegate when a recording ends badly.
    private(set) var lastError: String?
    private(set) var started = false
}

extension CameraEngine: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async { [self] in started = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let succeeded = error == nil
            || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let detail = (error as NSError?).map { "\($0.localizedDescription) [\($0.domain) \($0.code)] \($0.userInfo)" }
        queue.async { [self] in
            lastError = succeeded ? nil : detail
            finishContinuation?.resume(returning: succeeded)
            finishContinuation = nil
        }
    }
}

/// The UI-facing wrapper: device list, permissions, preview state.
@MainActor
final class WebcamRecorder: ObservableObject {

    enum PreviewState: Equatable {
        case off
        case noPermission
        case noCamera
        case live(String)
        case failed(String)
    }

    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String?
    @Published var includeMicrophone = true
    @Published private(set) var previewState: PreviewState = .off
    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?

    private let engine = CameraEngine()
    private var previewRequested = false

    var session: AVCaptureSession { engine.session }

    var selectedCamera: AVCaptureDevice? {
        cameras.first { $0.uniqueID == selectedCameraID } ?? cameras.first
    }

    // MARK: Devices

    func refreshCameras() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera
        ]
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                   mediaType: .video,
                                                   position: .unspecified).devices
        if selectedCameraID == nil || !cameras.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = cameras.first?.uniqueID
        }
    }

    // MARK: Permissions

    func requestPermissions() async -> Bool {
        let camera = await Self.authorize(.video)
        var microphone = true
        if includeMicrophone { microphone = await Self.authorize(.audio) }
        if !camera { previewState = .noPermission }
        return camera && microphone
    }

    private static func authorize(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    // MARK: Preview

    func startPreview() {
        previewRequested = true
        Task { await bringUpSession(forRecording: false) }
    }

    func stopPreview() {
        guard !isRecording else { return }
        previewRequested = false
        Task {
            await engine.stopRunning()
            previewState = .off
        }
    }

    /// Restarts the graph after the camera or microphone choice changes.
    func reconfigureIfPreviewing() {
        guard previewRequested, !isRecording else { return }
        Task { await bringUpSession(forRecording: false) }
    }

    @discardableResult
    private func bringUpSession(forRecording: Bool) async -> Bool {
        guard await requestPermissions() else { return false }
        refreshCameras()
        guard let camera = selectedCamera else {
            previewState = .noCamera
            return false
        }
        do {
            try await engine.configure(camera: camera, includeMicrophone: includeMicrophone)
            await engine.startRunning()
            previewState = .live(camera.localizedName)
            return true
        } catch {
            previewState = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: Recording

    func start(to url: URL) async throws {
        guard await bringUpSession(forRecording: true) else {
            throw SimpleError(previewState == .noPermission
                ? "Camera or microphone access was denied."
                : "The camera could not be started.")
        }
        // Let any pending UI work (such as the preview layer attaching itself to the
        // session) land before recording starts, and give the camera a moment to settle.
        try? await Task.sleep(nanoseconds: 400_000_000)

        lastError = nil
        try await engine.startRecording(to: url)
        isRecording = true
    }

    func stop() async -> Bool {
        guard isRecording else { return false }
        let succeeded = await engine.stopRecording()
        isRecording = false
        lastError = engine.lastError
        if !previewRequested {
            await engine.stopRunning()
            previewState = .off
        }
        return succeeded
    }
}

/// AVCaptureVideoPreviewLayer in a plain layer-backed NSView.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspect
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }
}
