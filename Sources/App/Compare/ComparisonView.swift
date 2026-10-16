import AppKit
import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Optional, read-only result inspection. No re-encoding, no destructive actions,
/// and thumbnails capped to the visible preview resolution.
@MainActor
enum ComparisonWindow {
    private static var windows: [UUID: NSWindow] = [:]
    private static let images = Set(["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "webp"])
    static func supported(source: URL, output: URL) -> Bool {
        let a = source.pathExtension.lowercased(), b = output.pathExtension.lowercased()
        return (a == "pdf" && b == "pdf") || (images.contains(a) && images.contains(b))
    }
    static func show(source: URL, output: URL) {
        let id = UUID()
        let view = ComparisonView(source: source, output: output)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Compare — \(source.lastPathComponent)"
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeValue(forKey: id) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct ComparisonView: View {
    let source: URL
    let output: URL
    @State private var page = 0
    @State private var split = false
    @State private var fraction: Double = 0.5
    @State private var zoom: Double = 1

    private var pdf: Bool { source.pathExtension.lowercased() == "pdf" &&
        output.pathExtension.lowercased() == "pdf" }
    private var sourcePDF: PDFDocument? { pdf ? PDFDocument(url: source) : nil }
    private var outputPDF: PDFDocument? { pdf ? PDFDocument(url: output) : nil }
    private var pageLimit: Int { min(sourcePDF?.pageCount ?? 0, outputPDF?.pageCount ?? 0) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Before & After").font(.title2.weight(.semibold))
                    Text("\(source.lastPathComponent) → \(output.lastPathComponent)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Picker("Layout", selection: $split) {
                    Text("Side by side").tag(false)
                    Text("Slider").tag(true)
                }.pickerStyle(.segmented).frame(width: 240)
                Button("Reveal Output") {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            }
            HStack(spacing: 12) {
                Text("Original: \(sizeString(source))")
                Text("Result: \(sizeString(output))")
                if let before = bytes(source), let after = bytes(output), before > 0 {
                    Text(String(format: "%.1f%% smaller", (1 - Double(after) / Double(before)) * 100))
                }
                Spacer()
                if pdf {
                    Text("Pages: \(sourcePDF?.pageCount ?? 0) → \(outputPDF?.pageCount ?? 0)")
                    Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0)
                    Text("\(page + 1) / \(max(pageLimit, 1))")
                    Button { page = min(max(pageLimit - 1, 0), page + 1) } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(page + 1 >= pageLimit)
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Zoom")
                Slider(value: $zoom, in: 0.5...2, step: 0.1).frame(width: 135)
                Text("\(Int(zoom * 100))%").monospacedDigit()
                Spacer()
                if split {
                    Text("Before")
                    Slider(value: $fraction, in: 0...1)
                        .accessibilityLabel("Before after split position")
                    Text("After")
                }
            }.font(.caption)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let height = max(1, geometry.size.height)
                if split {
                    ZStack(alignment: .leading) {
                        preview(output, name: "After").frame(width: width, height: height)
                        preview(source, name: "Before")
                            .frame(width: width, height: height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: width * fraction)
                            }
                        Rectangle().fill(.primary.opacity(0.55))
                            .frame(width: 1, height: height)
                            .offset(x: width * fraction)
                    }
                    .frame(width: width, height: height)
                } else {
                    HStack(spacing: 12) {
                        preview(source, name: "Before")
                        preview(output, name: "After")
                    }
                }
            }
            if pdf && (sourcePDF?.pageCount != outputPDF?.pageCount) {
                Label("The two PDFs have different page counts. Check structure and text separately.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Read-only preview; files are not recompressed or changed. PDFs show rasterized page previews, not selectable text validation.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder private func preview(_ url: URL, name: String) -> some View {
        VStack(spacing: 6) {
            Text(name).font(.headline)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .textBackgroundColor))
                    if let image = thumbnail(url, maxDimension: 1600) {
                        Image(nsImage: image)
                            .resizable().interpolation(.high).scaledToFit()
                            .scaleEffect(zoom)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .accessibilityLabel("\(name) preview, \(url.lastPathComponent)")
                    } else {
                        ContentUnavailableView("Preview unavailable",
                            systemImage: "doc.questionmark",
                            description: Text("The file is missing, unsupported, encrypted, or unreadable."))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thumbnail(_ url: URL, maxDimension: Int) -> NSImage? {
        if pdf {
            guard let doc = PDFDocument(url: url),
                  page < doc.pageCount, let pdfPage = doc.page(at: page) else { return nil }
            return pdfPage.thumbnail(of: NSSize(width: maxDimension, height: maxDimension),
                                     for: .mediaBox)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
    private func bytes(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
    private func sizeString(_ url: URL) -> String {
        guard let count = bytes(url) else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
