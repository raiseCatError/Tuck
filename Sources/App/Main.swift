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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tuck Settings"
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: SettingsView())
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
            runCompression(paths: request.paths, target: CompressionTarget(megabytes: size), operation: request.operation)
        case "zip":
            runZip(paths: request.paths)

        // MARK: - PDF Toolkit
        case "pdfMerge":
            runPDFMerge(paths: request.paths)
        case "pdfSplitRange":
            runPDFSplit(paths: request.paths, customRange: true)
        case "pdfSplitPages":
            runPDFSplit(paths: request.paths, customRange: false)
        case "pdfRotate":
            let deg = request.argument.flatMap(Int.init) ?? 90
            runPDFRotate(paths: request.paths, degrees: deg)
        case "pdfOCR":
            runPDFOCR(paths: request.paths)
        case "pdfExtractImages":
            runPDFExtractImages(paths: request.paths)
        case "pdfToImages":
            runPDFToImages(paths: request.paths)

        // MARK: - Image Toolkit
        case "imageConvert":
            guard let fmt = request.argument else { return }
            runImageConvert(paths: request.paths, targetFormat: fmt)
        case "imageResize":
            let arg = request.argument ?? "pct:50"
            runImageResize(paths: request.paths, spec: arg)
        case "imageResizeCustom":
            if let spec = promptForResize() {
                runImageResize(paths: request.paths, spec: spec)
            }

        // MARK: - Metadata
        case "metaInspect":
            runMetadataInspect(paths: request.paths)
        case "metaStrip":
            runMetadataStrip(paths: request.paths)

        // MARK: - Copy As
        case "copyAs":
            let fmt = request.argument.flatMap(CopyAsFormat.init(rawValue:)) ?? .absolutePath
            runCopyAs(paths: request.paths, format: fmt)

        case "copyTo", "moveTo":
            runTransfer(paths: request.paths, argument: request.argument,
                        mode: request.operation == "moveTo" ? .move : .copy)

        // MARK: - Advanced Rename
        case "advancedRename":
            runAdvancedRename(paths: request.paths)

        default:
            TuckLog.helperLogger.error("helper.handle-aborted op=\(request.operation, privacy: .public) reason=unknown-operation")
            return
        }
    }

    // MARK: - Compression

    // A single path for long-running file jobs: bounded queue, visible progress,
    // cooperative cancellation and a completion message only after the worker exits.
    private func queueOperation(title: String, operation: String, paths: [String],
                                canUndo: Bool = true,
                                historyItems: [JobItemStatus]? = nil,
                                worker: @escaping JobManager.Executor) {
        guard !paths.isEmpty else { return }
        let window = ProgressWindow()
        let jobId = JobManager.shared.enqueue(
            title: title, operation: operation, paths: paths, canUndo: canUndo,
            historyItems: historyItems,
            onComplete: { [weak self] job in
                window.dismiss()
                switch job.status {
                case .completed:
                    self?.report("Created \(job.outputs.count) output file(s). Open Settings → Activity to review results.", title: title)
                case .partial:
                    self?.report(job.progressDetail + "\nSee Activity for the failed filenames and reasons.", title: "\(title) partially completed")
                case .failed:
                    self?.report(job.progressDetail, title: "\(title) failed")
                case .cancelled:
                    if !job.outputs.isEmpty {
                        self?.report("Cancelled after publishing some results. Review Activity before retrying.", title: title)
                    }
                case .queued, .running: break
                }
            },
            executor: { token, progress in
                try await worker(token, { fraction, detail in
                    progress(fraction, detail)
                    Task { @MainActor in window.update(fraction: fraction, detail: detail) }
                })
            }
        )
        window.present(title: title, onCancel: { JobManager.shared.cancel(jobId: jobId) })
    }

    private func runCompression(paths: [String], target: CompressionTarget, operation: String) {
        queueOperation(title: "Compress under \(target.description)", operation: operation, paths: paths) { token, progress in
            let outcome = CompressionEngine.compress(
                paths: paths, target: target,
                progress: { update in
                    progress(update.fraction, update.fileName.isEmpty ? update.note : "\(update.fileName): \(update.note)")
                },
                shouldCancel: { token.isCancelled }
            )
            let outputs = outcome.results.compactMap(\.output)
            if token.isCancelled && outputs.isEmpty { throw CancellationError() }
            var failures = outcome.failures.map {
                JobFailure(inputPath: $0.0.path, reason: $0.1.description)
            }
            if outputs.isEmpty && failures.isEmpty {
                failures.append(JobFailure(inputPath: paths[0], reason: "No output was created."))
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    private func runZip(paths: [String]) {
        queueOperation(title: "Create ZIP archive", operation: "zip", paths: paths) { token, progress in
            let result = try FileWork.zip(paths, progress: { fraction in
                progress(fraction, "Creating archive…")
            }, shouldCancel: { token.isCancelled })
            // The archive may already have been published when cancellation arrives.
            return JobOutcome(outputs: [result.file])
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? CompressionFailure { return failure.description }
        return error.localizedDescription
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

    private func promptForResize() -> String? {
        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Enter dimensions (e.g. '800x600', '1920' for max edge, or '50%' for scale)."
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "1920")
        field.frame = NSRect(x: 0, y: 0, width: 290, height: 24)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - PDF Toolkit Handlers

    private func runPDFMerge(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        queueOperation(title: "Merge into PDF", operation: "pdfMerge", paths: paths) { token, progress in
            let merged = try PDFToolkit.merge(urls: urls, progress: progress, shouldCancel: { token.isCancelled })
            return JobOutcome(outputs: [merged])
        }
    }

    private func runPDFSplit(paths: [String], customRange: Bool) {
        guard let first = paths.first else { return }
        let url = URL(fileURLWithPath: first)
        var rangeDesc = "each"
        if customRange {
            let alert = NSAlert()
            alert.messageText = "Split PDF by Page Range"
            alert.informativeText = "Enter page numbers and ranges (e.g. '1-3,5,8-12'):"
            alert.addButton(withTitle: "Split")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: "1-3")
            field.frame = NSRect(x: 0, y: 0, width: 290, height: 24)
            alert.accessoryView = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            rangeDesc = field.stringValue
        }
        let selectedRange = rangeDesc
        queueOperation(title: "Split PDF", operation: "pdfSplit", paths: [first]) { token, progress in
            do {
                let outputs = try PDFToolkit.split(url: url, rangeDescription: selectedRange,
                                                   progress: progress, shouldCancel: { token.isCancelled })
                if token.isCancelled && outputs.isEmpty { throw CancellationError() }
                guard !outputs.isEmpty else { throw UndoError.unsafe("No PDF pages were extracted.") }
                return JobOutcome(outputs: outputs)
            } catch let partial as PartialPDFSplitError {
                return JobOutcome(outputs: partial.outputs,
                                  failures: [JobFailure(inputPath: first, reason: partial.failureDescription)])
            }
        }
    }

    private func runPDFRotate(paths: [String], degrees: Int) {
        queueOperation(title: "Rotate PDF pages", operation: "pdfRotate", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                progress(Double(index) / Double(paths.count), URL(fileURLWithPath: path).lastPathComponent)
                do {
                    outputs.append(try PDFToolkit.rotate(url: URL(fileURLWithPath: path), degrees: degrees))
                } catch {
                    failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                }
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    private func runPDFOCR(paths: [String]) {
        queueOperation(title: "Recognize PDF text", operation: "pdfOCR", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                let start = Double(index) / Double(paths.count)
                let source = URL(fileURLWithPath: path)
                do {
                    let output = try PDFToolkit.ocr(url: source, progress: { fraction, note in
                        progress(start + fraction / Double(paths.count), note)
                    }, shouldCancel: { token.isCancelled })
                    outputs.append(output)
                } catch {
                    if !token.isCancelled {
                        failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                    }
                }
            }
            if token.isCancelled && outputs.isEmpty { throw CancellationError() }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    private func runPDFExtractImages(paths: [String]) {
        queueOperation(title: "Extract PDF images", operation: "pdfExtractImages", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                progress(Double(index) / Double(paths.count), URL(fileURLWithPath: path).lastPathComponent)
                do {
                    let files = try PDFToolkit.extractImages(url: URL(fileURLWithPath: path))
                    if files.isEmpty {
                        failures.append(JobFailure(inputPath: path, reason: "No embedded raster assets found."))
                    } else {
                        outputs.append(contentsOf: files)
                    }
                } catch {
                    failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                }
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    private func runPDFToImages(paths: [String]) {
        queueOperation(title: "Export PDF pages as images", operation: "pdfToImages", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                progress(Double(index) / Double(paths.count), URL(fileURLWithPath: path).lastPathComponent)
                do {
                    let files = try PDFToolkit.renderPagesToImages(url: URL(fileURLWithPath: path))
                    if files.isEmpty {
                        failures.append(JobFailure(inputPath: path, reason: "No pages could be rendered."))
                    } else {
                        outputs.append(contentsOf: files)
                    }
                } catch {
                    failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                }
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    // MARK: - Image Toolkit Handlers

    private func runImageConvert(paths: [String], targetFormat: String) {
        queueOperation(title: "Convert images to \(targetFormat.uppercased())", operation: "imageConvert", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                progress(Double(index) / Double(paths.count), url.lastPathComponent)
                do {
                    outputs.append(try ImageToolkit.convert(
                        url: url, targetFormat: targetFormat,
                        progress: { fraction, detail in
                            progress((Double(index) + fraction) / Double(paths.count), detail)
                        }, shouldCancel: { token.isCancelled }))
                } catch {
                    if !token.isCancelled {
                        failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                    }
                }
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    private func runImageResize(paths: [String], spec: String) {
        let mode: ResizeMode
        if spec.hasPrefix("pct:") {
            mode = .percentage(Double(spec.dropFirst(4)) ?? 50)
        } else if spec.contains("x") {
            let dims = spec.components(separatedBy: "x")
            mode = .exact(width: dims.first.flatMap(Int.init) ?? 800,
                          height: dims.last.flatMap(Int.init) ?? 600)
        } else if let edge = Int(spec) {
            mode = .longestEdge(edge)
        } else {
            mode = .percentage(50)
        }
        queueOperation(title: "Resize images", operation: "imageResize", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                progress(Double(index) / Double(paths.count), url.lastPathComponent)
                do {
                    outputs.append(try ImageToolkit.resize(
                        url: url, mode: mode,
                        progress: { fraction, detail in
                            progress((Double(index) + fraction) / Double(paths.count), detail)
                        }, shouldCancel: { token.isCancelled }))
                } catch {
                    if !token.isCancelled {
                        failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                    }
                }
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    // MARK: - Metadata Handlers

    private func runMetadataInspect(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        // PDFKit inspection and hashing can be expensive. Never perform them
        // on the helper's UI actor while Finder waits for a response.
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = urls.map { MetadataToolkit.inspect(url: $0).summary }
                .joined(separator: "\n\n--------------------\n\n")
            await self?.showMetadataInspection(text)
        }
    }

    private func showMetadataInspection(_ text: String) {
        report(text, title: "Metadata Inspector")
    }

    private func runMetadataStrip(paths: [String]) {
        queueOperation(title: "Strip file metadata", operation: "metaStrip", paths: paths) { token, progress in
            var outputs: [URL] = []
            var failures: [JobFailure] = []
            for (index, path) in paths.enumerated() {
                if token.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                progress(Double(index) / Double(paths.count), url.lastPathComponent)
                do {
                    outputs.append(try MetadataToolkit.strip(url: url))
                } catch {
                    failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                }
            }
            return JobOutcome(outputs: outputs, failures: failures)
        }
    }

    // MARK: - Copy As & Advanced Rename

    private func runCopyAs(paths: [String], format: CopyAsFormat) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if format == .sha256 {
            // Hashing large selected files must not block the Settings app.
            Task.detached(priority: .userInitiated) { [weak self] in
                let text = CopyAsToolkit.format(urls: urls, format: format)
                await self?.finishCopyAs(text: text, count: urls.count, format: format)
            }
        } else {
            finishCopyAs(text: CopyAsToolkit.format(urls: urls, format: format),
                         count: urls.count, format: format)
        }
    }

    private func finishCopyAs(text: String, count: Int, format: CopyAsFormat) {
        CopyAsToolkit.copyToClipboard(text: text)
        report("Copied \(count) item(s) as \(format.rawValue) to clipboard:\n\n\(text)",
               title: "Copied to Clipboard")
    }

    private func runTransfer(paths: [String], argument: String?, mode: TransferMode) {
        guard let argument else { return }
        let folder: URL
        if argument == "choose" {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.message = "Choose destination for \(mode == .move ? "Move" : "Copy")"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            folder = chosen
        } else {
            guard let id = UUID(uuidString: argument),
                  let favorite = FavoritePreferences.all.first(where: { $0.id == id }) else {
                report("The chosen favourite is no longer available.", title: "Destination Missing")
                return
            }
            do { folder = try favorite.resolve() }
            catch {
                report("The saved folder is missing or disconnected. Choose another destination.",
                       title: "Destination Unavailable")
                return
            }
        }
        if mode == .move {
            let confirm = NSAlert()
            confirm.messageText = "Move \(paths.count) selected item(s)?"
            confirm.informativeText = "Destination: \(folder.path)\n\nTuck will never overwrite an existing item. Cross-volume moves copy, verify, then remove unchanged originals."
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Move")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        let undoable = mode == .copy && paths.allSatisfy {
            (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        queueOperation(title: mode == .copy ? "Copy to Folder" : "Move to Folder",
                       operation: mode == .copy ? "copyTo" : "moveTo", paths: paths,
                       canUndo: undoable) { token, progress in
            try FileTransfer.transfer(paths: paths, to: folder, mode: mode,
                                      isCancelled: { token.isCancelled }, progress: progress)
        }
    }

    private func runAdvancedRename(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Advanced Batch Rename"
        alert.informativeText = "Configure find and replace for selected filenames."
        alert.addButton(withTitle: "Preview")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        let findField = NSTextField(string: "")
        findField.placeholderString = "Find text"
        let replaceField = NSTextField(string: "")
        replaceField.placeholderString = "Replace with"
        stack.addArrangedSubview(findField)
        stack.addArrangedSubview(replaceField)
        stack.frame = NSRect(x: 0, y: 0, width: 330, height: 60)
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !findField.stringValue.isEmpty else {
            report("Enter a nonempty search term before renaming.", title: "Invalid Rename")
            return
        }

        let rule = RenameRule(op: .findReplace(
            find: findField.stringValue, replace: replaceField.stringValue, isRegex: false))
        let plan = AdvancedRenameToolkit.preview(urls: urls, rule: rule)
        let collisions = plan.filter(\.hasCollision)
        guard collisions.isEmpty else {
            report("Conflicting destination names detected:\n" +
                   collisions.prefix(12).map(\.proposedName).joined(separator: "\n"),
                   title: "Rename Cannot Proceed")
            return
        }

        let preview = NSAlert()
        preview.messageText = "Review \(plan.count) Proposed Rename(s)"
        let rows = plan.prefix(18).map {
            "\($0.originalURL.lastPathComponent) → \($0.proposedName)"
        }.joined(separator: "\n")
        preview.informativeText = rows + (plan.count > 18 ? "\n… and \(plan.count - 18) more" : "")
        preview.addButton(withTitle: "Rename Files")
        preview.addButton(withTitle: "Cancel")
        guard preview.runModal() == .alertFirstButtonReturn else { return }

        let items = plan.map {
            JobItemStatus(inputPath: $0.originalURL.path,
                          outputPath: $0.proposedURL.path, status: .queued)
        }
        queueOperation(title: "Rename \(plan.count) file(s)", operation: "advancedRename",
                       paths: paths, historyItems: items) { token, progress in
            if token.isCancelled { throw CancellationError() }
            progress(0.05, "Applying reviewed filename changes…")
            let outputs = try AdvancedRenameToolkit.execute(plan: plan)
            progress(1, "Rename complete")
            return JobOutcome(outputs: outputs)
        }
    }

    private func report(_ message: String, title: String = "Tuck") {
        TuckLog.helperLogger.error("helper.reported title=\(title, privacy: .public) detail=\(message, privacy: .private)")
        let alert = NSAlert()
        alert.messageText = title
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
