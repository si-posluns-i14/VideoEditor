import Foundation
import SwiftUI
import AVFoundation

/// Runs the screen recorder and the webcam recorder as one session, and hands the
/// finished files back to the editor.
@MainActor
final class RecordingManager: ObservableObject {

    struct Session {
        /// Filenames relative to the workspace's Media/ folder.
        var screenFile: String?
        var webcamFile: String?
    }

    /// What this take is called. Files are named "<take> - Screen.mp4" and
    /// "<take> - Self-View.mp4", with a number appended if that name is taken.
    @Published var takeName = "Take"
    @Published var recordScreen = true
    @Published var recordWebcam = true
    @Published var captureSystemAudio = true
    @Published var frameRate = 30

    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var statusText = ""

    let screen = ScreenRecorder()
    let webcam = WebcamRecorder()

    /// Called on the main actor once both files are closed.
    var onFinish: ((Session) -> Void)?

    private var ticker: Timer?
    private var startDate: Date?
    private var screenURL: URL?
    private var webcamURL: URL?

    // MARK: Preferences

    private let defaults = UserDefaults.standard

    func loadPreferences() {
        if defaults.object(forKey: "recordScreen") != nil { recordScreen = defaults.bool(forKey: "recordScreen") }
        if defaults.object(forKey: "recordWebcam") != nil { recordWebcam = defaults.bool(forKey: "recordWebcam") }
        if defaults.object(forKey: "captureSystemAudio") != nil { captureSystemAudio = defaults.bool(forKey: "captureSystemAudio") }
        if defaults.object(forKey: "includeMicrophone") != nil { webcam.includeMicrophone = defaults.bool(forKey: "includeMicrophone") }
        webcam.selectedCameraID = defaults.string(forKey: "selectedCameraID")
        if let display = defaults.object(forKey: "selectedDisplayID") as? Int {
            screen.selectedDisplayID = CGDirectDisplayID(display)
        }
        if let fps = defaults.object(forKey: "frameRate") as? Int { frameRate = fps }
        if let name = defaults.string(forKey: "takeName"), !name.isEmpty { takeName = name }
    }

    func savePreferences() {
        defaults.set(recordScreen, forKey: "recordScreen")
        defaults.set(recordWebcam, forKey: "recordWebcam")
        defaults.set(captureSystemAudio, forKey: "captureSystemAudio")
        defaults.set(webcam.includeMicrophone, forKey: "includeMicrophone")
        defaults.set(webcam.selectedCameraID, forKey: "selectedCameraID")
        defaults.set(frameRate, forKey: "frameRate")
        defaults.set(takeName, forKey: "takeName")
        if let display = screen.selectedDisplayID { defaults.set(Int(display), forKey: "selectedDisplayID") }
    }

    // MARK: Session

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    func toggle(workspace: URL?) {
        Task { isRecording ? await stop() : await start(workspace: workspace) }
    }

    func start(workspace: URL?) async {
        guard !isRecording, !isBusy else { return }
        errorMessage = nil
        guard let workspace else { errorMessage = RecordingError.noWorkspace.localizedDescription; return }
        guard recordScreen || recordWebcam else { errorMessage = RecordingError.nothingSelected.localizedDescription; return }

        isBusy = true
        statusText = "Starting…"
        defer { isBusy = false }

        let media = WorkspaceManager.mediaFolder(workspace)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let trimmed = takeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if trimmed.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            base = formatter.string(from: Date())
        } else {
            base = trimmed.replacingOccurrences(of: "/", with: "-")
        }

        // One source failing must not take the other down with it: record whatever can
        // be recorded and report the rest.
        var problems: [String] = []

        // Reserve both names together so a clash bumps them as a pair.
        let suffix = nextSuffix(in: media, base: base)

        if recordWebcam {
            do {
                guard await webcam.requestPermissions() else {
                    throw SimpleError("Camera or microphone access was denied. Grant VideoEditor in System Settings → Privacy & Security → Camera (and Microphone).")
                }
                webcam.refreshCameras()
                let url = media.appendingPathComponent("\(base)\(suffix) - Self-View.mp4")
                try await webcam.start(to: url)
                webcamURL = url
            } catch {
                problems.append(error.localizedDescription)
            }
        }

        if recordScreen {
            do {
                let url = media.appendingPathComponent("\(base)\(suffix) - Screen.mp4")
                try await screen.start(to: url, fps: frameRate, captureSystemAudio: captureSystemAudio)
                screenURL = url
            } catch {
                problems.append(screen.permissionDenied
                    ? "Screen Recording permission is needed. Grant VideoEditor in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
                    : error.localizedDescription)
            }
        }

        guard screenURL != nil || webcamURL != nil else {
            statusText = ""
            errorMessage = problems.joined(separator: "\n")
            cleanUp(deleteFiles: true)
            return
        }
        errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")

        savePreferences()
        isRecording = true
        startDate = Date()
        elapsed = 0
        statusText = "Recording"
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func stop() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        statusText = "Finishing…"
        defer { isBusy = false }

        let webcamOK = webcamURL != nil ? await webcam.stop() : false
        let screenOK = screenURL != nil ? await screen.stop() : false

        var session = Session()
        var problems: [String] = []
        if screenOK, let url = screenURL, isUsable(url) {
            session.screenFile = url.lastPathComponent
        } else if let url = screenURL {
            try? FileManager.default.removeItem(at: url)
            problems.append("Screen: the recording came out empty.")
        }

        if webcamOK, let url = webcamURL, isUsable(url) {
            session.webcamFile = url.lastPathComponent
        } else if let url = webcamURL {
            try? FileManager.default.removeItem(at: url)
            if let reason = webcam.lastError { problems.append("Webcam: \(reason)") }
            else { problems.append("Webcam: the recording came out empty.") }
        }

        cleanUp(deleteFiles: false)

        if !problems.isEmpty {
            errorMessage = ([errorMessage].compactMap { $0 } + problems).joined(separator: "\n")
        }

        if session.screenFile == nil && session.webcamFile == nil {
            if errorMessage == nil {
                errorMessage = "Nothing was recorded. Check the Screen Recording and Camera permissions in System Settings."
            }
            statusText = ""
        } else {
            let parts = [session.screenFile != nil ? "screen" : nil, session.webcamFile != nil ? "webcam" : nil]
                .compactMap { $0 }
            statusText = "Saved \(parts.joined(separator: " + ")) to Media/"
            onFinish?(session)
        }
    }

    private func cleanUp(deleteFiles: Bool) {
        ticker?.invalidate(); ticker = nil
        isRecording = false
        startDate = nil
        if deleteFiles {
            [screenURL, webcamURL].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        screenURL = nil
        webcamURL = nil
    }

    private func isUsable(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        return size > 10_000
    }

    /// "" if neither "<base> - Screen.mp4" nor "<base> - Self-View.mp4" exists yet,
    /// otherwise " 2", " 3", …
    private func nextSuffix(in folder: URL, base: String) -> String {
        let fm = FileManager.default
        func taken(_ suffix: String) -> Bool {
            ["Screen", "Self-View"].contains {
                fm.fileExists(atPath: folder.appendingPathComponent("\(base)\(suffix) - \($0).mp4").path)
            }
        }
        if !taken("") { return "" }
        var counter = 2
        while taken(" \(counter)") { counter += 1 }
        return " \(counter)"
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(counter).mp4")
            counter += 1
        }
        return candidate
    }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
