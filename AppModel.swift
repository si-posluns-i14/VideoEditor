import Foundation
import SwiftUI
import AVFoundation
import AppKit

enum PreviewMode: String, CaseIterable, Identifiable {
    case sequence, clip
    var id: String { rawValue }
    var label: String { self == .sequence ? "Sequence" : "Clip" }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case record, edit
    var id: String { rawValue }
    var label: String { self == .record ? "Capture" : "Timeline" }
    var symbol: String { self == .record ? "record.circle" : "film.stack" }
}

@MainActor
final class AppModel: ObservableObject {

    // Workspace
    @Published var workspace: URL?
    @Published var recents: [URL] = RecentWorkspaces.valid()
    @Published var message: String?

    /// Which half of the app is showing: capture or the editing timeline.
    @Published var mode: WorkspaceMode = .record {
        didSet { AppModel.trace("mode \(oldValue.rawValue) -> \(mode.rawValue) on \(ObjectIdentifier(self))") }
    }

    static func trace(_ line: String) {
        guard AppModel.launchOption("reportstate") != nil else { return }
        let url = URL(fileURLWithPath: "/tmp/videoeditor-trace.log")
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let text = "\(stamp)  \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    /// Sequence plays the whole assembled timeline; Clip plays the selected clip alone,
    /// which is where the in/out trim handles live.
    @Published var previewMode: PreviewMode = .sequence
    @Published private(set) var sequenceDuration: Double = 0
    @Published var sequenceTime: Double = 0
    /// Set after a take finishes, so capture mode can offer a way into the timeline.
    @Published var lastRecordingSummary: String?

    // Timeline
    @Published var clips: [Clip] = []
    /// The clip the inspector and the Clip preview follow — the last one clicked.
    @Published var selection: UUID?
    /// Everything highlighted on the timeline. Always contains `selection` when there is
    /// one; shift-click extends it along a row, ⌘-click toggles one clip.
    @Published var selectedIDs: Set<UUID> = []

    // Playback
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    // Everything sitting in the workspace folder, whether or not it is on the timeline
    @Published private(set) var mediaFiles: [URL] = []
    @Published private(set) var exportFiles: [URL] = []

    /// How the finished video is framed — aspect ratio, and how the clips sit inside it.
    @Published var frame = FrameSpec() {
        didSet {
            guard frame != oldValue else { return }
            AppModel.trace("frame \(oldValue.preset.rawValue)/\(String(format: "%.3f", oldValue.cropX)) -> \(frame.preset.rawValue)/\(String(format: "%.3f", frame.cropX))")
            scheduleSave()
            invalidateSequence()
        }
    }
    /// Preview the full source frame with the crop drawn on it, rather than the crop
    /// itself. A view preference, so it sticks between launches.
    @Published var showCropGuide = UserDefaults.standard.bool(forKey: "showCropGuide") {
        didSet {
            UserDefaults.standard.set(showCropGuide, forKey: "showCropGuide")
            invalidateSequence()
        }
    }
    /// The natural frame of the clips, for drawing that guide.
    @Published private(set) var sequenceSourceSize: CGSize = .zero

    /// Timeline scale, in points per second. A view preference, so it sticks.
    @Published var timelineZoom: Double = {
        let stored = UserDefaults.standard.double(forKey: "timelineZoom")
        return stored > 0 ? stored : 30
    }() {
        didSet { UserDefaults.standard.set(timelineZoom, forKey: "timelineZoom") }
    }

    // Export settings
    @Published var exportName = ""
    @Published var exportQuality: ExportQuality = .highest

    let player = AVPlayer()
    let recorder = RecordingManager()
    let exporter = ExportManager()

    private var undoStack: [(name: String, clips: [Clip], selection: UUID?)] = []
    private var redoStack: [(name: String, clips: [Clip], selection: UUID?)] = []
    private var lastUndoName: String?
    private var lastUndoAt = Date.distantPast
    private let undoLimit = 60

    private var saveTask: Task<Void, Never>?
    /// Clips just dropped in, waiting on their duration before the row can be opened up.
    /// Until that arrives a clip has no length, so it cannot overlap anything.
    private var pendingInsertions: Set<UUID> = []
    private var sequenceTask: Task<Void, Never>?
    /// Held so the composition backing the preview player stays alive.
    private var sequencePlan: RenderPlan?
    private var timeObserver: Any?
    private var scrubbing = false

    init() {
        AppModel.trace("AppModel init \(ObjectIdentifier(self))")
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in self?.tick(time.seconds) }
            }

        recorder.onFinish = { [weak self] session in
            self?.addRecorded(session)
        }

        // Debug affordance: --workspace /path/to/folder (or VIDEOEDITOR_WORKSPACE)
        // opens that workspace straight away, which is handy when testing without
        // clicking through the welcome screen.
        if let path = AppModel.launchOption("workspace"),
           FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
            if let seconds = AppModel.launchOption("autorecord").flatMap(Double.init) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self.recorder.start(workspace: self.workspace)
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    await self.recorder.stop()
                    let report = """
                    status: \(self.recorder.statusText)
                    error: \(self.recorder.errorMessage ?? "none")
                    camera: \(String(describing: self.recorder.webcam.previewState))
                    screenPermissionDenied: \(self.recorder.screen.permissionDenied)
                    screenError: \(self.recorder.screen.lastError ?? "none")
                    clips: \(self.clips.map(\.displayName))
                    """
                    try? report.write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                      atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("selecttest") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    let state = { @MainActor (label: String) -> String in
                        "\(label): main=\(self.mainClips.count) self=\(self.selfViewClips.count) selected=\(self.selectedIDs.count) anchor=\(self.selection != nil)"
                    }
                    var lines = [state("start")]
                    let mains = self.mainClips
                    if mains.count >= 3 {
                        self.select(mains[0].id)
                        lines.append(state("click first"))
                        self.extendSelection(to: mains[2].id)
                        lines.append(state("shift-click third"))
                        self.toggleSelection(mains[1].id)
                        lines.append(state("cmd-click second"))
                        self.deleteSelected()
                        lines.append(state("delete selection"))
                        self.undo()
                        lines.append(state("undo"))
                    } else {
                        lines.append("needs at least 3 clips on the Clip row")
                    }
                    try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                              atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("undotest") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    let summary = { @MainActor (label: String) -> String in
                        "\(label): \(self.mainClips.count) main / \(self.selfViewClips.count) self  "
                            + "canUndo=\(self.canUndo) [\(self.undoActionName)] canRedo=\(self.canRedo) [\(self.redoActionName)]"
                    }
                    var lines = [summary("start")]
                    self.seekSequence(to: 3.5)
                    self.splitAtPlayhead()
                    lines.append(summary("after split"))
                    self.undo()
                    lines.append(summary("after undo"))
                    self.redo()
                    lines.append(summary("after redo"))
                    self.undo()
                    lines.append(summary("after undo again"))
                    if let first = self.mainClips.first {
                        self.updateClip(first.id) { $0.inPoint += 2 }
                        lines.append(summary("after trim +2"))
                        lines.append("  in=\(String(format: "%.2f", self.mainClips.first?.inPoint ?? -1))")
                        self.undo()
                        lines.append(summary("after undo trim"))
                        lines.append("  in=\(String(format: "%.2f", self.mainClips.first?.inPoint ?? -1))")
                    }
                    try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                              atomically: true, encoding: .utf8)
                }
            }
            if let which = AppModel.launchOption("previewmode") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    self.setPreviewMode(which == "clip" ? .clip : .sequence)
                }
            }
            if AppModel.launchOption("frameprobe") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    var lines: [String] = []
                    guard let item = self.player.currentItem else {
                        try? "no player item".write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                    atomically: true, encoding: .utf8)
                        return
                    }
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(output)
                    self.player.play()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    let time = item.currentTime()
                    lines.append("previewMode: \(self.previewMode.rawValue)")
                    lines.append("videoComposition attached: \(item.videoComposition != nil)")
                    if let vc = item.videoComposition {
                        lines.append("vc render \(Int(vc.renderSize.width))x\(Int(vc.renderSize.height)) instructions \(vc.instructions.count) custom \(vc.customVideoCompositorClass != nil)")
                    }
                    lines.append("asset tracks: \((item.asset as? AVComposition)?.tracks.count ?? -1)")
                    lines.append("status: \(item.status.rawValue) rate: \(self.player.rate) time: \(String(format: "%.2f", time.seconds))")
                    lines.append("likelyToKeepUp: \(item.isPlaybackLikelyToKeepUp)")
                    lines.append("tracks: " + item.tracks.map { "\($0.assetTrack?.trackID ?? -1):\($0.assetTrack?.mediaType.rawValue ?? "?"):\($0.isEnabled ? "on" : "off")" }.joined(separator: " "))
                    if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
                        if let base = CVPixelBufferGetBaseAddress(buffer) {
                            let stride = CVPixelBufferGetBytesPerRow(buffer)
                            let px = base.advanced(by: (h/2)*stride + (w/2)*4).assumingMemoryBound(to: UInt8.self)
                            lines.append("frame \(w)x\(h) centre b\(px[0]) g\(px[1]) r\(px[2])")
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    } else {
                        lines.append("frame: none")
                    }
                    self.player.pause()
                    try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                             atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("dragtest") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    let layout = { @MainActor (label: String) -> String in
                        label + "  main: " + self.ordered(.main).map {
                            "[\(String(format: "%.1f", $0.start))-\(String(format: "%.1f", $0.end))]"
                        }.joined(separator: " ")
                    }
                    var lines = [layout("before")]

                    // Drag the first clip past the other two.
                    if let first = self.ordered(.main).first {
                        self.select(first.id)
                        self.setStart(first.id, to: 4.5)
                        lines.append(layout("mid-drag (overlap allowed)"))
                        self.finishDrag()
                        lines.append(layout("after drop past both"))
                    }

                    // Move the last two together.
                    let row = self.ordered(.main)
                    if row.count >= 3 {
                        self.select(row[1].id)
                        self.toggleSelection(row[2].id)
                        let anchors = Dictionary(uniqueKeysWithValues: self.selectedClips.map { ($0.id, $0.start) })
                        self.moveSelection(anchors, by: 3, undoName: "Move 2 Clips")
                        self.finishDrag()
                        lines.append(layout("after moving the last two by +3"))
                    }

                    let r = self.ordered(.main)
                    let overlaps = zip(r, r.dropFirst()).filter { $1.start < $0.end - 0.001 }.count
                    lines.append(overlaps == 0 ? "no overlaps" : "\(overlaps) overlaps")
                    try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                             atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("clipboardtest") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    let layout = { @MainActor (label: String) -> String in
                        label + "\n" + [Track.main, .selfView].map { track in
                            "  \(track.rawValue): " + self.ordered(track).map {
                                "[\(String(format: "%.1f", $0.start))-\(String(format: "%.1f", $0.end))]"
                            }.joined(separator: " ")
                        }.joined(separator: "\n")
                    }
                    var lines = [layout("before")]

                    // Rubber-band the first three seconds of both rows.
                    self.selectInRange(0...3, tracks: [.main, .selfView])
                    lines.append("marquee 0–3s selected \(self.selectedIDs.count) clips")

                    self.copySelection()
                    lines.append("clipboard holds \(self.clipboard.count)")

                    self.seekSequence(to: self.timelineDuration)
                    self.paste()
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    lines.append(layout("after pasting at the end"))

                    // Cut the first clip and check the clipboard round-trips.
                    if let first = self.ordered(.main).first {
                        self.select(first.id)
                        self.cutSelection()
                        lines.append(layout("after cutting the first clip"))
                        self.seekSequence(to: 0)
                        self.paste()
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        lines.append(layout("after pasting it back at 0"))
                    }

                    let overlaps = [Track.main, .selfView].flatMap { track -> [String] in
                        let row = self.ordered(track)
                        return zip(row, row.dropFirst()).compactMap { a, b in
                            b.start < a.end - 0.001 ? "\(track.rawValue) overlap at \(String(format: "%.2f", b.start))" : nil
                        }
                    }
                    lines.append(overlaps.isEmpty ? "no overlaps" : overlaps.joined(separator: "\n"))
                    try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                             atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("inserttest") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    let layout = { @MainActor (label: String) -> String in
                        label + "\n" + [Track.main, .selfView].map { track in
                            "  \(track.rawValue): " + self.ordered(track).map {
                                "[\(String(format: "%.1f", $0.start))-\(String(format: "%.1f", $0.end))]"
                            }.joined(separator: " ")
                        }.joined(separator: "\n")
                    }
                    var lines = [layout("before")]

                    // Drop a library file into the middle of the Clip row.
                    if let file = self.mediaFiles.first {
                        self.addFromLibrary(file, to: .main, at: 1.5)
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        lines.append(layout("after dropping at 1.5s"))
                    }

                    // Try to drag a tail over the next clip.
                    if let first = self.ordered(.main).first {
                        self.updateClip(first.id) { $0.outPoint = $0.inPoint + 999 }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        lines.append(layout("after over-trimming the first clip"))
                    }

                    let overlaps = [Track.main, .selfView].flatMap { track -> [String] in
                        let row = self.ordered(track)
                        return zip(row, row.dropFirst()).compactMap { a, b in
                            b.start < a.end - 0.001 ? "\(track.rawValue) overlap at \(String(format: "%.2f", b.start))" : nil
                        }
                    }
                    lines.append(overlaps.isEmpty ? "no overlaps" : overlaps.joined(separator: "\n"))
                    try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"),
                                                             atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("reportstate") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let report = """
                    mode: \(self.mode.rawValue)
                    clips: \(self.clips.count)  main: \(self.mainClips.count)  self: \(self.selfViewClips.count)
                    media: \(self.mediaFiles.count)
                    previewMode: \(self.previewMode.rawValue)
                    timelineDuration: \(String(format: "%.2f", self.timelineDuration))
                    sequenceDuration: \(String(format: "%.2f", self.sequenceDuration))
                    playerItem: \(self.player.currentItem != nil)
                    itemStatus: \(self.player.currentItem?.status.rawValue ?? -1)
                    itemError: \(self.player.currentItem?.error?.localizedDescription ?? "none")
                    \(self.planReport())
                    workspace: \(self.workspace?.path ?? "nil")
                    """
                    try? report.write(to: URL(fileURLWithPath: "/tmp/videoeditor-debug.log"), atomically: true, encoding: .utf8)
                }
            }
            if AppModel.launchOption("autoexport") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.startExport()
                }
            }
        }
    }

    /// Debug launch options, from either `--<name> <value>` on the command line or
    /// `VIDEOEDITOR_<NAME>` in the environment.
    static func launchOption(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        return ProcessInfo.processInfo.environment["VIDEOEDITOR_\(name.uppercased())"]
    }

    var selectedClip: Clip? {
        guard let selection else { return nil }
        return clips.first { $0.id == selection }
    }

    /// The timeline runs until the last thing on either row finishes.
    var timelineDuration: Double {
        clips.reduce(0) { max($0, $1.end) }
    }

    /// Clips on a row, in the order they play.
    func ordered(_ track: Track) -> [Clip] {
        clips(in: track).sorted { $0.start < $1.start }
    }

    /// Whatever is on `track` at this moment, if anything.
    func clip(on track: Track, at time: Double) -> Clip? {
        ordered(track).first { time >= $0.start - 0.0001 && time < $0.end - 0.0001 }
    }

    /// Lays out a project written before clips could be positioned freely: each row packed
    /// end to end, with a self-view starting wherever its clip does.
    func positionIfNeeded() {
        guard clips.contains(where: { $0.start < 0 }) else { return }
        var cursor = 0.0
        for index in clips.indices where clips[index].track == .main {
            if clips[index].start < 0 { clips[index].start = cursor }
            cursor = clips[index].end
        }
        var fallback = 0.0
        for index in clips.indices where clips[index].track == .selfView {
            guard clips[index].start < 0 else { continue }
            clips[index].start = fallback
            fallback = clips[index].end
        }
    }

    /// Moves a clip along its row. Nothing is clamped to its neighbours: dragging one
    /// clip past another has to be possible. Overlaps are resolved when the drag ends.
    func setStart(_ id: UUID, to seconds: Double, undoName: String? = "Move Clip") {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if let undoName { recordUndo(undoName) }
        clips[index].start = max(0, seconds)
        scheduleSave()
    }

    /// Moves everything selected together, from the positions captured when the drag began.
    func moveSelection(_ anchors: [UUID: Double], by delta: Double, undoName: String?) {
        if let undoName { recordUndo(undoName) }
        let floor = anchors.values.min() ?? 0
        let shift = max(delta, -floor)
        for (id, start) in anchors {
            guard let index = clips.firstIndex(where: { $0.id == id }) else { continue }
            clips[index].start = max(0, start + shift)
        }
        scheduleSave()
    }

    /// Called when a drag finishes: whatever ended up on top of something else is pushed
    /// clear, which is what lets a clip dragged past its neighbour land after it.
    func finishDrag() {
        resolveOverlaps(on: .main)
        resolveOverlaps(on: .selfView)
        scheduleSave()
    }

    // MARK: - Cut, copy and paste

    /// Copied clips, with their starts relative to the earliest of them.
    @Published private(set) var clipboard: [Clip] = []
    var canPaste: Bool { !clipboard.isEmpty }

    /// ⌘X/⌘C/⌘V belong to whatever is focused: a text field gets first refusal.
    func performCut() {
        guard !AppModel.forwardToTextEditor(#selector(NSText.cut(_:))) else { return }
        cutSelection()
    }

    func performCopy() {
        guard !AppModel.forwardToTextEditor(#selector(NSText.copy(_:))) else { return }
        copySelection()
    }

    func performPaste() {
        guard !AppModel.forwardToTextEditor(#selector(NSText.paste(_:))) else { return }
        paste()
    }

    private static func forwardToTextEditor(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    func copySelection() {
        let picked = selectedClips
        guard !picked.isEmpty else { return }
        let origin = picked.map(\.start).min() ?? 0
        clipboard = picked.map { clip -> Clip in
            var copy = clip.duplicated()
            copy.start = clip.start - origin
            return copy
        }
    }

    func cutSelection() {
        let ids = selectedIDs.isEmpty ? Set([selection].compactMap { $0 }) : selectedIDs
        guard !ids.isEmpty else { return }
        copySelection()
        delete(ids, undoName: ids.count > 1 ? "Cut \(ids.count) Clips" : "Cut Clip")
    }

    /// Drops the clipboard in at the playhead, sliding whatever follows out of the way.
    func paste() {
        guard !clipboard.isEmpty else { return }
        recordUndo(clipboard.count > 1 ? "Paste \(clipboard.count) Clips" : "Paste Clip")

        let at = sequenceTime
        var landed: [Clip] = []

        for track in [Track.main, Track.selfView] {
            let group = clipboard.filter { $0.track == track }
            guard !group.isEmpty else { continue }
            let insertAt = insertionPoint(on: track, at: at)
            let length = (group.map { $0.start + $0.trimmedDuration }.max() ?? 0)
            makeRoom(on: track, at: insertAt, length: length)
            for clip in group {
                var copy = clip.duplicated()
                copy.start = insertAt + clip.start
                landed.append(copy)
            }
        }
        clips.append(contentsOf: landed)
        resolveOverlaps(on: .main)
        resolveOverlaps(on: .selfView)

        selectedIDs = Set(landed.map(\.id))
        selection = landed.first?.id
        scheduleSave()
        loadMetadata()
    }

    /// Everything on these rows that the given stretch of timeline touches.
    func selectInRange(_ range: ClosedRange<Double>, tracks: [Track]) {
        let hits = clips.filter {
            tracks.contains($0.track) && $0.start < range.upperBound + 0.0001 && $0.end > range.lowerBound - 0.0001
        }
        selectedIDs = Set(hits.map(\.id))
        if let anchor = selection, !selectedIDs.contains(anchor) { selection = nil }
        if selection == nil { selection = hits.min { $0.start < $1.start }?.id }
    }

    /// Snaps one moment in time onto a nearby edge — used when dragging a clip's ends.
    func snappedTime(excluding id: UUID?, proposed: Double, tolerance: Double) -> Double {
        guard tolerance > 0 else { return proposed }
        var edges: [Double] = [0, sequenceTime]
        for other in clips where other.id != id {
            edges.append(other.start)
            edges.append(other.end)
        }
        var best = proposed
        var bestDistance = tolerance
        for edge in edges where edge >= 0 {
            let distance = abs(edge - proposed)
            if distance < bestDistance {
                bestDistance = distance
                best = edge
            }
        }
        return best
    }

    // MARK: - Keeping a row tidy

    /// Where a clip dropped at `time` should actually land: inside an existing clip is
    /// taken to mean "after it", so a drop never lands on top of something.
    func insertionPoint(on track: Track, at time: Double) -> Double {
        let wanted = max(0, time)
        if let straddling = ordered(track).first(where: { wanted > $0.start + 0.0001 && wanted < $0.end - 0.0001 }) {
            return straddling.end
        }
        return wanted
    }

    /// Slides everything from `time` onwards along a row to open up `length` seconds —
    /// but only by as much as is actually missing. Dropping into a gap that is already
    /// big enough moves nothing.
    func makeRoom(on track: Track, at time: Double, length: Double, excluding id: UUID? = nil) {
        guard length > 0 else { return }
        let row = ordered(track).filter { $0.id != id }
        guard let next = row.first(where: { $0.start >= time - 0.0001 }) else { return }
        let shortfall = length - (next.start - time)
        guard shortfall > 0.0001 else { return }
        for index in clips.indices
        where clips[index].track == track && clips[index].id != id && clips[index].start >= time - 0.0001 {
            clips[index].start += shortfall
        }
    }

    /// Guarantees the invariant the rest of the app relies on: clips on a row never
    /// overlap. Anything that would sit on top of its predecessor is pushed clear.
    /// Without this a clip can end up hidden under another and silently vanish from the
    /// export, which skips whatever it cannot place.
    func resolveOverlaps(on track: Track) {
        var cursor = -Double.greatestFiniteMagnitude
        for clip in ordered(track) {
            guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { continue }
            if clips[index].start < cursor - 0.0001 {
                clips[index].start = cursor
            }
            cursor = clips[index].end
        }
    }

    /// Stops a trim from running over the neighbouring clip.
    private func limitToNeighbours(_ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        let row = ordered(clip.track).filter { $0.id != id }
        if let previous = row.last(where: { $0.start <= clip.start }), clips[index].start < previous.end {
            clips[index].start = previous.end
        }
        if let next = row.first(where: { $0.start > clips[index].start }) {
            let room = next.start - clips[index].start
            if clips[index].trimmedDuration > room + 0.0001 {
                clips[index].outPoint = clips[index].inPoint + max(0.1, room)
            }
        }
    }

    /// Pulls a proposed start onto a nearby edge: the ruler's zero, the playhead, or the
    /// start or end of any other clip on either row. Without this, lining two rows up by
    /// hand is guesswork.
    func snapped(_ id: UUID, proposedStart: Double, tolerance: Double) -> Double {
        guard tolerance > 0, let clip = clips.first(where: { $0.id == id }) else { return proposedStart }
        let length = clip.trimmedDuration
        // Clips travelling with the drag are not edges to snap against.
        let moving = selectedIDs.contains(id) ? selectedIDs : [id]

        var edges: [Double] = [0, sequenceTime]
        for other in clips where !moving.contains(other.id) {
            edges.append(other.start)
            edges.append(other.end)
        }

        var best = proposedStart
        var bestDistance = tolerance
        for edge in edges {
            // Either end of the dragged clip can land on an edge.
            for candidate in [edge, edge - length] where candidate >= -tolerance {
                let distance = abs(candidate - proposedStart)
                if distance < bestDistance {
                    bestDistance = distance
                    best = max(0, candidate)
                }
            }
        }
        return best
    }


    /// The two rows of the timeline. Position pairs them: the self-view clip at index i
    /// is composited onto the main clip at index i.
    var mainClips: [Clip] { clips.filter { $0.track == .main } }
    var selfViewClips: [Clip] { clips.filter { $0.track == .selfView } }

    func clips(in track: Track) -> [Clip] {
        track == .main ? mainClips : selfViewClips
    }



    /// Keeps storage in a predictable order: every main clip, then every self-view clip.
    private func restack(main: [Clip], selfView: [Clip]) {
        clips = main + selfView
    }

    var hasBackgroundRemoval: Bool { clips.contains { $0.removeBackground } }

    // MARK: - Workspace lifecycle

    func newWorkspace() {
        guard let url = WorkspaceManager.chooseNew() else { return }
        do {
            try WorkspaceManager.prepare(url)
            open(url)
        } catch {
            message = error.localizedDescription
        }
    }

    func openWorkspace() {
        guard let url = WorkspaceManager.chooseExisting() else { return }
        open(url)
    }

    func open(_ url: URL) {
        saveTask?.cancel()
        do {
            try WorkspaceManager.prepare(url)
            let data = try ProjectFile.read(from: url)
            workspace = url
            frame = data.frame
            exportQuality = data.exportQuality
            // Default to the project's own name rather than a generic one — and replace
            // the old generic defaults, including the one from before the rename.
            let stale = ["", "VideoEditor Export", "StreamCutter Export"]
            exportName = stale.contains(data.lastExportName) ? url.lastPathComponent : data.lastExportName

            let media = WorkspaceManager.mediaFolder(url)
            clips = data.clips.map { $0.clip(mediaFolder: media) }
            positionIfNeeded()
            resolveOverlaps(on: .main)
            resolveOverlaps(on: .selfView)
            undoStack.removeAll()
            redoStack.removeAll()
            lastUndoName = nil
            refreshLibrary()
            setSelection(clips.first?.id)
            lastRecordingSummary = nil
            sequenceTime = 0
            mode = clips.isEmpty ? .record : .edit
            loadSelectedIntoPlayer()
            loadMetadata()
            invalidateSequence()

            RecentWorkspaces.remember(url)
            recents = RecentWorkspaces.valid()
            message = nil
        } catch {
            message = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func closeWorkspace() {
        saveNow()
        player.pause()
        player.replaceCurrentItem(with: nil)
        workspace = nil
        clips = []
        setSelection(nil)
        recents = RecentWorkspaces.valid()
    }

    func revealWorkspace() {
        guard let workspace else { return }
        NSWorkspace.shared.open(workspace)
    }

    // MARK: - Saving

    func scheduleSave() {
        invalidateSequence()
        guard workspace != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let workspace else { return }
        var data = ProjectData()
        data.clips = clips.map(ClipData.init)
        data.frame = frame
        data.exportQuality = exportQuality
        data.lastExportName = exportName
        do { try ProjectFile.write(data, to: workspace) }
        catch { message = "Could not save project: \(error.localizedDescription)" }
    }

    // MARK: - Clips

    func addClips(copy: Bool = true) {
        guard workspace != nil else { return }
        let urls = WorkspaceManager.chooseVideoFiles()
        guard !urls.isEmpty else { return }
        add(urls, copy: copy)
    }

    func add(_ urls: [URL], copy: Bool) {
        guard let workspace else { return }
        recordUndo("Add Clips")
        var added: [UUID] = []
        for url in urls where url.isVideoFile {
            do {
                var clip: Clip
                if copy {
                    let name = try WorkspaceManager.importCopy(url, into: workspace)
                    let destination = WorkspaceManager.mediaFolder(workspace).appendingPathComponent(name)
                    clip = Clip(path: name, isExternal: false, url: destination)
                } else {
                    clip = Clip(path: url.path, isExternal: true, url: url)
                }
                clip.track = .main
                clip.start = ordered(.main).last?.end ?? 0
                clips.append(clip)
                added.append(clip.id)
            } catch {
                message = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        restack(main: mainClips, selfView: selfViewClips)
        refreshLibrary()
        if selection == nil, let first = added.first {
            setSelection(first)
            loadSelectedIntoPlayer()
        }
        scheduleSave()
        loadMetadata()
    }

    func remove(_ id: UUID) {
        recordUndo("Delete Clip")
        clips.removeAll { $0.id == id }
        if selection == id {
            setSelection(clips.first?.id)
            loadSelectedIntoPlayer()
        }
        scheduleSave()
    }

    /// Butts a clip up against whatever precedes it on its row, closing the gap.
    func closeGapBefore(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        let previous = ordered(clip.track).last { $0.id != id && $0.start < clip.start }
        setStart(id, to: previous?.end ?? 0, undoName: "Close Gap")
    }

    /// Butts the following clip up against this one.
    func closeGapAfter(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        guard let next = ordered(clip.track).first(where: { $0.id != id && $0.start > clip.start }) else { return }
        setStart(next.id, to: clip.end, undoName: "Close Gap")
    }

    func moveToPlayhead(_ id: UUID) {
        setStart(id, to: sequenceTime, undoName: "Move Clip")
    }

    /// Packs a row end to end from zero, removing every gap.
    func closeAllGaps(on track: Track) {
        recordUndo("Close Gaps")
        var cursor = 0.0
        for clip in ordered(track) {
            guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { continue }
            clips[index].start = cursor
            cursor += clips[index].trimmedDuration
        }
        scheduleSave()
    }

    /// Sends a clip to the other row, keeping its trim and settings.
    func setTrack(_ id: UUID, to track: Track) {
        guard let index = clips.firstIndex(where: { $0.id == id }), clips[index].track != track else { return }
        recordUndo("Change Row")
        clips[index].track = track
        clips[index].start = insertionPoint(on: track, at: clips[index].start)
        resolveOverlaps(on: track)
        restack(main: mainClips, selfView: selfViewClips)
        scheduleSave()
        invalidateSequence()
    }



    /// Sets the anchor and collapses the highlight onto it.
    func setSelection(_ id: UUID?) {
        selection = id
        selectedIDs = id.map { [$0] } ?? []
    }

    func select(_ id: UUID) {
        guard selection != id || selectedIDs.count != 1 else { return }
        setSelection(id)
        loadSelectedIntoPlayer()
    }

    /// ⌘-click: add or remove one clip.
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selection == id {
                selection = selectedIDs.first
                loadSelectedIntoPlayer()
            }
        } else {
            selectedIDs.insert(id)
            selection = id
            loadSelectedIntoPlayer()
        }
    }

    /// Shift-click: everything between the anchor and this clip, along one row. Rows are
    /// separate sequences, so a range across both would not mean anything.
    func extendSelection(to id: UUID) {
        guard let target = clips.first(where: { $0.id == id }) else { return }
        guard let anchor = selection,
              let anchorClip = clips.first(where: { $0.id == anchor }),
              anchorClip.track == target.track else {
            toggleSelection(id)
            return
        }
        let row = ordered(target.track)
        guard let from = row.firstIndex(where: { $0.id == anchor }),
              let to = row.firstIndex(where: { $0.id == id }) else { return }
        selectedIDs = Set(row[min(from, to)...max(from, to)].map(\.id))
        selectedIDs.insert(anchor)
    }

    var selectedClips: [Clip] {
        clips.filter { selectedIDs.contains($0.id) }
    }

    /// Write-through binding so every inspector edit schedules an autosave.
    func binding(for id: UUID) -> Binding<Clip> {
        Binding(
            get: { self.clips.first(where: { $0.id == id }) ?? Clip(path: "", isExternal: false, url: URL(fileURLWithPath: "/")) },
            set: { updated in self.updateClip(id) { $0 = updated } })
    }

    /// The one place clips are edited, so a trim can be mirrored onto a locked partner.
    /// `undoName` of nil skips the snapshot — used mid-drag, where the first change
    /// already recorded one.
    func updateClip(_ id: UUID, undoName: String? = "Edit Clip", _ transform: (inout Clip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if let undoName { recordUndo(undoName) }
        let before = clips[index]
        transform(&clips[index])
        mirrorTrim(from: before, to: clips[index])
        limitToNeighbours(id)
        scheduleSave()
    }

    /// Trimming the head moves the clip along the timeline by the same amount, so the
    /// footage that remains stays where it was rather than sliding backwards.
    private func mirrorTrim(from before: Clip, to after: Clip) {
        let deltaIn = after.inPoint - before.inPoint
        guard abs(deltaIn) > 0.001,
              let index = clips.firstIndex(where: { $0.id == after.id }) else { return }
        clips[index].start = max(0, before.start + deltaIn)
    }



    /// Takes the files a recording session just wrote into Media/ and appends them to the
    /// timeline as one more pair: the screen on the Clip row, the webcam on the Self-View
    /// row directly beneath it.
    func addRecorded(_ session: RecordingManager.Session) {
        guard let workspace else { return }
        recordUndo("Add Recording")
        let media = WorkspaceManager.mediaFolder(workspace)

        // A take lands after everything already on the timeline, with both halves
        // starting together.
        let landing = max(ordered(.main).last?.end ?? 0, ordered(.selfView).last?.end ?? 0)
        var firstAdded: UUID?

        if let name = session.screenFile {
            var clip = Clip(path: name, isExternal: false, url: media.appendingPathComponent(name))
            clip.track = .main
            clip.start = landing
            clips.append(clip)
            firstAdded = clip.id
        }
        if let name = session.webcamFile {
            var clip = Clip(path: name, isExternal: false, url: media.appendingPathComponent(name))
            // A webcam take with no screen alongside it is just an ordinary clip.
            clip.track = session.screenFile == nil ? .main : .selfView
            clip.start = landing
            clips.append(clip)
            if firstAdded == nil { firstAdded = clip.id }
        }

        if let firstAdded, selection == nil { setSelection(firstAdded); loadSelectedIntoPlayer() }
        lastRecordingSummary = [session.screenFile, session.webcamFile]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        refreshLibrary()
        scheduleSave()
        loadMetadata()
    }

    // MARK: - Metadata + thumbnails

    struct LoadedMeta: @unchecked Sendable {
        let id: UUID
        let duration: Double
        let size: CGSize
        let thumbnail: NSImage?
        let missing: Bool
    }

    func loadMetadata() {
        let pending = clips.filter { !$0.isLoaded }
        guard !pending.isEmpty else { return }
        Task {
            for chunk in stride(from: 0, to: pending.count, by: 6).map({ Array(pending[$0..<min($0 + 6, pending.count)]) }) {
                await withTaskGroup(of: LoadedMeta.self) { group in
                    for clip in chunk {
                        group.addTask { await AppModel.meta(for: clip) }
                    }
                    for await meta in group { self.apply(meta) }
                }
            }
        }
    }

    private func apply(_ meta: LoadedMeta) {
        guard let index = clips.firstIndex(where: { $0.id == meta.id }) else { return }
        clips[index].isLoaded = true
        clips[index].isMissing = meta.missing
        guard !meta.missing else { return }
        clips[index].duration = meta.duration
        clips[index].naturalSize = meta.size
        clips[index].thumbnail = meta.thumbnail
        if clips[index].outPoint < 0 || clips[index].outPoint > meta.duration {
            clips[index].outPoint = meta.duration
        }
        clips[index].inPoint = max(0, min(clips[index].inPoint, clips[index].outPoint))

        if pendingInsertions.remove(clips[index].id) != nil {
            let inserted = clips[index]
            makeRoom(on: inserted.track, at: inserted.start, length: inserted.trimmedDuration, excluding: inserted.id)
            resolveOverlaps(on: inserted.track)
        }
        if clips[index].id == selection, player.currentItem == nil {
            loadSelectedIntoPlayer()
        }
        invalidateSequence()
    }

    nonisolated private static func meta(for clip: Clip) async -> LoadedMeta {
        guard FileManager.default.fileExists(atPath: clip.url.path) else {
            return LoadedMeta(id: clip.id, duration: 0, size: .zero, thumbnail: nil, missing: true)
        }
        let asset = AVURLAsset(url: clip.url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            return LoadedMeta(id: clip.id, duration: 0, size: .zero, thumbnail: nil, missing: true)
        }

        var size = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            size = Geometry.displayedSize(natural: loaded.0, preferred: loaded.1)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let at = CMTime(seconds: min(1.0, duration / 2), preferredTimescale: 600)
        var thumbnail: NSImage?
        if let cgImage = try? await generator.image(at: at).image {
            thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return LoadedMeta(id: clip.id, duration: duration, size: size, thumbnail: thumbnail, missing: false)
    }

    // MARK: - Playback

    func loadSelectedIntoPlayer() {
        guard previewMode == .clip else { return }
        player.pause()
        isPlaying = false
        guard let clip = selectedClip, !clip.isMissing else {
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: clip.url))
        seek(to: clip.inPoint)
    }

    func playPause() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if previewMode == .sequence {
            if sequenceTime >= sequenceDuration - 0.05 { seekSequence(to: 0) }
            player.play()
            isPlaying = true
        } else {
            if let clip = selectedClip, currentTime >= clip.resolvedOut - 0.05 {
                seek(to: clip.inPoint)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        currentTime = max(0, seconds)
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setScrubbing(_ active: Bool) {
        scrubbing = active
        if active, isPlaying { player.pause(); isPlaying = false }
    }

    func step(_ seconds: Double) {
        if previewMode == .sequence {
            seekSequence(to: sequenceTime + seconds)
            return
        }
        guard let clip = selectedClip else { return }
        seek(to: min(max(0, currentTime + seconds), clip.duration))
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if previewMode == .sequence {
            if !scrubbing { sequenceTime = min(seconds, max(sequenceDuration, 0)) }
            if isPlaying, sequenceDuration > 0, seconds >= sequenceDuration - 0.02 {
                player.pause()
                isPlaying = false
            }
            return
        }
        if !scrubbing { currentTime = seconds }
        // Stop at the out point so playback previews the trim.
        if isPlaying, let clip = selectedClip, clip.resolvedOut > 0, seconds >= clip.resolvedOut {
            player.pause()
            isPlaying = false
            seek(to: clip.resolvedOut)
        }
    }

    // MARK: - Trim helpers

    func setInPointAtPlayhead() {
        guard let id = selection else { return }
        updateClip(id) { $0.inPoint = min(self.currentTime, max(0, $0.resolvedOut - 0.1)) }
    }

    func setOutPointAtPlayhead() {
        guard let id = selection else { return }
        updateClip(id) { $0.outPoint = max(self.currentTime, $0.inPoint + 0.1) }
    }

    func resetTrim() {
        guard let id = selection else { return }
        updateClip(id) {
            $0.inPoint = 0
            $0.outPoint = $0.duration
        }
    }

    // MARK: - Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String { undoStack.last?.name ?? "" }
    var redoActionName: String { redoStack.last?.name ?? "" }

    /// Snapshots the timeline before a change. Repeated changes of the same kind within a
    /// second collapse into one step, so dragging a trim handle is a single undo rather
    /// than a hundred.
    func recordUndo(_ name: String) {
        let now = Date()
        if name == lastUndoName, now.timeIntervalSince(lastUndoAt) < 1.0 {
            lastUndoAt = now
            return
        }
        lastUndoName = name
        lastUndoAt = now
        undoStack.append((name, clips, selection))
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        redoStack.removeAll()
    }

    /// ⌘Z belongs to whatever is focused: if a text field can undo, let it.
    func performUndo() {
        guard !AppModel.forwardToTextEditor(undo: true) else { return }
        undo()
    }

    func performRedo() {
        guard !AppModel.forwardToTextEditor(undo: false) else { return }
        redo()
    }

    private static func forwardToTextEditor(undo: Bool) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              let manager = editor.undoManager else { return false }
        if undo {
            guard manager.canUndo else { return false }
            manager.undo()
        } else {
            guard manager.canRedo else { return false }
            manager.redo()
        }
        return true
    }

    /// Deletes everything highlighted, as one undo step.
    func deleteSelected() {
        let ids = selectedIDs.isEmpty ? Set([selection].compactMap { $0 }) : selectedIDs
        delete(ids)
    }

    func delete(_ ids: Set<UUID>, undoName: String? = nil) {
        guard !ids.isEmpty else { return }
        recordUndo(undoName ?? (ids.count > 1 ? "Delete \(ids.count) Clips" : "Delete Clip"))
        clips.removeAll { ids.contains($0.id) }
        setSelection(clips.first?.id)
        if previewMode == .clip { loadSelectedIntoPlayer() }
        scheduleSave()
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append((step.name, clips, selection))
        restore(step)
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append((step.name, clips, selection))
        restore(step)
    }

    private func restore(_ step: (name: String, clips: [Clip], selection: UUID?)) {
        // A fresh snapshot must not be folded into the step we just came from.
        lastUndoName = nil
        clips = step.clips
        if let id = step.selection, clips.contains(where: { $0.id == id }) {
            setSelection(id)
        } else {
            setSelection(clips.first?.id)
        }
        saveNow()
        if previewMode == .clip { loadSelectedIntoPlayer() }
        invalidateSequence()
    }

    // MARK: - Workspace library

    /// Lists what is actually in Media/ and Exports/, so the browser shows the folder
    /// rather than just what the timeline happens to reference.
    func refreshLibrary() {
        guard let workspace else {
            mediaFiles = []
            exportFiles = []
            return
        }
        mediaFiles = Self.videoFiles(in: WorkspaceManager.mediaFolder(workspace))
        exportFiles = Self.videoFiles(in: WorkspaceManager.exportsFolder(workspace))
    }

    private static func videoFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter(\.isVideoFile)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Filenames the timeline already uses, so the browser can mark them.
    var usedMediaNames: Set<String> {
        Set(clips.filter { !$0.isExternal }.map(\.path))
    }

    /// Puts a file that is already inside Media/ onto the timeline, without copying it.
    /// `at` is where it lands on the ruler; nil means after everything else on that row.
    @discardableResult
    func addFromLibrary(_ url: URL, to track: Track, at start: Double? = nil) -> UUID? {
        guard let workspace else { return nil }
        let media = WorkspaceManager.mediaFolder(workspace)
        guard url.deletingLastPathComponent().standardizedFileURL == media.standardizedFileURL else {
            add([url], copy: true)
            return nil
        }
        recordUndo("Add Clip")
        var clip = Clip(path: url.lastPathComponent, isExternal: false, url: url)
        clip.track = track
        clip.start = start.map { insertionPoint(on: track, at: $0) } ?? (ordered(track).last?.end ?? 0)
        clips.append(clip)
        // Everything downstream slides right to make room; the new clip's real length
        // arrives with its metadata, so the gap is opened again once it is known.
        pendingInsertions.insert(clip.id)
        setSelection(clip.id)
        scheduleSave()
        loadMetadata()
        return clip.id
    }

    /// Handles a drop of file paths onto a timeline row, from the workspace browser or
    /// from Finder.
    func dropFiles(_ urls: [URL], to track: Track, at start: Double?) {
        guard let workspace else { return }
        let media = WorkspaceManager.mediaFolder(workspace).standardizedFileURL
        var cursor = start
        for url in urls where url.isVideoFile {
            var landed: UUID?
            if url.deletingLastPathComponent().standardizedFileURL == media {
                landed = addFromLibrary(url, to: track, at: cursor)
            } else {
                // From outside the workspace: copy it in first, as Add Clip would.
                guard let name = try? WorkspaceManager.importCopy(url, into: workspace) else { continue }
                let copied = WorkspaceManager.mediaFolder(workspace).appendingPathComponent(name)
                landed = addFromLibrary(copied, to: track, at: cursor)
                refreshLibrary()
            }
            if let landed, let clip = clips.first(where: { $0.id == landed }) {
                cursor = clip.end
            }
        }
    }

    // MARK: - Sequence preview

    /// Rebuilds the composition the preview player runs on, a beat after the last edit.
    func invalidateSequence() {
        guard previewMode == .sequence else { return }
        sequenceTask?.cancel()
        sequenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.rebuildSequence()
        }
    }

    func setPreviewMode(_ newMode: PreviewMode) {
        guard previewMode != newMode else { return }
        player.pause()
        isPlaying = false
        previewMode = newMode
        if newMode == .sequence {
            Task { await rebuildSequence() }
        } else {
            loadSelectedIntoPlayer()
        }
    }

    func rebuildSequence() async {
        guard previewMode == .sequence else { return }
        // Background removal is far too slow to run per frame while scrubbing; it is
        // applied at export instead. The preview still shows the picture-in-picture.
        let snapshot = clips.map { clip -> Clip in
            var copy = clip
            copy.removeBackground = false
            return copy
        }
        guard snapshot.contains(where: { $0.track == .main && !$0.isMissing }) else {
            player.replaceCurrentItem(with: nil)
            sequencePlan = nil
            sequenceDuration = 0
            sequenceTime = 0
            return
        }

        do {
            // With the guide on, the preview shows the whole source frame and the crop is
            // drawn over it; otherwise the preview is framed exactly as the export will be.
            let previewFrame = showCropGuide ? FrameSpec() : frame
            let plan = try await TimelineBuilder.build(clips: snapshot, frame: previewFrame,
                                                        overlayBounds: showCropGuide ? guideOverlayBounds() : nil)
            guard previewMode == .sequence else { return }
            sequenceSourceSize = plan.sourceSize
            let resumeAt = min(sequenceTime, plan.duration.seconds)
            // AVPlayerItem wants immutable snapshots: handing it the mutable objects
            // plays back as a black frame.
            let asset = plan.composition.copy() as! AVComposition
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = (plan.videoComposition.copy() as! AVVideoComposition)
            sequencePlan = plan
            sequenceDuration = plan.duration.seconds
            player.replaceCurrentItem(with: item)
            seekSequence(to: resumeAt)
        } catch {
            sequencePlan = nil
            sequenceDuration = 0
            sequenceSourceSize = .zero
            player.replaceCurrentItem(with: nil)
        }
    }

    /// With the guide showing, the self-view is placed inside the surviving crop so the
    /// preview matches the export.
    private func guideOverlayBounds() -> CGRect? {
        guard frame.cropsAnything else { return nil }
        var width: CGFloat = 0, height: CGFloat = 0
        for clip in mainClips where !clip.isMissing {
            width = max(width, clip.naturalSize.width)
            height = max(height, clip.naturalSize.height)
        }
        guard width > 0, height > 0 else { return nil }
        let source = evenSize(CGSize(width: width, height: height))
        let render = frame.preset.outputSize(source: source)
        return Geometry.visibleSourceRect(source: source, render: render,
                                          mode: frame.mode, position: frame.position)
    }

    /// Debug dump of the composition behind the preview.
    func planReport() -> String {
        guard let plan = sequencePlan else { return "plan: none" }
        var lines = ["plan render: \(Int(plan.renderSize.width))x\(Int(plan.renderSize.height))",
                     "plan duration: \(String(format: "%.2f", plan.duration.seconds))",
                     "instructions: \(plan.videoComposition.instructions.count)",
                     "customCompositor: \(plan.usesCustomCompositor)",
                     "frameDuration: \(plan.videoComposition.frameDuration.seconds)"]
        for track in plan.composition.tracks {
            lines.append("track \(track.trackID) \(track.mediaType.rawValue) "
                         + "range \(String(format: "%.2f", track.timeRange.start.seconds))"
                         + "..\(String(format: "%.2f", track.timeRange.end.seconds)) "
                         + "segments \(track.segments.count)")
        }
        for (index, instruction) in plan.videoComposition.instructions.enumerated() {
            let ids = (instruction.requiredSourceTrackIDs ?? []).map { "\($0)" }.joined(separator: ",")
            lines.append("instr \(index) "
                         + "\(String(format: "%.2f", instruction.timeRange.start.seconds))"
                         + "..\(String(format: "%.2f", instruction.timeRange.end.seconds)) "
                         + "tracks [\(ids)] passthrough \(instruction.passthroughTrackID)")
        }
        return lines.joined(separator: "\n")
    }

    func seekSequence(to seconds: Double) {
        sequenceTime = max(0, min(seconds, max(sequenceDuration, 0)))
        player.seek(to: CMTime(seconds: sequenceTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Start time of a clip on the timeline.
    func sequenceStart(of id: UUID) -> Double {
        clips.first { $0.id == id }?.start ?? 0
    }

    // MARK: - Splitting

    /// A clip on this row that the playhead is comfortably inside.
    private func splittable(on track: Track, at time: Double) -> Clip? {
        guard let found = clip(on: track, at: time) else { return nil }
        let offset = time - found.start
        guard offset > 0.08, offset < found.trimmedDuration - 0.08 else { return nil }
        return found
    }

    var canSplit: Bool {
        guard previewMode == .sequence else { return false }
        return splittable(on: .main, at: sequenceTime) != nil
            || splittable(on: .selfView, at: sequenceTime) != nil
    }

    /// Cuts whatever the playhead is inside, on both rows — a razor across the timeline.
    func splitAtPlayhead() {
        guard previewMode == .sequence else {
            message = "Switch the preview to Sequence to split at the playhead."
            return
        }
        let time = sequenceTime
        let targets = [Track.main, Track.selfView].compactMap { splittable(on: $0, at: time) }
        guard !targets.isEmpty else {
            message = "Move the playhead inside a clip first."
            return
        }

        recordUndo(targets.count > 1 ? "Split Clips" : "Split Clip")
        var newSelection: UUID?
        for target in targets {
            guard let index = clips.firstIndex(where: { $0.id == target.id }) else { continue }
            let cut = target.inPoint + (time - target.start)
            var tail = target.duplicated()
            tail.inPoint = cut
            tail.outPoint = target.resolvedOut
            tail.start = time
            clips[index].outPoint = cut
            clips.append(tail)
            if target.track == .main { newSelection = tail.id }
            else if newSelection == nil { newSelection = tail.id }
        }
        if let newSelection { setSelection(newSelection) }
        scheduleSave()
    }

    // MARK: - Export


    func startExport() {
        guard let workspace else { return }
        saveNow()
        exporter.export(clips: clips, workspace: workspace, name: exportName,
                        quality: exportQuality, frame: frame)
    }
}
