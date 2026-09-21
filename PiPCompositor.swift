import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Geometry shared by both export paths
//
// AVFoundation's render coordinate space has its origin at the TOP-LEFT and y growing
// downwards. Core Image's has its origin at the BOTTOM-LEFT. Everything below is
// computed once in AV space; `Geometry.toCoreImage` converts when the custom compositor
// needs it.

enum Geometry {

    /// The on-screen size of a track once its `preferredTransform` (rotation) is applied.
    static func displayedSize(natural: CGSize, preferred: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: natural).applying(preferred)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Aspect-fit the whole track into the render frame, centred.
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize) -> CGAffineTransform {
        frameTransform(natural: natural, preferred: preferred, render: render,
                       mode: .fit, position: CGPoint(x: 0.5, y: 0.5))
    }

    /// Places a track in the render frame: Fill scales to cover and crops the overflow,
    /// Fit scales to contain and pads. `align` decides which part survives a crop.
    static func frameTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize,
                               mode: CropMode, position: CGPoint) -> CGAffineTransform {
        let box = CGRect(origin: .zero, size: natural).applying(preferred)
        let w = abs(box.width), h = abs(box.height)
        guard w > 0, h > 0 else { return preferred }

        let scale = mode == .fill
            ? max(render.width / w, render.height / h)
            : min(render.width / w, render.height / h)
        let outW = w * scale, outH = h * scale

        func offset(_ output: CGFloat, _ frame: CGFloat, _ fraction: Double) -> CGFloat {
            // Only an overflowing axis can be positioned; an axis that fits is centred.
            guard output > frame else { return (frame - output) / 2 }
            return (frame - output) * CGFloat(min(max(fraction, 0), 1))
        }

        return preferred
            .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offset(outW, render.width, position.x),
                                             y: offset(outH, render.height, position.y)))
    }

    /// The part of a source frame that survives, in source coordinates — what the crop
    /// guide draws.
    static func visibleSourceRect(source: CGSize, render: CGSize, mode: CropMode, position: CGPoint) -> CGRect {
        guard source.width > 0, source.height > 0, mode == .fill else {
            return CGRect(origin: .zero, size: source)
        }
        let scale = max(render.width / source.width, render.height / source.height)
        let visible = CGSize(width: min(source.width, render.width / scale),
                             height: min(source.height, render.height / scale))
        func origin(_ span: CGFloat, _ total: CGFloat, _ fraction: Double) -> CGFloat {
            guard span < total else { return 0 }
            return (total - span) * CGFloat(min(max(fraction, 0), 1))
        }
        return CGRect(x: origin(visible.width, source.width, position.x),
                      y: origin(visible.height, source.height, position.y),
                      width: visible.width, height: visible.height)
    }

    /// Scale the track to `fraction` of the render width and place it anywhere in the
    /// frame: position 0…1 runs between the margins on each axis.
    static func overlayTransform(natural: CGSize, preferred: CGAffineTransform, bounds: CGRect,
                                 fraction: CGFloat, position: CGPoint) -> CGAffineTransform {
        let box = CGRect(origin: .zero, size: natural).applying(preferred)
        let w = abs(box.width), h = abs(box.height)
        guard w > 0, h > 0 else { return preferred }
        let clamped = min(max(fraction, 0.05), 1.5)
        let scale = (bounds.width * clamped) / w
        let outW = w * scale, outH = h * scale

        let rect = overlayRect(outputSize: CGSize(width: outW, height: outH),
                               bounds: bounds, position: position)
        return preferred
            .concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Where the overlay lands inside `bounds`. Normally that is the whole render frame;
    /// with the crop guide showing it is the part that survives the crop, so the preview
    /// puts the self-view where the export will.
    static func overlayRect(outputSize: CGSize, bounds: CGRect, position: CGPoint) -> CGRect {
        let margin = bounds.width * 0.025
        let spanX = bounds.width - outputSize.width - margin * 2
        let spanY = bounds.height - outputSize.height - margin * 2
        // Once the overlay is too big to have anywhere to go, centre it rather than
        // pinning it to a margin and letting it hang off the edge.
        let x = spanX > 0
            ? bounds.minX + margin + spanX * CGFloat(min(max(position.x, 0), 1))
            : bounds.minX + (bounds.width - outputSize.width) / 2
        let y = spanY > 0
            ? bounds.minY + margin + spanY * CGFloat(min(max(position.y, 0), 1))
            : bounds.minY + (bounds.height - outputSize.height) / 2
        return CGRect(origin: CGPoint(x: x, y: y), size: outputSize)
    }

    /// Convert a top-left-origin AV transform into a bottom-left-origin Core Image one.
    ///
    ///   p_ci --flip(src)--> p_av --m--> q_av --flip(render)--> q_ci
    static func toCoreImage(_ m: CGAffineTransform, sourceHeight: CGFloat, renderHeight: CGFloat) -> CGAffineTransform {
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipRender = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderHeight)
        return flipSource.concatenating(m).concatenating(flipRender)
    }
}

// MARK: - Layer-instruction PiP (used when no background removal is involved)

enum PiPCompositor {

    /// Builds a plain `AVMutableVideoCompositionInstruction` for one timeline segment:
    /// the main track aspect-fitted, and — if present — the overlay track scaled into a
    /// corner with a `CGAffineTransform`.
    static func instruction(timeRange: CMTimeRange,
                            main: SegmentTrack?,
                            overlay: SegmentTrack?,
                            renderSize: CGSize,
                            overlayBounds: CGRect,
                            frame: FrameSpec,
                            transparent: Bool = false) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        // Gaps on the timeline show this through: black, or nothing at all when the
        // export keeps an alpha channel.
        instruction.backgroundColor = transparent
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        var mainLayer: AVMutableVideoCompositionLayerInstruction?
        if let main {
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: main.track)
            layer.setTransform(Geometry.frameTransform(natural: main.naturalSize,
                                                       preferred: main.preferredTransform,
                                                       render: renderSize,
                                                       mode: frame.mode,
                                                       position: frame.position),
                               at: timeRange.start)
            mainLayer = layer
        }

        if let overlay {
            let overlayLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: overlay.track)
            overlayLayer.setTransform(Geometry.overlayTransform(natural: overlay.naturalSize,
                                                               preferred: overlay.preferredTransform,
                                                               bounds: overlayBounds,
                                                               fraction: overlay.scale,
                                                               position: overlay.position),
                                      at: timeRange.start)
            // Later layer instructions draw underneath, so the overlay comes first.
            instruction.layerInstructions = [overlayLayer] + (mainLayer.map { [$0] } ?? [])
        } else {
            instruction.layerInstructions = mainLayer.map { [$0] } ?? []
        }
        return instruction
    }
}

/// A composition track plus the source geometry needed to place it.
struct SegmentTrack {
    let track: AVMutableCompositionTrack
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    var scale: CGFloat = 0.28
    var position: CGPoint = CGPoint(x: 1, y: 1)
}
