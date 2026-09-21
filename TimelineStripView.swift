import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Two independent lanes on one ruler, iMovie style.
///
///     Clip:       [ clip 1 ][ clip 2 ]      [ clip 3 ]
///     Self-View:  [ one long self-view              ]
///
/// Clips carry their own start time, so either row can hold any number of clips of any
/// length, with gaps wherever you leave them. A self-view can be locked to a clip, and
/// then the two move and trim together; everything else slides freely.
struct TimelineStripView: View {
    @EnvironmentObject var model: AppModel

    private var pps: CGFloat { CGFloat(model.timelineZoom) }
    private let rowHeight: CGFloat = 62
    private let rulerHeight: CGFloat = 20
    private let gap: CGFloat = 8
    private let minimumCardWidth: CGFloat = 18
    private let rowSpace = "timelineRows"

    private enum TrimEdge { case leading, trailing }

    /// Where every clip being dragged sat when the drag began — a multi-selection moves
    /// as one.
    @SCState private var dragAnchors: [UUID: Double]?
    @SCState private var trimAnchor: (id: UUID, inPoint: Double, outPoint: Double, start: Double, end: Double)?
    @SCState private var marquee: (from: CGPoint, to: CGPoint)?

    /// Room to drag past the end of the material.
    private var contentWidth: CGFloat {
        max(360, CGFloat(model.timelineDuration + 5) * pps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                labels
                Divider()
                ScrollView(.horizontal) {
                    content.padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Text("Timeline").font(.system(size: 12, weight: .semibold))
            Text("\(model.mainClips.count) clip\(model.mainClips.count == 1 ? "" : "s")  ·  \(timecode(model.timelineDuration))")
                .font(.caption).foregroundStyle(.secondary)
            Text(preciseTimecode(model.sequenceTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.previewMode == .sequence ? .primary : .tertiary)
            if model.selectedIDs.count > 1 {
                Text("\(model.selectedIDs.count) selected")
                    .font(.caption)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            Spacer()

            Menu {
                ForEach(AspectPreset.allCases) { preset in
                    Button {
                        model.frame.preset = preset
                    } label: {
                        if model.frame.preset == preset {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
                Divider()
                Toggle("Show what gets cropped", isOn: $model.showCropGuide)
                    .disabled(!model.frame.cropsAnything)
            } label: {
                Label(model.frame.preset.label, systemImage: "aspectratio")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Aspect ratio of the exported video")

            Menu {
                Button("Close Gaps on Clip Row") { model.closeAllGaps(on: .main) }
                Button("Close Gaps on Self-View Row") { model.closeAllGaps(on: .selfView) }
            } label: {
                Label("Gaps", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Pack a row end to end")

            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .controlSize(.small)
                .disabled(!model.canSplit)
                .help("Split whatever the playhead is inside (⌘B)")

            Button { model.addClips(copy: true) } label: { Label("Add Clip", systemImage: "plus") }
                .controlSize(.small)

            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.timelineZoom, in: 6...140)
                    .frame(width: 90)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .help("Timeline zoom")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var labels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            Spacer().frame(height: gap)
            labelCell("Clip", "film")
            Spacer().frame(height: gap)
            labelCell("Self-View", "person.crop.square")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 96)
    }

    private func labelCell(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 10))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(height: rowHeight)
    }

    // MARK: Body

    private var content: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ruler
                Spacer().frame(height: gap)
                lane(.main)
                Spacer().frame(height: gap)
                lane(.selfView)
            }
            playhead

            if let marquee {
                let rect = CGRect(x: min(marquee.from.x, marquee.to.x),
                                  y: min(marquee.from.y, marquee.to.y),
                                  width: abs(marquee.to.x - marquee.from.x),
                                  height: abs(marquee.to.y - marquee.from.y))
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .contentShape(Rectangle())
        // Lowest priority: a drag that starts on a card or the ruler belongs to them.
        .gesture(marqueeGesture)
        // A stable space: measuring a drag in a card's own coordinates would let the card
        // move out from under the gesture.
        .coordinateSpace(name: rowSpace)
    }

    /// Drag across empty timeline to rubber-band a selection.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(rowSpace))
            .onChanged { value in
                marquee = (value.startLocation, value.location)
                applyMarquee(from: value.startLocation, to: value.location)
            }
            .onEnded { _ in marquee = nil }
    }

    private var mainRowRange: ClosedRange<CGFloat> {
        let top = rulerHeight + gap
        return top...(top + rowHeight)
    }

    private var selfRowRange: ClosedRange<CGFloat> {
        let top = rulerHeight + gap + rowHeight + gap
        return top...(top + rowHeight)
    }

    private func applyMarquee(from: CGPoint, to: CGPoint) {
        let times = [time(forX: from.x), time(forX: to.x)].sorted()
        let ys = [from.y, to.y].sorted()
        let band = ys[0]...ys[1]
        var tracks: [Track] = []
        if band.overlaps(mainRowRange) { tracks.append(.main) }
        if band.overlaps(selfRowRange) { tracks.append(.selfView) }
        guard !tracks.isEmpty else { return }
        model.selectInRange(times[0]...times[1], tracks: tracks)
    }

    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.secondary.opacity(0.08))
            ForEach(tickTimes, id: \.self) { time in
                let labelled = time.truncatingRemainder(dividingBy: labelEvery) == 0
                Rectangle()
                    .fill(Color.secondary.opacity(labelled ? 0.5 : 0.25))
                    .frame(width: 1, height: labelled ? rulerHeight : 5)
                    .offset(x: x(for: time))
                if labelled {
                    Text(timecode(time))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .offset(x: x(for: time) + 3, y: 4)
                }
            }
        }
        .frame(width: contentWidth, height: rulerHeight)
        .clipShape(Rectangle())
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(rowSpace))
                .onChanged { value in
                    model.setScrubbing(true)
                    model.seekSequence(to: time(forX: value.location.x))
                }
                .onEnded { _ in model.setScrubbing(false) }
        )
        .help("Drag to scrub the whole sequence")
    }

    private var tickStep: Double {
        let target: CGFloat = 60
        for candidate in [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0] where CGFloat(candidate) * pps >= target {
            return candidate
        }
        return 600
    }

    private var labelEvery: Double { tickStep * 2 }

    private var tickTimes: [Double] {
        let total = max(model.timelineDuration, Double(contentWidth / max(pps, 1)))
        guard total > 0 else { return [] }
        return stride(from: 0.0, through: total, by: tickStep).map { $0 }
    }

    private func lane(_ track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.07))
                .frame(width: contentWidth, height: rowHeight)

            if model.clips(in: track).isEmpty {
                Text(track == .main
                     ? "Drag clips here from the workspace, or record"
                     : "Webcam takes land here")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                    .frame(height: rowHeight, alignment: .leading)
            }

            ForEach(model.ordered(track)) { clip in
                card(clip, track: track)
                    .offset(x: x(for: clip.start))
            }
        }
        .frame(width: contentWidth, height: rowHeight, alignment: .topLeading)
        .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { providers, location in
            handleDrop(providers, track: track, at: time(forX: location.x))
        }
    }

    private var playhead: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: rulerHeight + gap * 2 + rowHeight * 2)
            .offset(x: x(for: model.sequenceTime) - 1)
            .opacity(model.previewMode == .sequence ? 1 : 0.25)
            .allowsHitTesting(false)
    }

    // MARK: Cards

    private func cardWidth(_ clip: Clip) -> CGFloat {
        max(minimumCardWidth, CGFloat(clip.trimmedDuration) * pps)
    }

    private func card(_ clip: Clip, track: Track) -> some View {
        let selected = model.selectedIDs.contains(clip.id)
        let isAnchor = model.selection == clip.id
        let width = cardWidth(clip)

        return ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.black.opacity(0.8))

            if let thumbnail = clip.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if clip.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)

            if width > 52 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(clip.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 3) {
                        Text(clip.isMissing ? "Missing" : timecode(clip.trimmedDuration))
                            .font(.system(size: 9))
                        if clip.removeBackground {
                            Text("BG")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 3)
                                .background(.purple.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.bottom, 3)
            }
        }
        .frame(width: width, height: rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.accentColor : Color.black.opacity(0.3),
                        lineWidth: selected ? 3 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(isAnchor && model.selectedIDs.count > 1 ? 0.9 : 0), lineWidth: 1)
                .padding(2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                model.extendSelection(to: clip.id)
            } else if flags.contains(.command) {
                model.toggleSelection(clip.id)
            } else {
                model.select(clip.id)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(rowSpace))
                .onChanged { value in
                    var first = false
                    if dragAnchors == nil {
                        // Dragging a clip outside the selection takes just that one.
                        if !model.selectedIDs.contains(clip.id) { model.select(clip.id) }
                        dragAnchors = Dictionary(uniqueKeysWithValues:
                            model.selectedClips.map { ($0.id, $0.start) })
                        first = true
                    }
                    guard let anchors = dragAnchors, let origin = anchors[clip.id] else { return }
                    let raw = Double(value.translation.width) / Double(pps)
                    // Snap the clip under the cursor, then shift the whole group by the
                    // same amount so their spacing is preserved.
                    let snappedStart = model.snapped(clip.id,
                                                     proposedStart: origin + raw,
                                                     tolerance: Double(7 / max(pps, 1)))
                    let count = anchors.count
                    model.moveSelection(anchors, by: snappedStart - origin,
                                        undoName: first ? (count > 1 ? "Move \(count) Clips" : "Move Clip") : nil)
                }
                .onEnded { _ in
                    dragAnchors = nil
                    model.finishDrag()
                }
        )
        .overlay(alignment: .leading) { trimHandle(clip, edge: .leading) }
        .overlay(alignment: .trailing) { trimHandle(clip, edge: .trailing) }
        .help("\(clip.displayName) — \(timecode(clip.start)) to \(timecode(clip.end))")
        .contextMenu { menu(for: clip, track: track) }
    }

    /// Grab either end of a card to change where the clip starts or stops. Trimming the
    /// head slides the clip along too, so the footage that remains does not move.
    private func trimHandle(_ clip: Clip, edge: TrimEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(trimAnchor?.id == clip.id ? 1 : 0.7))
                    .frame(width: 3, height: rowHeight * 0.4)
                    .shadow(radius: 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(rowSpace))
                    .onChanged { value in
                        var first = false
                        if trimAnchor?.id != clip.id {
                            trimAnchor = (clip.id, clip.inPoint, clip.resolvedOut, clip.start, clip.end)
                            first = true
                        }
                        guard let anchor = trimAnchor else { return }
                        let raw = Double(value.translation.width) / Double(pps)
                        let tolerance = Double(7 / max(pps, 1))
                        // Snap the edge being dragged, not the raw mouse delta, so the
                        // clip's end lands exactly on a neighbour or the playhead.
                        let edgeNow = (edge == .leading ? anchor.start : anchor.end) + raw
                        let snapped = model.snappedTime(excluding: clip.id, proposed: edgeNow, tolerance: tolerance)
                        let delta = snapped - (edge == .leading ? anchor.start : anchor.end)

                        model.updateClip(clip.id, undoName: first ? "Trim Clip" : nil) { c in
                            let limit = c.duration > 0 ? c.duration : anchor.outPoint
                            switch edge {
                            case .leading:
                                c.inPoint = min(max(anchor.inPoint + delta, 0), anchor.outPoint - 0.1)
                            case .trailing:
                                c.outPoint = max(min(anchor.outPoint + delta, limit), anchor.inPoint + 0.1)
                            }
                        }
                    }
                    .onEnded { _ in trimAnchor = nil }
            )
            .help(edge == .leading ? "Drag to trim the start" : "Drag to trim the end")
    }

    @ViewBuilder
    private func menu(for clip: Clip, track: Track) -> some View {
        let batch = model.selectedIDs.contains(clip.id) && model.selectedIDs.count > 1
        let targets: Set<UUID> = batch ? model.selectedIDs : [clip.id]

        Button(batch ? "Cut \(targets.count) Clips" : "Cut") {
            if !model.selectedIDs.contains(clip.id) { model.select(clip.id) }
            model.cutSelection()
        }
        Button(batch ? "Copy \(targets.count) Clips" : "Copy") {
            if !model.selectedIDs.contains(clip.id) { model.select(clip.id) }
            model.copySelection()
        }
        Button("Paste at Playhead") { model.paste() }
            .disabled(!model.canPaste)
        Divider()
        Button("Move to Playhead") { model.moveToPlayhead(clip.id) }
        Button("Close Gap Before") { model.closeGapBefore(clip.id) }
        Button("Close Gap After") { model.closeGapAfter(clip.id) }
        Divider()
        if track == .selfView {
            Button("Move to Clip Row") { model.setTrack(clip.id, to: .main) }
        } else {
            Button("Move to Self-View Row") { model.setTrack(clip.id, to: .selfView) }
        }
        Button("Reveal in Finder") { revealInFinder(clip.url) }
        Divider()
        Button(batch ? "Delete \(targets.count) Clips" : "Delete", role: .destructive) {
            model.delete(targets)
        }
    }

    // MARK: Geometry — linear now that clips carry their own start

    private func x(for time: Double) -> CGFloat { CGFloat(max(0, time)) * pps }

    private func time(forX px: CGFloat) -> Double { max(0, Double(px / max(pps, 1))) }

    // MARK: Drag and drop

    private func handleDrop(_ providers: [NSItemProvider], track: Track, at time: Double) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? NSURL as URL? else { return }
                    Task { @MainActor in model.dropFiles([url], to: track, at: time) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String else { return }
                    Task { @MainActor in
                        if let dropped = UUID(uuidString: text) {
                            if model.clips.first(where: { $0.id == dropped })?.track != track {
                                model.setTrack(dropped, to: track)
                            }
                            model.setStart(dropped, to: time)
                        } else {
                            model.dropFiles([URL(fileURLWithPath: text)], to: track, at: time)
                        }
                    }
                }
            }
        }
        return handled
    }
}
