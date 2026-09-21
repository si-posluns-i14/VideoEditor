import Foundation
import AppKit
import SwiftUI
import AVFoundation

// MARK: - @State shim
//
// The macOS 26 SDK declares `State` as a SwiftUI macro backed by the SwiftUIMacros
// compiler plugin, which ships with Xcode but NOT with the Command Line Tools. This app
// is built with plain `swiftc`, so the attribute is spelled `@SCState`: a typealias to
// the original `SwiftUI.State` property wrapper, which behaves identically and needs no
// plugin. Swap it back to `@State` if you ever move this into Xcode.
typealias SCState = SwiftUI.State

// MARK: - Formatting

func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func preciseTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
    let total = Int(seconds)
    let tenths = Int((seconds - Double(total)) * 10)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
                 : String(format: "%d:%02d.%d", m, s, tenths)
}

// MARK: - Codable colour

struct RGBAColor: Codable, Equatable {
    var r: Double = 0.0, g: Double = 0.65, b: Double = 0.31, a: Double = 1.0

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }

    init() {}
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .green
        r = Double(ns.redComponent); g = Double(ns.greenComponent)
        b = Double(ns.blueComponent); a = Double(ns.alphaComponent)
    }
}

// MARK: - Misc helpers

extension URL {
    var isVideoFile: Bool {
        ["mp4", "mov", "m4v"].contains(pathExtension.lowercased())
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// Even, sane render dimensions — encoders dislike odd numbers.
func evenSize(_ size: CGSize) -> CGSize {
    func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
    return CGSize(width: even(size.width), height: even(size.height))
}
