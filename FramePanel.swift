import SwiftUI

/// Aspect ratio of the finished video, and how the clips sit inside it.
struct FramePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frame").font(.system(size: 12, weight: .semibold))

            Picker("Aspect", selection: $model.frame.preset) {
                ForEach(AspectPreset.allCases) { Text($0.label).tag($0) }
            }
            Text(model.frame.preset.note)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.frame.preset != .original {
                Picker("Scaling", selection: $model.frame.mode) {
                    ForEach(CropMode.allCases) { Text($0.label).tag($0) }
                }

                if model.frame.mode == .fill {
                    positionControls
                    Toggle("Show what gets cropped", isOn: $model.showCropGuide)
                    Text(model.showCropGuide
                         ? "The preview shows the whole frame, dimmed outside the crop — drag the yellow box to move it."
                         : "The preview is framed exactly as the export will be.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let size = outputSize {
                    Text(verbatim: "Output: \(Int(size.width))×\(Int(size.height))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var positionControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Crop position").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Centre") {
                    model.frame.cropX = 0.5
                    model.frame.cropY = 0.5
                }
                .controlSize(.mini)
                .disabled(model.frame.cropX == 0.5 && model.frame.cropY == 0.5)
            }

            slider("X", value: $model.frame.cropX, enabled: cropsHorizontally,
                   low: "Left", high: "Right")
            slider("Y", value: $model.frame.cropY, enabled: cropsVertically,
                   low: "Top", high: "Bottom")
        }
    }

    private func slider(_ axis: String, value: Binding<Double>, enabled: Bool,
                        low: String, high: String) -> some View {
        HStack(spacing: 6) {
            Text(axis).font(.system(size: 10, weight: .medium)).frame(width: 10)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? "0% = \(low), 100% = \(high)" : "This aspect ratio does not crop that axis")
    }

    private var outputSize: CGSize? {
        let source = model.sequenceSourceSize
        guard source.width > 0, source.height > 0 else { return nil }
        return model.frame.preset.outputSize(source: source)
    }

    /// The crop only takes slices off the axis where the source overflows the frame.
    private var cropsVertically: Bool {
        guard let ratio = presetRatio, let source = validSource else { return false }
        return ratio > source.width / source.height
    }

    private var cropsHorizontally: Bool {
        guard let ratio = presetRatio, let source = validSource else { return false }
        return ratio < source.width / source.height
    }

    private var presetRatio: CGFloat? { model.frame.mode == .fill ? model.frame.preset.ratio : nil }

    private var validSource: CGSize? {
        let source = model.sequenceSourceSize
        return (source.width > 0 && source.height > 0) ? source : nil
    }
}

/// Dims everything the chosen aspect ratio will cut away, and lets you drag the crop.
struct CropGuide: View {
    let source: CGSize
    @Binding var frame: FrameSpec

    @SCState private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let displayed = fitted(source, in: geo.size)
            let render = frame.preset.outputSize(source: source)
            let visible = Geometry.visibleSourceRect(source: source, render: render,
                                                     mode: frame.mode, position: frame.position)
            let scale = source.width > 0 ? displayed.width / source.width : 1
            let keep = CGRect(x: displayed.minX + visible.minX * scale,
                              y: displayed.minY + visible.minY * scale,
                              width: visible.width * scale,
                              height: visible.height * scale)
            let slackX = source.width - visible.width
            let slackY = source.height - visible.height

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(displayed)
                    path.addRect(keep)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                    .frame(width: keep.width, height: keep.height)
                    .position(x: keep.midX, y: keep.midY)

                // verbatim: a plain Text interpolation would localise these as 1,104.
                Text(verbatim: "\(frame.preset.label)  ·  \(Int(render.width))×\(Int(render.height))")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.yellow)
                    .position(x: keep.midX, y: max(keep.minY + 12, displayed.minY + 12))

                // The drag target is the whole preview, fixed in place. Attaching it to
                // the moving crop rectangle instead makes the rectangle chase the cursor:
                // the target shifts under the gesture, which changes the translation,
                // which shifts it again.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .local)
                            .onChanged { value in
                                if dragStart == nil {
                                    guard keep.contains(value.startLocation) else { return }
                                    dragStart = CGPoint(x: frame.cropX, y: frame.cropY)
                                }
                                guard let start = dragStart, scale > 0 else { return }
                                if slackX > 0.5 {
                                    let delta = Double(value.translation.width / scale) / Double(slackX)
                                    frame.cropX = min(max(start.x + delta, 0), 1)
                                }
                                if slackY > 0.5 {
                                    let delta = Double(value.translation.height / scale) / Double(slackY)
                                    frame.cropY = min(max(start.y + delta, 0), 1)
                                }
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
        }
    }

    /// Where an aspect-fitted video actually lands inside the player view.
    private func fitted(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
