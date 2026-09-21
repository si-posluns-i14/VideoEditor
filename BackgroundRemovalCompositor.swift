import Foundation
import AVFoundation
import CoreImage
import Vision
import Metal

// MARK: - Per-segment instruction carried into the custom compositor
//
// A custom compositor is instantiated by AVFoundation with no arguments, so every
// per-clip setting has to travel inside the instruction objects.

final class SCInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    struct Layer {
        var trackID: CMPersistentTrackID
        /// Transform in Core Image space (bottom-left origin).
        var transform: CGAffineTransform
        var removeBackground: Bool
        /// nil means "make the background transparent".
        var backgroundColor: CIColor?
        var quality: VNGeneratePersonSegmentationRequest.QualityLevel
        /// Stable key so each layer keeps its own stateful Vision request.
        var segmenterKey: String
        /// Corner rounding, as a fraction of the layer's shorter side. 0 is square.
        var cornerRadius: Double = 0
    }

    /// Adjusted after the fact so the instructions tile the composition exactly.
    var timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Nil when nothing is filling the frame — a self-view playing on past its clip, or
    /// over a clip that is missing. The backdrop shows through.
    let main: Layer?
    let overlay: Layer?
    /// Letterbox / empty areas: clear when the export keeps an alpha channel, else black.
    let transparentBackdrop: Bool

    init(timeRange: CMTimeRange, main: Layer?, overlay: Layer?, transparentBackdrop: Bool) {
        self.timeRange = timeRange
        self.main = main
        self.overlay = overlay
        self.transparentBackdrop = transparentBackdrop
        var ids: [NSValue] = []
        if let main { ids.append(NSNumber(value: main.trackID)) }
        if let overlay { ids.append(NSNumber(value: overlay.trackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

// MARK: - Custom compositor: Vision person segmentation + PiP, via Core Image

final class BackgroundRemovalCompositor: NSObject, AVVideoCompositing {

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    private let queue = DispatchQueue(label: "local.videoeditor.compositor")
    private var renderSize: CGSize = .zero
    private var segmenters: [String: VNGeneratePersonSegmentationRequest] = [:]

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderSize = newRenderContext.size }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let instruction = request.videoCompositionInstruction as? SCInstruction,
                  let destination = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.badRequest)
                return
            }

            let bounds = CGRect(origin: .zero, size: request.renderContext.size)
            let backdropColor = instruction.transparentBackdrop
                ? CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            var output = CIImage(color: backdropColor).cropped(to: bounds)

            if let main = instruction.main, let image = self.layerImage(main, request: request) {
                output = image.composited(over: output)
            }
            if let overlay = instruction.overlay, let image = self.layerImage(overlay, request: request) {
                output = image.composited(over: output)
            }

            self.ciContext.render(output,
                                  to: destination,
                                  bounds: bounds,
                                  colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: destination)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: Per-layer work

    private func layerImage(_ layer: SCInstruction.Layer,
                            request: AVAsynchronousVideoCompositionRequest) -> CIImage? {
        guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if layer.removeBackground {
            image = segmented(image, buffer: buffer, layer: layer)
        }
        if layer.cornerRadius > 0.001 {
            image = rounded(image, fraction: layer.cornerRadius)
        }
        return image.transformed(by: layer.transform)
    }

    /// Rounds a layer's corners by masking it with a rounded rectangle of its own size.
    /// Done before the transform, so the radius scales with the layer.
    private func rounded(_ image: CIImage, fraction: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let radius = CGFloat(min(max(fraction, 0), 0.5)) * min(extent.width, extent.height)
        guard radius > 0.5,
              let generator = CIFilter(name: "CIRoundedRectangleGenerator") else { return image }
        generator.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        generator.setValue(radius, forKey: "inputRadius")
        generator.setValue(CIColor.white, forKey: "inputColor")
        guard let mask = generator.outputImage?.cropped(to: extent),
              let masked = CIFilter(name: "CISourceInCompositing") else { return image }
        masked.setValue(image, forKey: kCIInputImageKey)
        masked.setValue(mask, forKey: kCIInputBackgroundImageKey)
        return masked.outputImage?.cropped(to: extent) ?? image
    }

    /// Replace everything that is not a person with `layer.backgroundColor` (or clear).
    private func segmented(_ image: CIImage, buffer: CVPixelBuffer, layer: SCInstruction.Layer) -> CIImage {
        let request = segmenter(for: layer.segmenterKey)
        request.qualityLevel = layer.quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = (request.results?.first)?.pixelBuffer else { return image }

        var mask = CIImage(cvPixelBuffer: maskBuffer)
        guard mask.extent.width > 0, mask.extent.height > 0 else { return image }
        mask = mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width,
                                                      y: image.extent.height / mask.extent.height))

        let background = CIImage(color: layer.backgroundColor ?? CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: image.extent)

        guard let filter = CIFilter(name: "CIBlendWithMask") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage ?? image
    }

    /// Person segmentation is a stateful request — reuse one instance per layer so it can
    /// carry temporal context between frames.
    private func segmenter(for key: String) -> VNGeneratePersonSegmentationRequest {
        if let existing = segmenters[key] { return existing }
        let request = VNGeneratePersonSegmentationRequest()
        segmenters[key] = request
        return request
    }
}

enum CompositorError: LocalizedError {
    case badRequest
    var errorDescription: String? { "The compositor received an unusable frame request." }
}

extension SegmentationQuality {
    var visionLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
        self == .accurate ? .accurate : .balanced
    }
}

// MARK: - Single-frame preview of the background-removal effect

enum BackgroundPreview {

    /// Renders one frame of `url` with the person isolated, for the inspector thumbnail.
    static func image(url: URL, at seconds: Double, clip: Clip, maxWidth: CGFloat = 320) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth * 2, height: maxWidth * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        guard let cgImage = try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
        else { return nil }

        guard clip.removeBackground else { return cgImage }

        let source = CIImage(cgImage: cgImage)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = clip.segmentationQuality.visionLevel
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = (request.results?.first)?.pixelBuffer else { return cgImage }

        var mask = CIImage(cvPixelBuffer: maskBuffer)
        guard mask.extent.width > 0 else { return cgImage }
        mask = mask.transformed(by: CGAffineTransform(scaleX: source.extent.width / mask.extent.width,
                                                      y: source.extent.height / mask.extent.height))

        let backgroundColor = clip.backgroundMode == .transparent
            ? CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            : clip.backgroundColor.ciColor
        let background = CIImage(color: backgroundColor).cropped(to: source.extent)

        guard let filter = CIFilter(name: "CIBlendWithMask") else { return cgImage }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage else { return cgImage }

        let context = CIContext(options: nil)
        return context.createCGImage(output, from: source.extent)
    }
}
