import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct VideoEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("VideoEditor") {
            ContentView()
                .environmentObject(model)
                .onDisappear { model.saveNow() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") { model.newWorkspace() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Open Workspace…") { model.openWorkspace() }
                    .keyboardShortcut("o", modifiers: [.command])

                Menu("Open Recent") {
                    ForEach(model.recents, id: \.path) { url in
                        Button(url.lastPathComponent) { model.open(url) }
                    }
                }
                .disabled(model.recents.isEmpty)

                Divider()
                Button("Close Workspace") { model.closeWorkspace() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.workspace == nil)
            }

            CommandGroup(after: .saveItem) {
                Button("Save Project") { model.saveNow() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(model.workspace == nil)
                Button("Show Workspace in Finder") { model.revealWorkspace() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.workspace == nil)
            }

            CommandMenu("Clip") {
                Button("Add Clip…") { model.addClips(copy: true) }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("Add Clip (reference only)…") { model.addClips(copy: false) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Set In Point") { model.setInPointAtPlayhead() }
                    .keyboardShortcut("[", modifiers: [])
                Button("Set Out Point") { model.setOutPointAtPlayhead() }
                    .keyboardShortcut("]", modifiers: [])
                Button("Reset Trim") { model.resetTrim() }
                Button("Split at Playhead") { model.splitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(!model.canSplit)
                Divider()
                Button("Export…") { model.startExport() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(model.workspace == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button(model.canUndo ? "Undo \(model.undoActionName)" : "Undo") { model.performUndo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button(model.canRedo ? "Redo \(model.redoActionName)" : "Redo") { model.performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { model.performCut() }
                    .keyboardShortcut("x", modifiers: [.command])
                Button("Copy") { model.performCopy() }
                    .keyboardShortcut("c", modifiers: [.command])
                Button(model.clipboard.count > 1 ? "Paste \(model.clipboard.count) Clips" : "Paste") {
                    model.performPaste()
                }
                .keyboardShortcut("v", modifiers: [.command])
                Divider()
                Button("Delete") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.selection == nil)
            }

            CommandGroup(before: .toolbar) {
                Button("Capture") { model.mode = .record }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(model.workspace == nil || model.recorder.isRecording)
                Button("Timeline") { model.mode = .edit }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(model.workspace == nil || model.recorder.isRecording)
                Divider()
            }

            CommandMenu("Record") {
                Button(model.recorder.isRecording ? "Stop Recording" : "Start Recording") {
                    model.recorder.toggle(workspace: model.workspace)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.workspace == nil || model.recorder.isBusy)
            }
        }
    }
}
