import AppKit
import SwiftUI
import Foundation

@main
enum TuckEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = TuckApplication()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class TuckApplication: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var receivedURL = false
    private var seenRequests = Set<String>()
    private var sizeRelay: SizeRelay?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TuckPreferences.prepareKey()
        if CommandLine.arguments.contains("--settings") { showSettings(); return }
        // A Finder-triggered URL may arrive after didFinishLaunching. Never show the
        // settings window for those requests just because the helper wasn't running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.receivedURL else { return }
            self.showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        for url in urls {
            if url.host == "settings" { showSettings(); continue }
            guard let request = TuckRequest.verified(url), !seenRequests.contains(request.nonce) else { continue }
            seenRequests.insert(request.nonce)
            if seenRequests.count > 2000 { seenRequests.removeAll(keepingCapacity: true) }
            handle(request)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tuck Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handle(_ request: TuckRequest) {
        switch request.operation {
        case "newFile", "newFileCustom":
            guard let first = request.paths.first else { return }
            var name = request.argument
            if request.operation == "newFileCustom" { name = promptForName() }
            guard let name else { return }
            do {
                let output = try FileWork.newFile(in: URL(fileURLWithPath: first), name: name)
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch { report(error.localizedDescription) }
        case "openWith":
            guard let id = request.argument,
                  TuckMenuModel.editors.contains(where: { $0.1 == id }),
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
            let files = request.paths.map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.report(error.localizedDescription) } }
            }
        case "terminal":
            guard let path = request.paths.first else { return }
            openTerminal(at: path)
        case "compress", "compressCustom":
            var size = request.argument.flatMap(Double.init)
            if request.operation == "compressCustom" { size = promptForSize() }
            guard let size, (0.1...500).contains(size) else { return }
            let paths = request.paths
            Task.detached(priority: .userInitiated) { [weak self] in
                let results = FileWork.compress(paths, targetMB: size)
                await MainActor.run {
                    if !results.files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results.files) }
                    if !results.errors.isEmpty { self?.report(results.errors.joined(separator: "\n")) }
                }
            }
        case "zip":
            let paths = request.paths
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let output = try FileWork.zip(paths)
                    await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                } catch {
                    await MainActor.run { self?.report(error.localizedDescription) }
                }
            }
        default: return
        }
    }

    private func openTerminal(at path: String) {
        let id = TuckPreferences.terminal
        if id == "com.mitchellh.ghostty" {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else {
                report("Ghostty isn't installed. Choose Terminal.app in Settings."); return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-na", "Ghostty", "--args", "--working-directory=\(path)"]
            do { try task.run() } catch { report(error.localizedDescription) }
        } else {
            // Terminal.app accepts Finder folders through its open-document route.
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.report(error.localizedDescription) } }
            }
        }
    }

    private func promptForName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = "Name the file to create in this folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "Untitled.txt")
        field.frame = NSRect(x: 0, y: 0, width: 290, height: 24)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func promptForSize() -> Double? {
        let alert = NSAlert()
        alert.messageText = "Compress Under a Size"
        alert.informativeText = "Enter a maximum target in MB. The file is never overwritten."
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let slider = NSSlider(value: 5, minValue: 1, maxValue: 100, target: nil, action: nil)
        slider.numberOfTickMarks = 0
        slider.frame = NSRect(x: 0, y: 0, width: 290, height: 24)
        let field = NSTextField(string: "5")
        field.placeholderString = "Maximum MB (0.1–500)"
        field.frame = NSRect(x: 0, y: 0, width: 290, height: 24)
        let relay = SizeRelay(field: field)
        sizeRelay = relay
        defer { sizeRelay = nil }
        slider.target = relay
        slider.action = #selector(SizeRelay.changed(_:))
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(field)
        stack.frame = NSRect(x: 0, y: 0, width: 290, height: 62)
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? Double(field.stringValue) : nil
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Tuck"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
private final class SizeRelay: NSObject {
    let field: NSTextField
    init(field: NSTextField) { self.field = field }
    @objc func changed(_ sender: NSSlider) { field.stringValue = String(Int(sender.doubleValue)) }
}
