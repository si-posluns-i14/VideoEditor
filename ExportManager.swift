import Foundation
import AVFoundation
import SwiftUI

enum ExportError: LocalizedError {
    case noClips
    case compositionFailed
    case noVideoTrack(String)
    case noCompatiblePreset

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no usable clips to export."
        case .compositionFailed: return "Could not build the composition."
        case .noVideoTrack(let name): return "\"\(name)\" has no video track."
        case .noCompatiblePreset: return "No export preset is compatible with these clips."
        }
    }
}

// MARK: - Turning the clip list into an AVMutableComposition

struct RenderPlan {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let needsAlpha: Bool
    let usesCustomCompositor: Bool
    /// The natural frame of the clips, before any aspect-ratio re-framing.
    let sourceSize: CGSize
    let renderSize: CGSize
    let duration: CMTime
}

enum TimelineBuilder {

    private struct Source {
        let clip: Clip
        /// `AVAssetTrack.asset` is a weak reference, so the asset has to be held here for
        /// as long as its tracks are in use — otherwise `insertTimeRange` fails with a
        /// bare AVFoundation "unknown error".
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let naturalSize: CGSize
        let transform: CGAffineTransform
        let fps: Float
        let trimStart: Double
        let trimDuration: Double
    }

    /// A clip once it has been put on the timeline, with the stretch of the finished
    /// video it occupies.
    private struct Placed {
        let source: Source
        let range: CMTimeRange
        var start: Double { range.start.seconds }
        var end: Double { range.end.seconds }
    }

    private static func load(_ clip: Clip) async throws -> Source {
        let asset = AVURLAsset(url: clip.url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack(clip.displayName)
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let assetDuration = try await asset.load(.duration).seconds
        let (naturalSize, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)

        let start = max(0, min(clip.inPoint, assetDuration))
        let end = clip.outPoint < 0 ? assetDuration : min(clip.outPoint, assetDuration)
        return Source(clip: clip, asset: asset, video: video, audio: audio,
                      naturalSize: naturalSize, transform: transform, fps: fps,
                      trimStart: start, trimDuration: max(0, end - start))
    }

    /// `overlayBounds` confines the self-view to part of the frame — used by the crop
    /// guide, which renders the whole source frame but must still show the overlay where
    /// the cropped export will put it.
    static func build(clips: [Clip], frame: FrameSpec = FrameSpec(),
                      overlayBounds: CGRect? = nil) async throws -> RenderPlan {
        let mainRow = clips.filter { $0.track == .main && !$0.isMissing }.sorted { $0.start < $1.start }
        let selfRow = clips.filter { $0.track == .selfView && !$0.isMissing }.sorted { $0.start < $1.start }
        guard !mainRow.isEmpty || !selfRow.isEmpty else { throw ExportError.noClips }

        let composition = AVMutableComposition()
        guard let mainVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.compositionFailed }
        let selfVideo = selfRow.isEmpty
            ? nil
            : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)

        // Audio tracks are created only once there is real audio to put in them: a
        // composition track holding nothing but empty ranges fails the export outright.
        var mainAudio: AVMutableCompositionTrack?
        var selfAudio: AVMutableCompositionTrack?

        /// Lays a row onto its track at each clip's own start time, skipping anything
        /// that would overlap what came before.
        func place(_ row: [Clip], video: AVMutableCompositionTrack?,
                   audio: inout AVMutableCompositionTrack?) async throws -> [Placed] {
            guard let video else { return [] }
            var placed: [Placed] = []
            var lastEnd = -Double.greatestFiniteMagnitude
            for clip in row {
                let source = try await load(clip)
                guard source.trimDuration > 0.02 else { continue }
                // The model keeps a row free of overlaps; if one slips through anyway,
                // butt the clip up against its predecessor rather than dropping it, so
                // nothing silently disappears from the export.
                let begin = max(max(0, clip.start), lastEnd == -Double.greatestFiniteMagnitude ? 0 : lastEnd)

                let sourceRange = CMTimeRange(start: CMTime(seconds: source.trimStart, preferredTimescale: 600),
                                              duration: CMTime(seconds: source.trimDuration, preferredTimescale: 600))
                let at = CMTime(seconds: begin, preferredTimescale: 600)
                try video.insertTimeRange(sourceRange, of: source.video, at: at)
                if let track = source.audio {
                    if audio == nil {
                        audio = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try? audio?.insertTimeRange(sourceRange, of: track, at: at)
                }
                placed.append(Placed(source: source,
                                     range: CMTimeRange(start: at, duration: sourceRange.duration)))
                lastEnd = begin + sourceRange.duration.seconds
            }
            return placed
        }

        let mainPlaced = try await place(mainRow, video: mainVideo, audio: &mainAudio)
        let selfPlaced = try await place(selfRow, video: selfVideo, audio: &selfAudio)
        guard !mainPlaced.isEmpty || !selfPlaced.isEmpty else { throw ExportError.noClips }

        // Render frame: the largest displayed size among the clips.
        var width: CGFloat = 0, height: CGFloat = 0
        for placed in mainPlaced {
            let displayed = Geometry.displayedSize(natural: placed.source.naturalSize,
                                                   preferred: placed.source.transform)
            width = max(width, displayed.width)
            height = max(height, displayed.height)
        }
        if width < 1 || height < 1 {
            for placed in selfPlaced {
                let displayed = Geometry.displayedSize(natural: placed.source.naturalSize,
                                                       preferred: placed.source.transform)
                width = max(width, displayed.width)
                height = max(height, displayed.height)
            }
        }
        let sourceSize = evenSize(CGSize(width: max(width, 16), height: max(height, 16)))
        let renderSize = frame.preset.outputSize(source: sourceSize)
        let overlayFrame = overlayBounds ?? CGRect(origin: .zero, size: renderSize)

        let present = clips.filter { !$0.isMissing }
        // Rounded corners need masking, which only the Core Image path can do.
        let usesCustomCompositor = present.contains { $0.removeBackground }
            || present.contains { $0.track == .selfView && $0.pipCornerRadius > 0.001 }
        let needsAlpha = present.contains { $0.removeBackground && $0.backgroundMode == .transparent }

        // Cut the timeline at every clip boundary on either row; within each slice the
        // cast does not change.
        let total = composition.duration.seconds
        var marks: Set<Double> = [0, total]
        for placed in mainPlaced + selfPlaced {
            marks.insert(placed.start)
            marks.insert(placed.end)
        }
        let boundaries = marks.filter { $0 >= -0.0001 && $0 <= total + 0.0001 }.sorted()

        var instructions: [any AVVideoCompositionInstructionProtocol] = []
        for (index, from) in boundaries.enumerated() where index + 1 < boundaries.count {
            let to = boundaries[index + 1]
            guard to - from > 0.005 else { continue }
            let middle = (from + to) / 2
            let activeMain = mainPlaced.first { middle >= $0.start && middle < $0.end }
            let activeSelf = selfPlaced.first { middle >= $0.start && middle < $0.end }

            let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                    duration: CMTime(seconds: to - from, preferredTimescale: 600))

            if usesCustomCompositor {
                var mainLayer: SCInstruction.Layer?
                if let source = activeMain?.source {
                    mainLayer = SCInstruction.Layer(
                        trackID: mainVideo.trackID,
                        transform: Geometry.toCoreImage(
                            Geometry.frameTransform(natural: source.naturalSize,
                                                    preferred: source.transform,
                                                    render: renderSize,
                                                    mode: frame.mode,
                                                    position: frame.position),
                            sourceHeight: source.naturalSize.height,
                            renderHeight: renderSize.height),
                        removeBackground: source.clip.removeBackground,
                        backgroundColor: source.clip.backgroundMode == .transparent
                            ? nil : source.clip.backgroundColor.ciColor,
                        quality: source.clip.segmentationQuality.visionLevel,
                        segmenterKey: "main-\(source.clip.id.uuidString)")
                }
                var overlayLayer: SCInstruction.Layer?
                if let source = activeSelf?.source, let track = selfVideo {
                    overlayLayer = SCInstruction.Layer(
                        trackID: track.trackID,
                        transform: Geometry.toCoreImage(
                            Geometry.overlayTransform(natural: source.naturalSize,
                                                      preferred: source.transform,
                                                      bounds: overlayFrame,
                                                      fraction: CGFloat(source.clip.pipScale),
                                                      position: CGPoint(x: source.clip.pipX,
                                                                        y: source.clip.pipY)),
                            sourceHeight: source.naturalSize.height,
                            renderHeight: renderSize.height),
                        removeBackground: source.clip.removeBackground,
                        backgroundColor: source.clip.backgroundMode == .transparent
                            ? nil : source.clip.backgroundColor.ciColor,
                        quality: source.clip.segmentationQuality.visionLevel,
                        segmenterKey: "self-\(source.clip.id.uuidString)",
                        cornerRadius: source.clip.pipCornerRadius)
                }
                instructions.append(SCInstruction(timeRange: range,
                                                  main: mainLayer,
                                                  overlay: overlayLayer,
                                                  transparentBackdrop: needsAlpha))
            } else {
                var main: SegmentTrack?
                if let source = activeMain?.source {
                    main = SegmentTrack(track: mainVideo,
                                        naturalSize: source.naturalSize,
                                        preferredTransform: source.transform)
                }
                var overlay: SegmentTrack?
                if let source = activeSelf?.source, let track = selfVideo {
                    overlay = SegmentTrack(track: track,
                                           naturalSize: source.naturalSize,
                                           preferredTransform: source.transform,
                                           scale: CGFloat(source.clip.pipScale),
                                           position: CGPoint(x: source.clip.pipX, y: source.clip.pipY))
                }
                instructions.append(PiPCompositor.instruction(timeRange: range,
                                                              main: main,
                                                              overlay: overlay,
                                                              renderSize: renderSize,
                                                              overlayBounds: overlayFrame,
                                                              frame: frame,
                                                              transparent: needsAlpha))
            }
        }

        guard !instructions.isEmpty else { throw ExportError.noClips }

        // Drop any track that ended up with nothing in it.
        for track in composition.tracks where track.timeRange.duration.seconds <= 0 {
            composition.removeTrack(track)
        }

        // The instructions must tile the composition exactly — start at zero, leave no
        // gaps, and finish on its last frame. Rounding drift between the accumulated
        // boundaries and the tracks' own timing is enough that an export or an image
        // generator shrugs it off while AVPlayer treats the composition as invalid and
        // renders nothing at all.
        normalise(&instructions, toCover: composition.duration)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let rates = (mainPlaced + selfPlaced).map(\.source.fps)
        let fps = max(1, min(60, rates.max() ?? 30))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        if usesCustomCompositor {
            videoComposition.customVideoCompositorClass = BackgroundRemovalCompositor.self
        }
        videoComposition.instructions = instructions

        return RenderPlan(composition: composition,
                          videoComposition: videoComposition,
                          needsAlpha: needsAlpha,
                          usesCustomCompositor: usesCustomCompositor,
                          sourceSize: sourceSize,
                          renderSize: renderSize,
                          duration: composition.duration)
    }

    /// Stretches the instruction list so it covers `total` with no gaps or overlaps.
    private static func normalise(_ instructions: inout [any AVVideoCompositionInstructionProtocol],
                                  toCover total: CMTime) {
        guard total.seconds > 0, !instructions.isEmpty else { return }
        var previousEnd = CMTime.zero
        for (index, instruction) in instructions.enumerated() {
            let isLast = index == instructions.count - 1
            var end = isLast ? total : instruction.timeRange.end
            if end <= previousEnd { end = isLast ? total : previousEnd }
            let range = CMTimeRange(start: previousEnd, end: max(end, previousEnd))
            if let mutable = instruction as? AVMutableVideoCompositionInstruction {
                mutable.timeRange = range
            } else if let custom = instruction as? SCInstruction {
                custom.timeRange = range
            }
            previousEnd = range.end
        }
    }
}

// MARK: - Driving AVAssetExportSession

@MainActor
final class ExportManager: ObservableObject {

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published var resultURL: URL?
    @Published var errorMessage: String?

    private var session: AVAssetExportSession?
    private var ticker: Timer?

    func export(clips: [Clip], workspace: URL, name: String, quality: ExportQuality, frame: FrameSpec) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        resultURL = nil
        errorMessage = nil
        statusText = "Preparing…"

        Task {
            do {
                let plan = try await TimelineBuilder.build(clips: clips, frame: frame)

                let preset: String
                let fileType: AVFileType
                let ext: String
                if plan.needsAlpha {
                    preset = AVAssetExportPresetAppleProRes4444LPCM
                    fileType = .mov
                    ext = "mov"
                } else {
                    preset = quality.preset
                    fileType = .mp4
                    ext = "mp4"
                }

                let available = AVAssetExportSession.exportPresets(compatibleWith: plan.composition)
                let chosen = available.contains(preset) ? preset : AVAssetExportPresetHighestQuality
                guard let session = AVAssetExportSession(asset: plan.composition, presetName: chosen) else {
                    throw ExportError.noCompatiblePreset
                }

                let output = WorkspaceManager.uniqueExportURL(workspace: workspace,
                                                              name: name.isEmpty ? "Export" : name,
                                                              ext: ext)
                session.outputURL = output
                session.outputFileType = fileType
                session.videoComposition = plan.videoComposition
                session.shouldOptimizeForNetworkUse = !plan.needsAlpha
                self.session = session

                statusText = plan.usesCustomCompositor
                    ? "Exporting with background removal — this is slower than a normal export."
                    : "Exporting…"

                startTicker(session)
                await withCheckedContinuation { continuation in
                    session.exportAsynchronously { continuation.resume() }
                }
                stopTicker()

                switch session.status {
                case .completed:
                    progress = 1
                    resultURL = output
                    statusText = "Exported to \(output.lastPathComponent)"
                case .cancelled:
                    statusText = "Export cancelled."
                default:
                    errorMessage = session.error?.localizedDescription ?? "Export failed."
                    statusText = ""
                }
            } catch {
                stopTicker()
                errorMessage = error.localizedDescription
                statusText = ""
            }
            isExporting = false
            session = nil
        }
    }

    func cancel() {
        session?.cancelExport()
        stopTicker()
    }

    private func startTicker(_ session: AVAssetExportSession) {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.progress = Double(session.progress)
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
