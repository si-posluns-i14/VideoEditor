import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

/// Writes ScreenCaptureKit frames (and, optionally, system audio) straight to an .mp4.
///
/// Kept off the main actor: SCStream delivers sample buffers on its own queues and this
/// object appends them there, so the UI never waits on the encoder.
final class ScreenStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var sessionStarted = false
    private var stopped = false

    /// Called if the stream dies on its own (display disconnected, permission revoked…).
    var onFailure: (@Sendable (Error) -> Void)?

    init(url: URL, width: Int, height: Int, fps: Int, captureAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let bitrate = min(40_000_000, max(6_000_000, width * height * fps / 10))
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        if captureAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }

        switch outputType {
        case .screen:
            // ScreenCaptureKit also emits "idle" and "blank" frames; only complete ones
            // carry pixels worth writing.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  sampleBuffer.imageBuffer != nil else { return }

            if !sessionStarted {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData { videoInput.append(sampleBuffer) }

        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)

        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }

    // MARK: Finishing

    /// Closes the inputs under the lock; kept separate so no lock is held across `await`.
    private func sealInputs() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hadFrames = sessionStarted
        stopped = true
        if hadFrames {
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
        }
        return hadFrames
    }

    /// Returns true if a file with actual content was written.
    func finish() async -> Bool {
        guard sealInputs() else {
            writer.cancelWriting()
            return false
        }
        await writer.finishWriting()
        return writer.status == .completed
    }
}

/// Owns the SCStream and its writer; drives one screen recording.
@MainActor
final class ScreenRecorder: ObservableObject {

    @Published private(set) var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var permissionDenied = false
    @Published private(set) var lastError: String?

    private var stream: SCStream?
    private var output: ScreenStreamOutput?

    var selectedDisplay: SCDisplay? {
        displays.first { $0.displayID == selectedDisplayID } ?? displays.first
    }

    func label(for display: SCDisplay) -> String {
        let name = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.localizedName
        return "\(name ?? "Display") — \(display.width)×\(display.height)"
    }

    /// True once Screen Recording has been granted to *this* build of the app.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt — but only if macOS has no decision on file yet. Once a
    /// denial is recorded it returns false silently, which is what `resetPermission()`
    /// is for.
    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Clears the recorded decision so macOS will ask again on the next launch.
    ///
    /// Needed more often than you would think: the app is ad-hoc signed, so every
    /// rebuild changes its code signature and macOS treats it as a different app,
    /// leaving a stale entry behind that can never be satisfied.
    func resetPermission() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "local.videoeditor.app"]
        try? process.run()
        process.waitUntilExit()
        lastError = "Permission reset. Quit and reopen VideoEditor, then press Record and choose Allow."
    }

    /// Also the permission check: this throws until Screen Recording is granted.
    func refreshDisplays() async {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            permissionDenied = false
            lastError = nil
            if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = content.displays.first?.displayID
            }
        } catch {
            displays = []
            permissionDenied = true
            lastError = error.localizedDescription
        }
    }

    func start(to url: URL, fps: Int, captureSystemAudio: Bool) async throws {
        await refreshDisplays()
        guard let display = selectedDisplay else { throw RecordingError.noDisplay }

        // Native pixels, so a Retina display is not recorded at half resolution.
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        let width = min(4096, Int((CGFloat(display.width) * scale).rounded()) & ~1)
        let height = min(4096, Int((CGFloat(display.height) * scale).rounded()) & ~1)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = captureSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        // Leave VideoEditor itself out, or the preview mirrors into infinity.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier ?? "local.videoeditor.app"
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let output = try ScreenStreamOutput(url: url, width: width, height: height,
                                            fps: fps, captureAudio: captureSystemAudio)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "local.videoeditor.screen"))
        if captureSystemAudio {
            try stream.addStreamOutput(output, type: .audio,
                                       sampleHandlerQueue: DispatchQueue(label: "local.videoeditor.screenaudio"))
        }
        try await stream.startCapture()

        self.stream = stream
        self.output = output
    }

    /// Returns true if a usable file was produced.
    func stop() async -> Bool {
        guard let stream, let output else { return false }
        self.stream = nil
        self.output = nil
        try? await stream.stopCapture()
        return await output.finish()
    }
}

enum RecordingError: LocalizedError {
    case noDisplay
    case noCamera
    case noWorkspace
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display is available to capture."
        case .noCamera: return "No camera is available."
        case .noWorkspace: return "Open a workspace first — recordings are saved into its Media folder."
        case .nothingSelected: return "Turn on the screen, the webcam, or both."
        }
    }
}
