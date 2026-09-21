import SwiftUI
import AVFoundation
import AppKit

/// The workspace's own folders, listed the way an editor lists a project: everything in
/// Media/ and Exports/, whether or not the timeline currently uses it.
struct MediaBrowserView: View {
    @EnvironmentObject var model: AppModel

    @SCState private var showMedia = true
    @SCState private var showExports = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspace").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan the workspace folder")
                Button { model.revealWorkspace() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Open the workspace in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            List {
                Section(isExpanded: $showMedia) {
                    if model.mediaFiles.isEmpty {
                        Text("Nothing recorded or imported yet")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        ForEach(model.mediaFiles, id: \.path) { url in
                            row(url, inMedia: true)
                        }
                    }
                } header: {
                    Label("Media", systemImage: "film.stack").font(.system(size: 11, weight: .semibold))
                }

                Section(isExpanded: $showExports) {
                    if model.exportFiles.isEmpty {
                        Text("No exports yet")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        ForEach(model.exportFiles, id: \.path) { url in
                            row(url, inMedia: false)
                        }
                    }
                } header: {
                    Label("Exports", systemImage: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 6) {
                Button { model.addClips(copy: true) } label: { Label("Import…", systemImage: "plus") }
                    .controlSize(.small)
                Spacer()
                Text("\(model.mediaFiles.count) file\(model.mediaFiles.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .task { model.refreshLibrary() }
    }

    private func row(_ url: URL, inMedia: Bool) -> some View {
        let used = inMedia && model.usedMediaNames.contains(url.lastPathComponent)
        return HStack(spacing: 8) {
            LibraryThumbnail(url: url)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1).truncationMode(.middle)
                Text(fileSize(url))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if used {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Already on the timeline")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: url.path as NSString) }
        .contextMenu {
            if inMedia {
                Button("Add to Clip Row") { model.addFromLibrary(url, to: .main) }
                Button("Add to Self-View Row") { model.addFromLibrary(url, to: .selfView) }
                Divider()
            }
            Button("Reveal in Finder") { revealInFinder(url) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Divider()
            Button("Move File to Trash…", role: .destructive) { confirmTrash(url, inMedia: inMedia) }
        }
        .onTapGesture(count: 2) {
            if inMedia { model.addFromLibrary(url, to: .main) } else { NSWorkspace.shared.open(url) }
        }
        .help(inMedia ? "Drag onto a timeline row, or double-click to add to the Clip row" : "Double-click to play")
    }

    /// Deleting is the user's file, not just a timeline entry, so it asks first and goes
    /// to the Trash rather than disappearing.
    private func confirmTrash(_ url: URL, inMedia: Bool) {
        let used = inMedia && model.usedMediaNames.contains(url.lastPathComponent)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \u{201C}\(url.lastPathComponent)\u{201D} to the Trash?"
        alert.informativeText = used
            ? "The timeline uses this file. Those clips will show as missing until you put it back."
            : "You can get it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([url]) { _, _ in
            Task { @MainActor in model.refreshLibrary() }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Small poster frame, generated lazily as rows appear.
private struct LibraryThumbnail: View {
    let url: URL
    @SCState private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.5))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(width: 40, height: 24)
        .task(id: url) { image = await Self.poster(url) }
    }

    nonisolated private static func poster(_ url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
