import Foundation
import AppKit
import AVFoundation

/// The timeline has two rows. "Clip" is what fills the frame; "Self-View" is the webcam,
/// composited into a corner of the Clip sitting at the same position in the sequence.
enum Track: String, Codable, CaseIterable, Identifiable {
    case main, selfView
    var id: String { rawValue }
    var label: String { self == .main ? "Clip" : "Self-View" }
}

/// Quick placements for the self-view. The stored position is free; these just set it.
enum PiPCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    var position: CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: 0, y: 0)
        case .topRight:    return CGPoint(x: 1, y: 0)
        case .bottomLeft:  return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }

    var symbol: String {
        switch self {
        case .topLeft:     return "arrow.up.left"
        case .topRight:    return "arrow.up.right"
        case .bottomLeft:  return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum PiPSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Overlay width as a fraction of the render width.
    var fraction: CGFloat {
        switch self {
        case .small: return 0.20
        case .medium: return 0.28
        case .large: return 0.36
        }
    }
}

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case solid, transparent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "Solid colour"
        case .transparent: return "Transparent (ProRes 4444 .mov)"
        }
    }
}

enum SegmentationQuality: String, Codable, CaseIterable, Identifiable {
    case balanced, accurate
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// MARK: - A clip in the timeline

struct Clip: Identifiable {
    let id: UUID
    /// Filename relative to the workspace's `Media/` folder, or an absolute path for
    /// reference-only clips.
    var path: String
    var isExternal: Bool

    // Loaded at runtime, never persisted
    var url: URL
    var duration: Double = 0
    var naturalSize: CGSize = .zero
    var thumbnail: NSImage?
    var isMissing = false
    var isLoaded = false

    // Persisted editing state
    var track: Track = .main
    /// Where the clip sits on the timeline, in seconds. The two rows are independent
    /// lanes on one ruler: clips may be moved freely and may leave gaps.
    /// Negative means "not positioned yet" — a project from before free positioning.
    var start: Double = 0
    var inPoint: Double = 0
    /// Negative means "to the end of the clip".
    var outPoint: Double = -1
    /// Self-view placement inside the output frame: 0…1 on each axis, and the overlay's
    /// width as a fraction of the frame. Free rather than four fixed corners, so it can
    /// be nudged clear of whatever is underneath.
    var pipX: Double = 1
    var pipY: Double = 1
    var pipScale: Double = 0.28
    /// Corner rounding for the self-view, as a fraction of its shorter side. 0 is square.
    var pipCornerRadius: Double = 0
    var removeBackground = false
    var backgroundMode: BackgroundMode = .solid
    var backgroundColor = RGBAColor()
    var segmentationQuality: SegmentationQuality = .balanced

    var displayName: String { (path as NSString).lastPathComponent }

    var resolvedOut: Double { outPoint < 0 ? duration : min(outPoint, duration) }
    var trimmedDuration: Double { max(0, resolvedOut - inPoint) }
    var end: Double { start + trimmedDuration }

    init(id: UUID = UUID(), path: String, isExternal: Bool, url: URL) {
        self.id = id
        self.path = path
        self.isExternal = isExternal
        self.url = url
    }

    /// The same clip under a fresh identity — used when splitting one clip into two.
    func duplicated() -> Clip {
        var copy = Clip(path: path, isExternal: isExternal, url: url)
        copy.duration = duration
        copy.naturalSize = naturalSize
        copy.thumbnail = thumbnail
        copy.isMissing = isMissing
        copy.isLoaded = isLoaded
        copy.track = track
        copy.start = start
        copy.inPoint = inPoint
        copy.outPoint = outPoint
        copy.pipX = pipX
        copy.pipY = pipY
        copy.pipScale = pipScale
        copy.pipCornerRadius = pipCornerRadius
        copy.removeBackground = removeBackground
        copy.backgroundMode = backgroundMode
        copy.backgroundColor = backgroundColor
        copy.segmentationQuality = segmentationQuality
        return copy
    }
}

// MARK: - On-disk representation

struct ClipData: Codable {
    var id: UUID
    var file: String
    var external: Bool
    var track: Track
    var start: Double?
    var inPoint: Double
    var outPoint: Double
    var pipX: Double
    var pipY: Double
    var pipScale: Double
    var pipCornerRadius: Double
    var removeBackground: Bool
    var backgroundMode: BackgroundMode
    var backgroundColor: RGBAColor
    var segmentationQuality: SegmentationQuality

    enum CodingKeys: String, CodingKey {
        case id, file, external, track, start, inPoint, outPoint
        case pipX, pipY, pipScale, pipCornerRadius
        case removeBackground, backgroundMode, backgroundColor, segmentationQuality
        /// Before the overlay could be placed freely it was one of four corners and
        /// three sizes.
        case pipCorner, pipSize
        /// Projects written before the two-track timeline stored a role here.
        case pipRole
    }

    init(_ clip: Clip) {
        id = clip.id
        file = clip.path
        external = clip.isExternal
        track = clip.track
        start = clip.start
        inPoint = clip.inPoint
        outPoint = clip.outPoint
        pipX = clip.pipX
        pipY = clip.pipY
        pipScale = clip.pipScale
        pipCornerRadius = clip.pipCornerRadius
        removeBackground = clip.removeBackground
        backgroundMode = clip.backgroundMode
        backgroundColor = clip.backgroundColor
        segmentationQuality = clip.segmentationQuality
    }

    /// Written by hand because `CodingKeys` carries the legacy `pipRole` key, which has
    /// no matching property and so blocks the synthesised encoder.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(file, forKey: .file)
        try container.encode(external, forKey: .external)
        try container.encode(track, forKey: .track)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encode(inPoint, forKey: .inPoint)
        try container.encode(outPoint, forKey: .outPoint)
        try container.encode(pipX, forKey: .pipX)
        try container.encode(pipY, forKey: .pipY)
        try container.encode(pipScale, forKey: .pipScale)
        try container.encode(pipCornerRadius, forKey: .pipCornerRadius)
        try container.encode(removeBackground, forKey: .removeBackground)
        try container.encode(backgroundMode, forKey: .backgroundMode)
        try container.encode(backgroundColor, forKey: .backgroundColor)
        try container.encode(segmentationQuality, forKey: .segmentationQuality)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        file = try container.decode(String.self, forKey: .file)
        external = try container.decodeIfPresent(Bool.self, forKey: .external) ?? false
        inPoint = try container.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try container.decodeIfPresent(Double.self, forKey: .outPoint) ?? -1

        if let stored = try container.decodeIfPresent(Track.self, forKey: .track) {
            track = stored
        } else if let legacyRole = try container.decodeIfPresent(String.self, forKey: .pipRole) {
            track = legacyRole == "overlay" ? .selfView : .main
        } else {
            track = .main
        }

        // Absent in projects written before clips could be positioned freely; the app
        // lays those out sequentially on open.
        start = try container.decodeIfPresent(Double.self, forKey: .start)
        if let x = try container.decodeIfPresent(Double.self, forKey: .pipX),
           let y = try container.decodeIfPresent(Double.self, forKey: .pipY) {
            pipX = x
            pipY = y
        } else {
            let corner = try container.decodeIfPresent(PiPCorner.self, forKey: .pipCorner) ?? .bottomRight
            pipX = corner.position.x
            pipY = corner.position.y
        }
        pipCornerRadius = try container.decodeIfPresent(Double.self, forKey: .pipCornerRadius) ?? 0
        if let scale = try container.decodeIfPresent(Double.self, forKey: .pipScale) {
            pipScale = scale
        } else {
            pipScale = Double((try container.decodeIfPresent(PiPSize.self, forKey: .pipSize) ?? .medium).fraction)
        }
        removeBackground = try container.decodeIfPresent(Bool.self, forKey: .removeBackground) ?? false
        backgroundMode = try container.decodeIfPresent(BackgroundMode.self, forKey: .backgroundMode) ?? .solid
        backgroundColor = try container.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor) ?? RGBAColor()
        segmentationQuality = try container.decodeIfPresent(SegmentationQuality.self, forKey: .segmentationQuality) ?? .balanced
    }

    func clip(mediaFolder: URL) -> Clip {
        let url = external ? URL(fileURLWithPath: file) : mediaFolder.appendingPathComponent(file)
        var c = Clip(id: id, path: file, isExternal: external, url: url)
        c.track = track
        c.start = start ?? -1
        c.inPoint = inPoint
        c.outPoint = outPoint
        c.pipX = pipX
        c.pipY = pipY
        c.pipScale = pipScale
        c.pipCornerRadius = pipCornerRadius
        c.removeBackground = removeBackground
        c.backgroundMode = backgroundMode
        c.backgroundColor = backgroundColor
        c.segmentationQuality = segmentationQuality
        c.isMissing = !FileManager.default.fileExists(atPath: url.path)
        return c
    }
}


// MARK: - Output framing

/// The shape of the exported video. "Original" keeps whatever the clips already are;
/// everything else re-frames to a standard aspect, cropping or letterboxing to suit.
enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case original
    case landscape16x9
    case vertical9x16
    case square1x1
    case portrait4x5
    case classic4x3
    case cinematic21x9

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original:      return "Original"
        case .landscape16x9: return "16:9 — Landscape"
        case .vertical9x16:  return "9:16 — Vertical"
        case .square1x1:     return "1:1 — Square"
        case .portrait4x5:   return "4:5 — Portrait"
        case .classic4x3:    return "4:3 — Classic"
        case .cinematic21x9: return "21:9 — Cinematic"
        }
    }

    var note: String {
        switch self {
        case .original:      return "Whatever the clips already are"
        case .landscape16x9: return "YouTube, Vimeo, standard video"
        case .vertical9x16:  return "YouTube Shorts, TikTok, Reels, Stories"
        case .square1x1:     return "Instagram and LinkedIn feed"
        case .portrait4x5:   return "Instagram portrait — the tallest the feed allows"
        case .classic4x3:    return "Older cameras and slide decks"
        case .cinematic21x9: return "Ultrawide / letterboxed film look"
        }
    }

    /// width / height, or nil for "original".
    var ratio: CGFloat? {
        switch self {
        case .original:      return nil
        case .landscape16x9: return 16.0 / 9.0
        case .vertical9x16:  return 9.0 / 16.0
        case .square1x1:     return 1
        case .portrait4x5:   return 4.0 / 5.0
        case .classic4x3:    return 4.0 / 3.0
        case .cinematic21x9: return 21.0 / 9.0
        }
    }

    /// The largest frame of this aspect that fits inside the source's own dimensions, so
    /// re-framing never enlarges the picture — capped so the encoder is not handed
    /// something absurd.
    func outputSize(source: CGSize) -> CGSize {
        guard let ratio, source.width > 0, source.height > 0 else { return evenSize(source) }
        var width = min(source.width, source.height * ratio)
        var height = width / ratio
        let cap: CGFloat = 3840
        let overshoot = max(width / cap, height / cap)
        if overshoot > 1 {
            width /= overshoot
            height /= overshoot
        }
        return evenSize(CGSize(width: width, height: height))
    }
}

/// Fill crops to the edges of the frame; Fit keeps everything and pads the sides.
enum CropMode: String, Codable, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var label: String { self == .fill ? "Fill frame (crop)" : "Fit inside (letterbox)" }
}

struct FrameSpec: Codable, Equatable {
    var preset: AspectPreset = .original
    var mode: CropMode = .fill
    /// Where the surviving window sits, 0…1 along each axis: 0 is left/top, 1 is
    /// right/bottom, 0.5 centred. Only the axis actually being cropped has any effect.
    var cropX: Double = 0.5
    var cropY: Double = 0.5

    var cropsAnything: Bool { preset != .original && mode == .fill }
    var position: CGPoint { CGPoint(x: cropX, y: cropY) }

    init() {}

    enum CodingKeys: String, CodingKey {
        case preset, mode, cropX, cropY
        /// Before the crop could be positioned freely it was a three-way choice.
        case align
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decodeIfPresent(AspectPreset.self, forKey: .preset) ?? .original
        mode = try container.decodeIfPresent(CropMode.self, forKey: .mode) ?? .fill
        if let x = try container.decodeIfPresent(Double.self, forKey: .cropX) { cropX = x }
        if let y = try container.decodeIfPresent(Double.self, forKey: .cropY) { cropY = y }
        if container.contains(.align), !container.contains(.cropX) {
            switch try container.decodeIfPresent(String.self, forKey: .align) {
            case "start": cropX = 0; cropY = 0
            case "end":   cropX = 1; cropY = 1
            default:      cropX = 0.5; cropY = 0.5
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(mode, forKey: .mode)
        try container.encode(cropX, forKey: .cropX)
        try container.encode(cropY, forKey: .cropY)
    }
}

enum ExportQuality: String, Codable, CaseIterable, Identifiable {
    case highest, medium, low
    var id: String { rawValue }
    var label: String {
        switch self {
        case .highest: return "Highest quality"
        case .medium: return "Medium"
        case .low: return "Low (small file)"
        }
    }
    var preset: String {
        switch self {
        case .highest: return AVAssetExportPresetHighestQuality
        case .medium:  return AVAssetExportPresetMediumQuality
        case .low:     return AVAssetExportPresetLowQuality
        }
    }
}

/// Everything that lives in VideoEditorProject.json.
struct ProjectData: Codable {
    var formatVersion = 2
    var clips: [ClipData] = []
    var frame = FrameSpec()
    var exportQuality: ExportQuality = .highest
    /// Empty means "name it after the workspace folder".
    var lastExportName = ""

    init() {}

    /// Decoded field by field so that a project written by an older build — which will
    /// be missing whatever was added since — still opens.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        clips = try container.decodeIfPresent([ClipData].self, forKey: .clips) ?? []
        frame = try container.decodeIfPresent(FrameSpec.self, forKey: .frame) ?? FrameSpec()
        exportQuality = try container.decodeIfPresent(ExportQuality.self, forKey: .exportQuality) ?? .highest
        lastExportName = try container.decodeIfPresent(String.self, forKey: .lastExportName) ?? ""
    }
}
