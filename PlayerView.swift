import SwiftUI
import AVKit
import AVFoundation

/// The video surface: an `AVPlayerLayer` in a plain layer-backed view.
///
/// `AVPlayerView` was here first and worked; it was swapped out while chasing a black
/// preview that turned out to be an invalid video composition, not the view. A player
/// layer is kept because it is the smaller surface: no controls, no AVKit chrome, and
/// nothing between the composition and the screen.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class SurfaceView: NSView {
        let playerLayer = AVPlayerLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            layer = host
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            host.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            // Layer geometry is not animated into place; the preview should track the
            // window live while it is being resized.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// iMovie-style scrub bar: click or drag anywhere to seek, plus draggable in/out markers.
struct ScrubBar: View {
    let duration: Double
    let current: Double
    @Binding var inPoint: Double
    @Binding var outPoint: Double
    var onSeek: (Double) -> Void
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    @SCState private var draggingHandle = false

    private let barHeight: CGFloat = 10
    private let handleWidth: CGFloat = 11
    private let handleHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            bar(totalWidth: geo.size.width, height: geo.size.height)
        }
        .frame(height: handleHeight)
    }

    // MARK: Geometry

    private func scale(_ totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return max(1, totalWidth - handleWidth) / CGFloat(duration)
    }

    private func position(_ seconds: Double, _ totalWidth: CGFloat) -> CGFloat {
        handleWidth / 2 + CGFloat(min(max(seconds, 0), duration)) * scale(totalWidth)
    }

    private func seconds(at x: CGFloat, _ totalWidth: CGFloat) -> Double {
        let s = scale(totalWidth)
        guard s > 0 else { return 0 }
        return min(max(Double((x - handleWidth / 2) / s), 0), duration)
    }

    // MARK: Pieces

    private func bar(totalWidth: CGFloat, height: CGFloat) -> some View {
        let inX = position(inPoint, totalWidth)
        let outX = position(outPoint, totalWidth)
        let playX = position(current, totalWidth)
        let midY = height / 2

        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: max(0, totalWidth - handleWidth), height: barHeight)
                .position(x: totalWidth / 2, y: midY)

            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: max(0, outX - inX), height: barHeight)
                .position(x: (inX + outX) / 2, y: midY)

            Capsule()
                .fill(Color.primary)
                .frame(width: 3, height: handleHeight - 4)
                .shadow(radius: 1)
                .position(x: playX, y: midY)

            handle(label: "In")
                .position(x: inX, y: midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            draggingHandle = true
                            let t = seconds(at: value.location.x, totalWidth)
                            inPoint = min(t, max(0, outPoint - 0.1))
                            onSeek(inPoint)
                        }
                        .onEnded { _ in draggingHandle = false }
                )

            handle(label: "Out")
                .position(x: outX, y: midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            draggingHandle = true
                            let t = seconds(at: value.location.x, totalWidth)
                            outPoint = max(t, min(duration, inPoint + 0.1))
                            onSeek(outPoint)
                        }
                        .onEnded { _ in draggingHandle = false }
                )
        }
        .frame(width: totalWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !draggingHandle else { return }
                    onScrubbingChanged(true)
                    onSeek(seconds(at: value.location.x, totalWidth))
                }
                .onEnded { _ in onScrubbingChanged(false) }
        )
    }

    private func handle(label: String) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: handleHeight)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 1))
            .help("\(label) point")
    }
}
