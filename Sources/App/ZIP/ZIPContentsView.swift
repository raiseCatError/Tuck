import AppKit
import SwiftUI

@MainActor
enum ZIPWindow {
    private static var windows: [UUID: NSWindow] = [:]
    static func show(paths: [String]) {
        guard let path = paths.first else { return }
        let id = UUID()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Inspect ZIP — \(URL(fileURLWithPath: path).lastPathComponent)"
        win.contentViewController = NSHostingController(rootView:
            ZIPContentsView(archive: URL(fileURLWithPath: path)))
        win.center()
        win.isReleasedWhenClosed = false
        windows[id] = win
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: win, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeValue(forKey: id) }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct ZIPContentsView: View {
    let archive: URL
    @State private var entries: [ZipEntry] = []
    @State private var selected: Set<String> = []
    @State private var filter = ""
    @State private var message = "Inspecting ZIP directory…"
    @State private var loading = true
    @State private var jobId: UUID?
    @State private var latestOutput: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ZIP Contents").font(.title2.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView() }
                if let jobId {
                    Button("Cancel extraction") { JobManager.shared.cancel(jobId: jobId) }
                }
            }
            if !entries.isEmpty {
                HStack {
                    TextField("Search files", text: $filter)
                    Button("Extract Selected…") { chooseFolder(selectedOnly: true) }
                        .disabled(selected.isEmpty || jobId != nil)
                    Button("Extract All…") { chooseFolder(selectedOnly: false) }
                        .disabled(jobId != nil)
                }
                List {
                    ForEach(entries.filter {
                        filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
                    }) { entry in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { selected.contains(entry.name) },
                                set: { on in if on { selected.insert(entry.name) }
                                       else { selected.remove(entry.name) } }
                            )).labelsHidden()
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            Text(entry.name).textSelection(.enabled).lineLimit(2)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressed),
                                                           countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                HStack {
                    Text("\(entries.count) entries")
                    Spacer()
                    Text("Selection: \(selected.count)")
                    if let latestOutput {
                        Button("Reveal Extracted Folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([latestOutput])
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            } else if !loading {
                ContentUnavailableView("No entries to display", systemImage: "archivebox",
                                       description: Text(message))
            }
            Text("Safety limits: ZIP/Deflate only, no encrypted entries or symlinks, 2 GB maximum expanded data, 10,000 entries. Originals remain unchanged. Extraction uses a private staging folder and publishes only when validated.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 680, minHeight: 450)
        .task {
            do {
                let found = try await Task.detached(priority: .utility) {
                    try ZipInspector.inspect(archive)
                }.value
                entries = found
                message = "\(found.count) safe ZIP entries available."
            } catch { message = error.localizedDescription }
            loading = false
        }
    }

    private func chooseFolder(selectedOnly: Bool) {
        let panel = NSOpenPanel()
        panel.message = "Select where Tuck should create a new extracted folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let names = selectedOnly ? selected : nil
        let id = JobManager.shared.enqueue(
            title: "Extract ZIP", operation: "zipExtract", paths: [archive.path], canUndo: false,
            onComplete: { record in
                jobId = nil
                message = record.progressDetail
                if let path = record.outputs.first { latestOutput = URL(fileURLWithPath: path) }
            },
            executor: { cancel, progress in
                progress(0.1, "Validating archive…")
                let output = try ZipInspector.extract(
                    archive: archive, destinationFolder: destination, selected: names,
                    shouldCancel: { cancel.isCancelled })
                progress(1, "Extraction completed")
                return JobOutcome(outputs: [output])
            }
        )
        jobId = id
        message = "Extraction queued in Activity…"
    }
}
