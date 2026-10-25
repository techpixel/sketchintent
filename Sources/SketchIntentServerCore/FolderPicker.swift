import AppKit
import Foundation

/// Presents a directory panel on the Mac. The iPad is showing that screen, so the
/// panel is the folder selector for the agent.
enum FolderPicker {
    private static let lock = NSLock()
    private static var open = false

    static func choose(startingAt path: String, reply: @escaping (String) -> Void) {
        lock.lock()
        if open {
            lock.unlock()
            return
        }
        open = true
        lock.unlock()
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "The agent will work in this folder."
            panel.title = "Agent folder"
            if path.hasPrefix("/") {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            let previous = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                let chosen = response == .OK ? (panel.url?.path ?? "") : ""
                NSApp.setActivationPolicy(previous)
                reply(chosen.hasPrefix("/") ? chosen : "")
                lock.lock()
                open = false
                lock.unlock()
            }
        }
    }
}
