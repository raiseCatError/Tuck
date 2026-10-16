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
        let created = TuckPreferences.prepareKey()
        TuckLog.helperLogger.info("helper.launched pid=\(ProcessInfo.processInfo.processIdentifier) keyCreated=\(created) keyPresent=\(TuckPreferences.sharedKey != nil) settingsArg=\(CommandLine.arguments.contains("--settings"))")
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
        TuckLog.helperLogger.info("helper.url-received count=\(urls.count)")
        for url in urls {
            if url.host == "settings" { showSettings(); continue }
            switch TuckRequest.verify(url) {
            case .failure(let reason):
                TuckLog.helperLogger.error("helper.verify-failed reason=\(reason.rawValue, privacy: .public) urlBytes=\(url.absoluteString.utf8.count)")
            case .success(let request):
                guard !seenRequests.contains(request.nonce) else {
                    TuckLog.helperLogger.error("helper.replay-rejected op=\(request.operation, privacy: .public)")
                    continue
                }
                seenRequests.insert(request.nonce)
                if seenRequests.count > 2000 { seenRequests.removeAll(keepingCapacity: true) }
                TuckLog.helperLogger.info("helper.verified op=\(request.operation, privacy: .public) paths=\(request.paths.count) argument=\(request.argument != nil, privacy: .public)")
                handle(request)
            }
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
        TuckLog.helperLogger.info("helper.handle op=\(request.operation, privacy: .public) paths=\(request.paths.count)")
        switch request.operation {
        case "newFile", "newFileCustom":
            guard let first = request.paths.first else {
                TuckLog.helperLogger.error("helper.handle-aborted op=\(request.operation, privacy: .public) reason=no-path"); return
            }
            var name = request.argument
            if request.operation == "newFileCustom" { name = promptForName() }
            guard let name else {
                TuckLog.helperLogger.info("helper.handle-cancelled op=\(request.operation, privacy: .public) reason=dismissed-prompt"); return
            }
            do {
                let output = try FileWork.newFile(in: URL(fileURLWithPath: first), name: name)
                TuckLog.helperLogger.info("helper.result op=\(request.operation, privacy: .public) outcome=created")
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                TuckLog.helperLogger.error("helper.result op=\(request.operation, privacy: .public) outcome=failed detail=\(error.localizedDescription, privacy: .private)")
                report(error.localizedDescription)
            }
        case "openWith":
            guard let id = request.argument,
                  TuckMenuModel.editors.contains(where: { $0.1 == id }),
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                TuckLog.helperLogger.error("helper.handle-aborted op=openWith reason=app-unavailable"); return
            }
            let files = request.paths.map { URL(fileURLWithPath: $0) }
            NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    TuckLog.helperLogger.error("helper.result op=openWith outcome=failed detail=\(error.localizedDescription, privacy: .private)")
                    Task { @MainActor in self.report(error.localizedDescription) }
                } else {
                    TuckLog.helperLogger.info("helper.result op=openWith outcome=opened files=\(files.count)")
                }
            }
        case "terminal":
            guard let path = request.paths.first else {
                TuckLog.helperLogger.error("helper.handle-aborted op=terminal reason=no-path"); return
            }
            openTerminal(at: path)
        case "compress", "compressCustom":
            var size = request.argument.flatMap(Double.init)
            if request.operation == "compressCustom" { size = promptForSize() }
            guard let size, (0.1...500).contains(size) else {
                TuckLog.helperLogger.error("helper.handle-aborted op=\(request.operation, privacy: .public) reason=invalid-size"); return
            }
            let paths = request.paths
            Task.detached(priority: .userInitiated) { [weak self] in
                let results = FileWork.compress(paths, targetMB: size)
                await MainActor.run {
                    TuckLog.helperLogger.info("helper.result op=\(request.operation, privacy: .public) outputs=\(results.files.count) failures=\(results.errors.count)")
                    if !results.files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results.files) }
                    if !results.errors.isEmpty { self?.report(results.errors.joined(separator: "\n")) }
                }
            }
        case "zip":
            let paths = request.paths
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let output = try FileWork.zip(paths)
                    await MainActor.run {
                        TuckLog.helperLogger.info("helper.result op=zip outcome=created")
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                } catch {
                    await MainActor.run {
                        TuckLog.helperLogger.error("helper.result op=zip outcome=failed detail=\(error.localizedDescription, privacy: .private)")
                        self?.report(error.localizedDescription)
                    }
                }
            }
        default:
            TuckLog.helperLogger.error("helper.handle-aborted op=\(request.operation, privacy: .public) reason=unknown-operation")
            return
        }
    }

    private func openTerminal(at path: String) {
        let id = TuckPreferences.terminal
        if id == "com.mitchellh.ghostty" {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else {
                TuckLog.helperLogger.error("helper.result op=terminal outcome=failed reason=ghostty-not-installed")
                report("Ghostty isn't installed. Choose Terminal.app in Settings."); return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-na", "Ghostty", "--args", "--working-directory=\(path)"]
            do {
                try task.run()
                TuckLog.helperLogger.info("helper.result op=terminal outcome=launched app=ghostty")
            } catch {
                TuckLog.helperLogger.error("helper.result op=terminal outcome=failed detail=\(error.localizedDescription, privacy: .private)")
                report(error.localizedDescription)
            }
        } else {
            // Terminal.app accepts Finder folders through its open-document route.
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                TuckLog.helperLogger.error("helper.result op=terminal outcome=failed reason=terminal-not-found")
                return
            }
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    TuckLog.helperLogger.error("helper.result op=terminal outcome=failed detail=\(error.localizedDescription, privacy: .private)")
                    Task { @MainActor in self.report(error.localizedDescription) }
                } else {
                    TuckLog.helperLogger.info("helper.result op=terminal outcome=launched app=Terminal")
                }
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
        TuckLog.helperLogger.error("helper.reported detail=\(message, privacy: .private)")
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
