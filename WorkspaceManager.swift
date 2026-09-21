import Foundation
import AppKit

/// A workspace is an ordinary, user-visible folder:
///
///     MyProject/
///       Media/                    copies of every imported clip
///       Exports/                  every rendered output
///       VideoEditorProject.json  the whole project state
///
/// Nothing is written outside it, apart from the recent-workspaces list and the recording
/// preferences, which live in UserDefaults because they are specific to this Mac.
enum WorkspaceManager {

    static let projectFileName = "VideoEditorProject.json"
    /// The app used to be called StreamCutter; workspaces made back then are migrated in
    /// place the first time they are opened.
    static let legacyProjectFileName = "StreamCutterProject.json"

    static func mediaFolder(_ workspace: URL) -> URL { workspace.appendingPathComponent("Media", isDirectory: true) }
    static func exportsFolder(_ workspace: URL) -> URL { workspace.appendingPathComponent("Exports", isDirectory: true) }
    static func projectFile(_ workspace: URL) -> URL { workspace.appendingPathComponent(projectFileName) }

    /// Creates Media/, Exports/ and an empty project file if they are not there yet.
    @discardableResult
    static func prepare(_ workspace: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaFolder(workspace), withIntermediateDirectories: true)
        try fm.createDirectory(at: exportsFolder(workspace), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: projectFile(workspace).path) {
            let legacy = workspace.appendingPathComponent(legacyProjectFileName)
            if fm.fileExists(atPath: legacy.path) {
                try fm.moveItem(at: legacy, to: projectFile(workspace))
            } else {
                try ProjectFile.write(ProjectData(), to: workspace)
            }
        }
        return workspace
    }

    /// Ask the user for an existing folder to open as a workspace.
    static func chooseExisting() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.message = "Pick a folder to use as a VideoEditor workspace."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Ask the user to name and place a brand-new workspace folder.
    static func chooseNew() -> URL? {
        let panel = NSSavePanel()
        panel.title = "New Workspace"
        panel.message = "Choose where to create the workspace folder."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "My Project"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Copy a file into `Media/`, never overwriting: clip.mov → clip-2.mov → clip-3.mov.
    static func importCopy(_ source: URL, into workspace: URL) throws -> String {
        let fm = FileManager.default
        let media = mediaFolder(workspace)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)

        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var name = source.lastPathComponent
        var destination = media.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            destination = media.appendingPathComponent(name)
            counter += 1
        }
        try fm.copyItem(at: source, to: destination)
        return name
    }

    /// A non-clashing name inside Exports/.
    static func uniqueExportURL(workspace: URL, name: String, ext: String) -> URL {
        let folder = exportsFolder(workspace)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var candidate = folder.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func chooseVideoFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add Clip"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["mp4", "mov", "m4v"]
        return panel.runModal() == .OK ? panel.urls : []
    }
}
