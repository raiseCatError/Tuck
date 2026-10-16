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
                                worker: @escaping JobManager.Executor) {
        guard !paths.isEmpty else { return }
        let window = ProgressWindow()
        let jobId = JobManager.shared.enqueue(
            title: title, operation: operation, paths: paths, canUndo: canUndo,
            onComplete: { [weak self] job in
                window.dismiss()
                switch job.status {
                case .completed:
                    self?.report("Created \(job.outputs.count) output file(s). Open Settings → Activity to review results.", title: title)
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
            if token.isCancelled { throw CancellationError() }
            let outputs = outcome.results.compactMap(\.output)
            if outputs.isEmpty {
                let details = outcome.failures.map { "\($0.0.lastPathComponent): \($0.1.description)" }
                throw UndoError.unsafe(details.isEmpty ? "Nothing was compressed." : details.joined(separator: "\n"))
            }
            if !outcome.failures.isEmpty {
                progress(1, "Completed \(outputs.count) with \(outcome.failures.count) failed input(s).")
            }
            return outputs
        }
    }

    private func runZip(paths: [String]) {
        queueOperation(title: "Create ZIP archive", operation: "zip", paths: paths) { token, progress in
            let result = try FileWork.zip(paths, progress: { fraction in
                progress(fraction, "Creating archive…")
            }, shouldCancel: { token.isCancelled })
            if token.isCancelled { throw CancellationError() }
            return [result.file]
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
        let progress = ProgressWindow()
        let cancelled = CancellationFlag()
        progress.present(title: "Merging into PDF", onCancel: { cancelled.cancel() })

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let merged = try PDFToolkit.merge(urls: urls, progress: { frac, note in
                    Task { @MainActor in progress.update(fraction: frac, detail: note) }
                }, shouldCancel: { cancelled.isCancelled })

                await MainActor.run {
                    progress.dismiss()
                    let record = JobRecord(
                        title: "Merge \(urls.count) item(s) to PDF",
                        operation: "pdfMerge",
                        finishedAt: Date(),
                        status: .completed,
                        progress: 1.0,
                        progressDetail: "Created \(merged.lastPathComponent)",
                        items: paths.map { JobItemStatus(inputPath: $0) },
                        outputs: [merged.path],
                        canUndo: true
                    )
                    JobManager.shared.recordCompletedJob(record)

                    NSWorkspace.shared.activateFileViewerSelecting([merged])
                    self?.report("Saved merged document as:\n\(merged.lastPathComponent)", title: "PDF Merged")
                }
            } catch {
                await MainActor.run {
                    progress.dismiss()
                    self?.report(error.localizedDescription, title: "PDF Merge Failed")
                }
            }
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

        let progress = ProgressWindow()
        let cancelled = CancellationFlag()
        progress.present(title: "Splitting PDF", onCancel: { cancelled.cancel() })

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let outputs = try PDFToolkit.split(url: url, rangeDescription: rangeDesc, progress: { frac, note in
                    Task { @MainActor in progress.update(fraction: frac, detail: note) }
                }, shouldCancel: { cancelled.isCancelled })

                await MainActor.run {
                    progress.dismiss()
                    if !outputs.isEmpty {
                        let record = JobRecord(
                            title: "Split PDF (\(outputs.count) pages/parts)",
                            operation: "pdfSplit",
                            finishedAt: Date(),
                            status: .completed,
                            progress: 1.0,
                            progressDetail: "Created \(outputs.count) PDF(s)",
                            items: [JobItemStatus(inputPath: first)],
                            outputs: outputs.map(\.path),
                            canUndo: true
                        )
                        JobManager.shared.recordCompletedJob(record)
                        NSWorkspace.shared.activateFileViewerSelecting(outputs)
                    }
                    self?.report("Created \(outputs.count) split PDF(s).", title: "PDF Split Complete")
                }
            } catch {
                await MainActor.run {
                    progress.dismiss()
                    self?.report(error.localizedDescription, title: "PDF Split Failed")
                }
            }
        }
    }

    private func runPDFRotate(paths: [String], degrees: Int) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var outputs: [URL] = []
        for url in urls {
            if let rotated = try? PDFToolkit.rotate(url: url, degrees: degrees) {
                outputs.append(rotated)
            }
        }
        if !outputs.isEmpty {
            let record = JobRecord(
                title: "Rotate \(outputs.count) PDF(s) \(degrees)°",
                operation: "pdfRotate",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Rotated \(outputs.count) file(s)",
                items: paths.map { JobItemStatus(inputPath: $0) },
                outputs: outputs.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            report("Rotated \(outputs.count) document(s) by \(degrees)°.", title: "PDF Rotated")
        }
    }

    private func runPDFOCR(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let progress = ProgressWindow()
        let cancelled = CancellationFlag()
        progress.present(title: "Running On-Device OCR", onCancel: { cancelled.cancel() })

        Task.detached(priority: .userInitiated) { [weak self] in
            var outputs: [URL] = []
            for (idx, url) in urls.enumerated() {
                if cancelled.isCancelled { break }
                let frac = Double(idx) / Double(urls.count)
                Task { @MainActor in progress.update(fraction: frac, detail: url.lastPathComponent) }
                if let ocrOutput = try? PDFToolkit.ocr(url: url, progress: { p, n in
                    Task { @MainActor in progress.update(fraction: frac + (p / Double(urls.count)), detail: n) }
                }, shouldCancel: { cancelled.isCancelled }) {
                    outputs.append(ocrOutput)
                }
            }
            await MainActor.run {
                progress.dismiss()
                if !outputs.isEmpty {
                    let record = JobRecord(
                        title: "OCR \(outputs.count) PDF(s)",
                        operation: "pdfOCR",
                        finishedAt: Date(),
                        status: .completed,
                        progress: 1.0,
                        progressDetail: "Created \(outputs.count) searchable PDF(s)",
                        items: paths.map { JobItemStatus(inputPath: $0) },
                        outputs: outputs.map(\.path),
                        canUndo: true
                    )
                    JobManager.shared.recordCompletedJob(record)
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
                self?.report("Generated \(outputs.count) searchable OCR PDF(s).", title: "OCR Complete")
            }
        }
    }

    private func runPDFExtractImages(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var totalImages: [URL] = []
        for url in urls {
            if let extracted = try? PDFToolkit.extractImages(url: url) {
                totalImages.append(contentsOf: extracted)
            }
        }
        if !totalImages.isEmpty {
            let record = JobRecord(
                title: "Extract Images (\(totalImages.count) assets)",
                operation: "pdfExtractImages",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Extracted \(totalImages.count) asset(s)",
                items: paths.map { JobItemStatus(inputPath: $0) },
                outputs: totalImages.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)
            NSWorkspace.shared.activateFileViewerSelecting(totalImages)
            report("Extracted \(totalImages.count) image assets.", title: "Images Extracted")
        } else {
            report("No image assets could be extracted.", title: "Image Extraction")
        }
    }

    private func runPDFToImages(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var totalImages: [URL] = []
        for url in urls {
            if let rendered = try? PDFToolkit.renderPagesToImages(url: url) {
                totalImages.append(contentsOf: rendered)
            }
        }
        if !totalImages.isEmpty {
            let record = JobRecord(
                title: "Render Pages to Images (\(totalImages.count) pages)",
                operation: "pdfToImages",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Rendered \(totalImages.count) page(s)",
                items: paths.map { JobItemStatus(inputPath: $0) },
                outputs: totalImages.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)
            NSWorkspace.shared.activateFileViewerSelecting(totalImages)
            report("Rendered \(totalImages.count) page image(s).", title: "Pages Converted")
        }
    }

    // MARK: - Image Toolkit Handlers

    private func runImageConvert(paths: [String], targetFormat: String) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var outputs: [URL] = []
        var failures: [String] = []

        for url in urls {
            do {
                let converted = try ImageToolkit.convert(url: url, targetFormat: targetFormat)
                outputs.append(converted)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !outputs.isEmpty {
            let record = JobRecord(
                title: "Convert to \(targetFormat.uppercased())",
                operation: "imageConvert",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Converted \(outputs.count) file(s)",
                items: paths.map { JobItemStatus(inputPath: $0) },
                outputs: outputs.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if !failures.isEmpty {
            report(failures.joined(separator: "\n"), title: "Conversion Issues")
        } else if !outputs.isEmpty {
            report("Converted \(outputs.count) image(s) to \(targetFormat.uppercased()).", title: "Conversion Finished")
        }
    }

    private func runImageResize(paths: [String], spec: String) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let mode: ResizeMode
        if spec.hasPrefix("pct:") {
            let pct = Double(spec.dropFirst(4)) ?? 50.0
            mode = .percentage(pct)
        } else if spec.contains("x") {
            let parts = spec.components(separatedBy: "x")
            let w = parts.first.flatMap(Int.init) ?? 800
            let h = parts.last.flatMap(Int.init) ?? 600
            mode = .exact(width: w, height: h)
        } else if let edge = Int(spec) {
            mode = .longestEdge(edge)
        } else {
            mode = .percentage(50)
        }

        var outputs: [URL] = []
        for url in urls {
            if let resized = try? ImageToolkit.resize(url: url, mode: mode) {
                outputs.append(resized)
            }
        }
        if !outputs.isEmpty {
            let record = JobRecord(
                title: "Resize \(outputs.count) image(s)",
                operation: "imageResize",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Resized \(outputs.count) image(s)",
                items: paths.map { JobItemStatus(inputPath: $0) },
                outputs: outputs.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            report("Resized \(outputs.count) image(s).", title: "Resize Complete")
        }
    }

    // MARK: - Metadata Handlers

    private func runMetadataInspect(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let reports = urls.map { MetadataToolkit.inspect(url: $0).summary }
        report(reports.joined(separator: "\n\n--------------------\n\n"), title: "Metadata Inspector")
    }

    private func runMetadataStrip(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var outputs: [URL] = []
        for url in urls {
            if let stripped = try? MetadataToolkit.strip(url: url) {
                outputs.append(stripped)
            }
        }
        if !outputs.isEmpty {
            let record = JobRecord(
                title: "Strip Metadata (\(outputs.count) files)",
                operation: "metaStrip",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Stripped \(outputs.count) file(s)",
                items: paths.map { JobItemStatus(inputPath: $0) },
                outputs: outputs.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            report("Created \(outputs.count) stripped file(s) with clean metadata.", title: "Metadata Stripped")
        }
    }

    // MARK: - Copy As & Advanced Rename

    private func runCopyAs(paths: [String], format: CopyAsFormat) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let text = CopyAsToolkit.format(urls: urls, format: format)
        CopyAsToolkit.copyToClipboard(text: text)
        report("Copied \(urls.count) item(s) as \(format.rawValue) to clipboard:\n\n\(text)", title: "Copied to Clipboard")
    }

    private func runAdvancedRename(paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Advanced Batch Rename"
        alert.informativeText = "Configure find and replace, prefix/suffix, or numbering pattern:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6

        let findField = NSTextField(string: "")
        findField.placeholderString = "Find text (or regex)"
        let replaceField = NSTextField(string: "")
        replaceField.placeholderString = "Replace with"

        stack.addArrangedSubview(findField)
        stack.addArrangedSubview(replaceField)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let rule = RenameRule(op: .findReplace(find: findField.stringValue, replace: replaceField.stringValue, isRegex: false))
        let plan = AdvancedRenameToolkit.preview(urls: urls, rule: rule)

        do {
            let renamed = try AdvancedRenameToolkit.execute(plan: plan)
            let items = plan.map { JobItemStatus(inputPath: $0.originalURL.path, outputPath: $0.proposedURL.path, status: .completed) }
            let record = JobRecord(
                title: "Rename \(renamed.count) file(s)",
                operation: "advancedRename",
                finishedAt: Date(),
                status: .completed,
                progress: 1.0,
                progressDetail: "Completed",
                items: items,
                outputs: renamed.map(\.path),
                canUndo: true
            )
            JobManager.shared.recordCompletedJob(record)

            NSWorkspace.shared.activateFileViewerSelecting(renamed)
            report("Successfully renamed \(renamed.count) file(s). You can undo this action from Settings > Activity.", title: "Rename Complete")
        } catch {
            report("Rename failed: \(error.localizedDescription)", title: "Rename Failed")
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
