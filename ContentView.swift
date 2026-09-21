import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.workspace == nil {
                WelcomeView()
            } else {
                workspace
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .alert("VideoEditor",
               isPresented: Binding(get: { model.message != nil },
                                    set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var workspace: some View {
        Group {
            switch model.mode {
            case .record:
                CaptureView(recorder: model.recorder,
                            screen: model.recorder.screen,
                            webcam: model.recorder.webcam)
            case .edit:
                timeline
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.revealWorkspace()
                } label: {
                    Label(model.workspace?.lastPathComponent ?? "Workspace", systemImage: "folder")
                }
                .help("Open the workspace folder in Finder")
            }
            ToolbarItem(placement: .principal) {
                // Deliberately buttons rather than a Picker: a segmented Picker in the
                // toolbar writes its own selection back once the toolbar realises, which
                // silently threw the app into the wrong mode a few seconds after launch.
                ModeSwitch(mode: model.mode, isRecording: model.recorder.isRecording) { model.mode = $0 }
            }
            ToolbarItem {
                Button { model.addClips(copy: true) } label: { Label("Add Clip", systemImage: "plus") }
                    .disabled(model.mode != .edit)
            }
            ToolbarItem {
                Button { model.startExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.exporter.isExporting || model.clips.isEmpty)
            }
        }
    }

    private var timeline: some View {
        VSplitView {
            HSplitView {
                MediaBrowserView()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                PreviewPane()
                    .frame(minWidth: 420)
                ScrollView {
                    VStack(spacing: 0) {
                        InspectorPane()
                        Divider()
                        FramePanel()
                        Divider()
                        ExportPanel(exporter: model.exporter)
                    }
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
            }
            .frame(minHeight: 320)

            TimelineStripView()
                .frame(minHeight: 170, idealHeight: 190, maxHeight: 280)
        }
    }
}

// MARK: - Welcome / workspace picker

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text("VideoEditor").font(.system(size: 26, weight: .semibold))
                        Text("Record your screen and webcam, then cut and join")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Everything for a project lives in one ordinary folder you choose — clips, project file and exports. Nothing is hidden away in your Library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380, alignment: .leading)

                HStack {
                    Button("New Workspace…") { model.newWorkspace() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Workspace…") { model.openWorkspace() }
                }
                .controlSize(.large)

                Spacer()
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Workspaces").font(.headline)
                if model.recents.isEmpty {
                    Text("None yet").foregroundStyle(.secondary).font(.callout)
                } else {
                    List {
                        ForEach(model.recents, id: \.path) { url in
                            Button {
                                model.open(url)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent).fontWeight(.medium)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from Recents") {
                                    RecentWorkspaces.forget(url)
                                    model.recents = RecentWorkspaces.valid()
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 330)
        }
        .frame(minWidth: 860, minHeight: 520)
    }
}

// MARK: - Export

struct ExportPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var exporter: ExportManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField(model.workspace?.lastPathComponent ?? "Export", text: $model.exportName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.scheduleSave() }
            }
            Picker("Quality", selection: $model.exportQuality) {
                ForEach(ExportQuality.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: model.exportQuality) { _, _ in model.scheduleSave() }
            .disabled(needsProRes)

            Text(formatNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.hasBackgroundRemoval {
                Label("Background removal makes export take longer.", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if exporter.isExporting {
                ProgressView(value: exporter.progress)
                HStack {
                    Text("\(Int(exporter.progress * 100))%").font(.caption).monospacedDigit()
                    Spacer()
                    Button("Cancel") { exporter.cancel() }.controlSize(.small)
                }
            } else {
                Button {
                    model.startExport()
                } label: {
                    Label("Export to Exports/", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.clips.isEmpty)
            }

            if !exporter.statusText.isEmpty {
                Text(exporter.statusText).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = exporter.resultURL {
                HStack {
                    Button("Reveal in Finder") { revealInFinder(url) }
                    Button("Play") { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }

            if let error = exporter.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Cuts are made at the trim points you set. A cut that does not land on a keyframe can show a single soft or black frame — normal for a plain cut-and-join tool.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var needsProRes: Bool {
        model.clips.contains { $0.removeBackground && $0.backgroundMode == .transparent }
    }

    private var formatNote: String {
        needsProRes
            ? "A transparent background needs an alpha channel, so this export is written as ProRes 4444 in a .mov. H.264 .mp4 cannot hold transparency."
            : "Exports are written as H.264 .mp4 into the workspace's Exports folder."
    }
}


/// Capture | Timeline, as two buttons that only ever write when clicked.
struct ModeSwitch: View {
    let mode: WorkspaceMode
    let isRecording: Bool
    let select: (WorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceMode.allCases) { candidate in
                Button {
                    select(candidate)
                } label: {
                    Text(candidate.label)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(mode == candidate ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(mode == candidate ? Color.white : Color.secondary)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        // Switching tears down the camera preview, which would abort a take.
        .disabled(isRecording)
        .help(isRecording ? "Stop recording first" : "Switch between capture and the timeline")
    }
}
