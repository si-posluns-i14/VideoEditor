import SwiftUI
import AVFoundation
import AppKit

/// Capture mode: a big camera preview, the capture settings beside it, and one large
/// record button. Everything to do with getting footage in.
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: RecordingManager
    @ObservedObject var screen: ScreenRecorder
    @ObservedObject var webcam: WebcamRecorder

    var body: some View {
        HSplitView {
            MediaBrowserView()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            VStack(spacing: 0) {
                preview
                Divider()
                transport
            }
            .frame(minWidth: 420)
            ScrollView { settings.padding(14) }
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
        }
        .task {
            recorder.loadPreferences()
            webcam.refreshCameras()
            await screen.refreshDisplays()
            if recorder.recordWebcam { webcam.startPreview() }
        }
        .onDisappear { webcam.stopPreview() }
        .onChange(of: webcam.selectedCameraID) { _, _ in
            recorder.savePreferences()
            webcam.reconfigureIfPreviewing()
        }
        .onChange(of: webcam.includeMicrophone) { _, _ in
            recorder.savePreferences()
            webcam.reconfigureIfPreviewing()
        }
        .onChange(of: recorder.recordScreen) { _, on in
            recorder.savePreferences()
            if on { Task { await screen.refreshDisplays() } }
        }
        .onChange(of: recorder.recordWebcam) { _, on in
            recorder.savePreferences()
            on ? webcam.startPreview() : webcam.stopPreview()
        }
        .onChange(of: recorder.captureSystemAudio) { _, _ in recorder.savePreferences() }
        .onChange(of: recorder.frameRate) { _, _ in recorder.savePreferences() }
        .onChange(of: recorder.takeName) { _, _ in recorder.savePreferences() }
        .onChange(of: screen.selectedDisplayID) { _, _ in recorder.savePreferences() }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black
            // Mounted once and only faded: attaching a preview layer to a live
            // AVCaptureSession counts as a configuration change and would abort a take.
            CameraPreview(session: webcam.session)
                .opacity(isPreviewing ? 1 : 0)

            if !recorder.recordWebcam {
                placeholder("Screen only — the webcam is switched off", "display")
            } else {
                switch webcam.previewState {
                case .live: EmptyView()
                case .off: placeholder("Starting camera…", "video")
                case .noCamera: placeholder("No camera found", "questionmark.video")
                case .noPermission:
                    placeholder("Camera access denied — enable it in System Settings → Privacy & Security", "hand.raised")
                case .failed(let reason): placeholder(reason, "exclamationmark.triangle")
                }
            }

            if recorder.isRecording {
                VStack {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text(recorder.elapsedText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(12)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                recorder.toggle(workspace: model.workspace)
            } label: {
                Label(recorder.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(width: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(model.workspace == nil || recorder.isBusy
                      || (!recorder.recordScreen && !recorder.recordWebcam))
            .keyboardShortcut("r", modifiers: [.command])

            VStack(alignment: .leading, spacing: 2) {
                if !recorder.statusText.isEmpty {
                    Text(recorder.statusText).font(.caption)
                }
                if let error = recorder.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.workspace == nil {
                    Text("Open a workspace first — recordings are saved into its Media folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.lastRecordingSummary != nil, !recorder.isRecording {
                Button {
                    model.mode = .edit
                } label: {
                    Label("Assemble in Timeline", systemImage: "arrow.right")
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Settings column

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Take name").font(.system(size: 12, weight: .medium))
                    TextField("Take", text: $recorder.takeName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { recorder.savePreferences() }
                        .disabled(recorder.isRecording)
                    Text(nameHint)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Screen", isOn: $recorder.recordScreen)
                        .font(.system(size: 12, weight: .medium))

                    if recorder.recordScreen {
                        if screen.permissionDenied {
                            Label("Screen Recording is not granted. Turn VideoEditor on in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Open System Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                }
                                Button("Ask Again") { screen.requestPermission() }
                            }
                            .controlSize(.small)
                            Button("Reset Permission…") { screen.resetPermission() }
                                .controlSize(.small)
                                .help("Clears macOS's recorded decision so it asks again next launch. Needed after rebuilding the app.")
                            if let note = screen.lastError {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if screen.displays.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Looking for displays…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("Display", selection: Binding(
                                get: { screen.selectedDisplayID ?? screen.displays.first?.displayID ?? 0 },
                                set: { screen.selectedDisplayID = $0 })) {
                                ForEach(screen.displays, id: \.displayID) { display in
                                    Text(screen.label(for: display)).tag(display.displayID)
                                }
                            }
                        }
                        Toggle("System audio", isOn: $recorder.captureSystemAudio)
                        Picker("Frame rate", selection: $recorder.frameRate) {
                            Text("24 fps").tag(24)
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(recorder.isRecording)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Webcam", isOn: $recorder.recordWebcam)
                        .font(.system(size: 12, weight: .medium))

                    if recorder.recordWebcam {
                        if webcam.cameras.isEmpty {
                            Text("No camera found.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("Camera", selection: Binding(
                                get: { webcam.selectedCameraID ?? webcam.cameras.first?.uniqueID ?? "" },
                                set: { webcam.selectedCameraID = $0 })) {
                                ForEach(webcam.cameras, id: \.uniqueID) { camera in
                                    Text(camera.localizedName).tag(camera.uniqueID)
                                }
                            }
                        }
                        Toggle("Microphone", isOn: $webcam.includeMicrophone)
                        Button("Rescan Cameras") { webcam.refreshCameras() }
                            .controlSize(.small)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(recorder.isRecording)

            Text("Screen and webcam are saved as two separate files in Media/ and appended to the timeline as a pair — the screen on the Clip row, the webcam on the Self-View row beneath it, locked to the same time frame.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    /// Shows exactly what the two files will be called.
    private var nameHint: String {
        let base = recorder.takeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "Empty — files will be named with the date and time." }
        var parts: [String] = []
        if recorder.recordScreen { parts.append("\(base) - Screen.mp4") }
        if recorder.recordWebcam { parts.append("\(base) - Self-View.mp4") }
        return parts.isEmpty ? "Nothing selected to record." : parts.joined(separator: "   ")
    }

    private var isPreviewing: Bool {
        if case .live = webcam.previewState { return true }
        return false
    }

    private func placeholder(_ text: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30))
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}
