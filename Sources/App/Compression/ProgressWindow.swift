import AppKit
import SwiftUI

// A small, cancellable progress panel. It never blocks the main thread and is
// dismissed the moment the worker finishes, so Finder stays responsive.

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
        TuckLog.compressionLogger.info("work.cancel-requested")
    }
}

@MainActor
final class ProgressModel: ObservableObject {
    @Published var fraction: Double = 0
    @Published var detail: String = ""
}

struct ProgressBody: View {
    @ObservedObject var model: ProgressModel
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ProgressView(value: model.fraction)
            if !model.detail.isEmpty {
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
final class ProgressWindow {
    private var window: NSWindow?
    private let model = ProgressModel()

    func present(title: String, onCancel: @escaping () -> Void) {
        let root = ProgressBody(model: model, title: title, onCancel: onCancel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 152),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        // No fullSizeContentView: the title bar must never overlap the content.
        window.titlebarAppearsTransparent = false
        let hosting = NSHostingController(rootView: root)
        window.contentViewController = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func update(fraction: Double, detail: String) {
        model.fraction = min(max(fraction, 0), 1)
        model.detail = detail
        if !detail.isEmpty { window?.title = detail }
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}