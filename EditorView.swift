import SwiftUI
import AVFoundation

// MARK: - Preview, scrub bar and trim controls

struct PreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                // Sequence mode plays the whole timeline, so it must not depend on which
                // clip happens to be selected.
                if model.previewMode == .sequence {
                    if model.timelineDuration > 0 {
                        player
                    } else {
                        Text("Nothing on the timeline yet").foregroundStyle(.secondary)
                    }
                } else if model.selectedClip == nil {
                    Text("Select a clip in the timeline").foregroundStyle(.secondary)
                } else if model.selectedClip?.isMissing == true {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text("Missing clip: \(model.selectedClip?.displayName ?? "")")
                            .foregroundStyle(.white)
                        Text("Put the file back in the workspace's Media folder, then reopen the workspace.")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    player
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            transport
        }
    }

    private var player: some View {
        PlayerSurface(player: model.player)
            .overlay {
                if model.previewMode == .sequence,
                   model.showCropGuide,
                   model.frame.cropsAnything,
                   model.sequenceSourceSize.width > 0 {
                    CropGuide(source: model.sequenceSourceSize, frame: $model.frame)
                }
            }
    }

    @ViewBuilder
    private var transport: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Preview", selection: Binding(get: { model.previewMode },
                                                     set: { model.setPreviewMode($0) })) {
                    ForEach(PreviewMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Sequence plays the whole timeline. Clip plays the selected clip on its own, with trim handles.")

                if model.previewMode == .sequence {
                    Text("Scrub on the timeline ruler below")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            if model.previewMode == .sequence { sequenceTransport } else { clipTransport }
        }
    }

    private var sequenceTransport: some View {
        HStack(spacing: 10) {
            Button { model.step(-1.0 / 30.0) } label: { Image(systemName: "backward.frame.fill") }
            Button(action: model.playPause) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { model.step(1.0 / 30.0) } label: { Image(systemName: "forward.frame.fill") }

            Text("\(preciseTimecode(model.sequenceTime)) / \(timecode(model.timelineDuration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .disabled(!model.canSplit)
                .keyboardShortcut("b", modifiers: [.command])
                .help("Split the clip under the playhead")

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var clipTransport: some View {
        if let clip = model.selectedClip, !clip.isMissing, clip.duration > 0 {
            let binding = model.binding(for: clip.id)
            VStack(spacing: 6) {
                ScrubBar(duration: clip.duration,
                         current: model.currentTime,
                         inPoint: Binding(get: { binding.wrappedValue.inPoint },
                                          set: { binding.wrappedValue.inPoint = $0 }),
                         outPoint: Binding(get: { binding.wrappedValue.resolvedOut },
                                           set: { binding.wrappedValue.outPoint = $0 }),
                         onSeek: { model.seek(to: $0) },
                         onScrubbingChanged: { model.setScrubbing($0) })
                    .padding(.horizontal, 14)

                HStack(spacing: 10) {
                    Button { model.step(-1.0 / 30.0) } label: { Image(systemName: "backward.frame.fill") }
                        .help("Step back")
                    Button(action: model.playPause) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 22)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button { model.step(1.0 / 30.0) } label: { Image(systemName: "forward.frame.fill") }
                        .help("Step forward")

                    Text("\(preciseTimecode(model.currentTime)) / \(timecode(clip.duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Divider().frame(height: 16)

                    Button("Set In") { model.setInPointAtPlayhead() }
                    Button("Set Out") { model.setOutPointAtPlayhead() }
                    Button("Reset") { model.resetTrim() }

                    Text("\(timecode(clip.trimmedDuration)) selected")
                        .font(.system(size: 11, weight: .medium))

                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            .padding(.top, 10)
        } else {
            Text("Select a clip to trim it")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 14)
        }
    }
}

// MARK: - Inspector for the selected clip

struct InspectorPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let clip = model.selectedClip, !clip.isMissing {
            let binding = model.binding(for: clip.id)
            VStack(alignment: .leading, spacing: 14) {
                Text(clip.displayName).font(.headline).lineLimit(1).truncationMode(.middle)

                Picker("Row", selection: Binding(
                    get: { clip.track },
                    set: { model.setTrack(clip.id, to: $0) })) {
                    ForEach(Track.allCases) { Text($0.label).tag($0) }
                }

                VStack(alignment: .leading, spacing: 3) {
                    detail("Duration", timecode(clip.duration))
                    detail("Trimmed", "\(preciseTimecode(clip.inPoint)) → \(preciseTimecode(clip.resolvedOut))")
                    if clip.naturalSize != .zero {
                        detail("Size", "\(Int(clip.naturalSize.width))×\(Int(clip.naturalSize.height))")
                    }
                    detail("Storage", clip.isExternal ? "Referenced in place" : "Copied into Media/")
                }

                if clip.track == .selfView {
                    GroupBox("Picture-in-picture") {
                        VStack(alignment: .leading, spacing: 8) {
                            pipSlider("Size", value: binding.pipScale, range: 0.08...1.0,
                                      readout: String(format: "%.0f%%", clip.pipScale * 100),
                                      help: "Width of the self-view as a share of the frame — up to 100%, which fills it")
                            pipSlider("X", value: binding.pipX, range: 0...1,
                                      readout: String(format: "%.0f%%", clip.pipX * 100),
                                      help: "0% = left edge, 100% = right edge")
                            pipSlider("Y", value: binding.pipY, range: 0...1,
                                      readout: String(format: "%.0f%%", clip.pipY * 100),
                                      help: "0% = top edge, 100% = bottom edge")

                            Picker("Corners", selection: Binding(
                                get: { clip.pipCornerRadius > 0.001 },
                                set: { binding.wrappedValue.pipCornerRadius = $0 ? 0.08 : 0 })) {
                                Text("Square").tag(false)
                                Text("Rounded").tag(true)
                            }
                            if clip.pipCornerRadius > 0.001 {
                                pipSlider("Radius", value: binding.pipCornerRadius, range: 0.01...0.5,
                                          readout: String(format: "%.0f%%", clip.pipCornerRadius * 100),
                                          help: "Corner radius, as a share of the self-view's shorter side")
                            }

                            HStack(spacing: 6) {
                                Text("Snap to").font(.caption).foregroundStyle(.secondary)
                                ForEach(PiPCorner.allCases) { corner in
                                    Button {
                                        binding.wrappedValue.pipX = corner.position.x
                                        binding.wrappedValue.pipY = corner.position.y
                                    } label: {
                                        Image(systemName: corner.symbol)
                                    }
                                    .controlSize(.small)
                                    .help(corner.label)
                                }
                                Button {
                                    binding.wrappedValue.pipX = 0.5
                                    binding.wrappedValue.pipY = 0.5
                                } label: {
                                    Image(systemName: "circle.circle")
                                }
                                .controlSize(.small)
                                .help("Centre")
                            }

                            Text("Composited over the clip at the same position on the Clip row. The position is inside the exported frame, so it follows the aspect ratio you pick.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Background") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Remove Background", isOn: binding.removeBackground)
                        if binding.wrappedValue.removeBackground {
                            Picker("Replace with", selection: binding.backgroundMode) {
                                ForEach(BackgroundMode.allCases) { Text($0.label).tag($0) }
                            }
                            if binding.wrappedValue.backgroundMode == .solid {
                                ColorPicker("Colour", selection: Binding(
                                    get: { binding.wrappedValue.backgroundColor.color },
                                    set: { binding.wrappedValue.backgroundColor = RGBAColor($0) }))
                            }
                            Picker("Quality", selection: binding.segmentationQuality) {
                                ForEach(SegmentationQuality.allCases) { Text($0.label).tag($0) }
                            }
                            BackgroundPreviewThumb(clip: binding.wrappedValue, at: model.currentTime)
                            Text("Applied at export only. Background removal makes export take noticeably longer, and hair or fast motion can show rough edges.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.tertiary)
                Text("Select a clip to edit it").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private func pipSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           readout: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 28, alignment: .leading)
            Slider(value: value, in: range)
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
        }
        .help(help)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - One-frame preview of the segmentation effect

struct BackgroundPreviewThumb: View {
    let clip: Clip
    let at: Double

    @SCState private var image: CGImage?
    @SCState private var working = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if working {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 168, height: 95)

            VStack(alignment: .leading, spacing: 4) {
                Text("Current frame").font(.caption)
                Button("Refresh") { Task { await load() } }
                    .controlSize(.small)
            }
            Spacer()
        }
        .task(id: key) { await load() }
    }

    private var key: String {
        "\(clip.id)-\(clip.removeBackground)-\(clip.backgroundMode)-\(clip.segmentationQuality)-\(clip.backgroundColor)"
    }

    private func load() async {
        working = true
        image = await BackgroundPreview.image(url: clip.url, at: at, clip: clip)
        working = false
    }
}
