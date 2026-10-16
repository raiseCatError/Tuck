import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum PDFMergeError: LocalizedError, Sendable {
    case noInputs
    case unreadableFile(String)
    case encryptedFile(String)
    case failedToCreateDocument
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "No valid PDF or image files selected to merge."
        case .unreadableFile(let path):
            return "Unable to decode or read: \(path)"
        case .encryptedFile(let path):
            return "PDF is password-protected or encrypted: \(path)"
        case .failedToCreateDocument:
            return "Failed to initialize target PDF document."
        case .writeFailed:
            return "Failed to write merged PDF to disk."
        }
    }
}

/// An error after some PDF pages have already been published. The caller must
/// keep these outputs in Activity and offer safe cleanup/Undo.
public struct PartialPDFSplitError: LocalizedError, Sendable {
    public let outputs: [URL]
    public let failureDescription: String
    public var errorDescription: String? { failureDescription }
}

public enum PDFToolkit {

    /// Merges an array of file URLs (PDFs and images) into a single combined multipage PDF.
    /// Preserves original PDF page structure, aspect ratio of images, and orientations.
    /// Returns the published output URL.
    public static func merge(urls: [URL],
                             outputName: String = "Merged.pdf",
                             progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                             shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> URL {
        guard !urls.isEmpty else { throw PDFMergeError.noInputs }
        let destinationDir = urls[0].deletingLastPathComponent()

        let combined = PDFDocument()
        var pageInsertIndex = 0

        for (fileIndex, url) in urls.enumerated() {
            if shouldCancel() { throw CancellationError() }
            let frac = Double(fileIndex) / Double(urls.count)
            progress(frac, "Processing \(url.lastPathComponent)…")

            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let doc = PDFDocument(url: url) else {
                    throw PDFMergeError.unreadableFile(url.lastPathComponent)
                }
                if doc.isEncrypted || doc.isLocked {
                    throw PDFMergeError.encryptedFile(url.lastPathComponent)
                }
                for p in 0..<doc.pageCount {
                    if shouldCancel() { throw CancellationError() }
                    guard let page = doc.page(at: p) else { continue }
                    combined.insert(page, at: pageInsertIndex)
                    pageInsertIndex += 1
                }
            } else if ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "webp", "gif"].contains(ext) {
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    throw PDFMergeError.unreadableFile(url.lastPathComponent)
                }
                
                // Get orientation from image properties if available
                var orientation: CGImagePropertyOrientation = .up
                if let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                   let rawVal = props[kCGImagePropertyOrientation] as? UInt32,
                   let parsed = CGImagePropertyOrientation(rawValue: rawVal) {
                    orientation = parsed
                }

                guard let page = makePDFPage(from: cgImage, orientation: orientation) else {
                    throw PDFMergeError.unreadableFile(url.lastPathComponent)
                }
                combined.insert(page, at: pageInsertIndex)
                pageInsertIndex += 1
            }
        }

        guard combined.pageCount > 0 else {
            throw PDFMergeError.noInputs
        }

        progress(0.95, "Writing Merged.pdf…")
        let tempTarget = destinationDir.appendingPathComponent(".tuck-merge-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempTarget) }

        guard combined.write(to: tempTarget) else {
            throw PDFMergeError.writeFailed
        }

        let published = try OutputName.publish(tempTarget, beside: urls[0], suffix: "", extraExtension: "pdf")
        // If OutputName gave something like "original.pdf", rename/ensure Merged.pdf collision-safe
        return published
    }

    /// Wraps a CGImage into a PDFPage without quality downsampling or pixel aspect distortion.
    public static func makePDFPage(from image: CGImage, orientation: CGImagePropertyOrientation = .up) -> PDFPage? {
        var width = CGFloat(image.width)
        var height = CGFloat(image.height)
        if orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored {
            swap(&width, &height)
        }
        
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            return nil
        }
        
        var mediaBox = bounds
        context.beginPage(mediaBox: &mediaBox)
        context.saveGState()

        // Handle orientation transform inside the PDF page context
        switch orientation {
        case .up:
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .down:
            context.translateBy(x: width, y: height)
            context.rotate(by: .pi)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .left:
            context.translateBy(x: width, y: 0)
            context.rotate(by: .pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
        case .right:
            context.translateBy(x: 0, y: height)
            context.rotate(by: -.pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
        case .upMirrored:
            context.translateBy(x: width, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .downMirrored:
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .leftMirrored:
            context.translateBy(x: width, y: height)
            context.rotate(by: .pi / 2)
            context.scaleBy(x: -1, y: 1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
        case .rightMirrored:
            context.rotate(by: -.pi / 2)
            context.scaleBy(x: -1, y: 1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: height, height: width))
        }

        context.restoreGState()
        context.endPage()
        context.closePDF()

        guard let generated = PDFDocument(data: pdfData as Data),
              let page = generated.page(at: 0) else {
            return nil
        }
        return page
    }

    /// Parses page ranges like "1-3,5,8-12" or "all" into a 0-indexed set of page numbers.
    public static func parsePageRanges(_ string: String, pageCount: Int) -> [Int] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "all" || trimmed.isEmpty {
            return Array(0..<pageCount)
        }
        var pages = Set<Int>()
        let components = trimmed.components(separatedBy: ",")
        for comp in components {
            let part = comp.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.contains("-") {
                let rangeParts = part.components(separatedBy: "-")
                if rangeParts.count == 2,
                   let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                   let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) {
                    let s = max(1, min(start, end))
                    let e = min(pageCount, max(start, end))
                    if s <= e {
                        for p in s...e { pages.insert(p - 1) }
                    }
                }
            } else if let single = Int(part) {
                if single >= 1 && single <= pageCount {
                    pages.insert(single - 1)
                }
            }
        }
        return pages.sorted()
    }

    /// Splits a PDF by page ranges or into individual pages. If a user
    /// cancels after some pages are published, return those paths so the Job
    /// Manager can record them rather than leaving invisible output files.
    public static func split(url: URL,
                             rangeDescription: String,
                             progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                             shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else {
            throw PDFMergeError.unreadableFile(url.lastPathComponent)
        }
        if doc.isEncrypted || doc.isLocked {
            throw PDFMergeError.encryptedFile(url.lastPathComponent)
        }
        let total = doc.pageCount
        guard total > 0 else { throw PDFMergeError.unreadableFile("Document has 0 pages") }

        let trimmed = rangeDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var outputs: [URL] = []
        do {
            if trimmed == "each" || trimmed == "single" {
                for i in 0..<total {
                    if shouldCancel() { return outputs }
                    progress(Double(i) / Double(total), "Splitting page \(i + 1) of \(total)…")
                    guard let page = doc.page(at: i) else { continue }
                    let single = PDFDocument()
                    single.insert(page, at: 0)
                    let temp = url.deletingLastPathComponent()
                        .appendingPathComponent(".tuck-split-\(UUID().uuidString).pdf")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    guard single.write(to: temp) else { throw PDFMergeError.writeFailed }
                    outputs.append(try OutputName.publish(
                        temp, beside: url, suffix: "-page-\(i + 1)", extraExtension: "pdf"))
                }
            } else {
                let indices = parsePageRanges(rangeDescription, pageCount: total)
                guard !indices.isEmpty else {
                    throw PDFMergeError.unreadableFile("No valid pages found in range: \(rangeDescription)")
                }
                let extracted = PDFDocument()
                for (newIndex, pageIndex) in indices.enumerated() {
                    if shouldCancel() { return outputs }
                    guard let page = doc.page(at: pageIndex) else { continue }
                    extracted.insert(page, at: newIndex)
                }
                let temp = url.deletingLastPathComponent()
                    .appendingPathComponent(".tuck-split-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: temp) }
                guard extracted.write(to: temp) else { throw PDFMergeError.writeFailed }
                let suffix = "-pages-\(rangeDescription.replacingOccurrences(of: " ", with: ""))"
                outputs.append(try OutputName.publish(
                    temp, beside: url, suffix: suffix, extraExtension: "pdf"))
            }
            return outputs
        } catch {
            if outputs.isEmpty { throw error }
            throw PartialPDFSplitError(outputs: outputs, failureDescription: error.localizedDescription)
        }
    }

    /// Rotates pages in a PDF document by 90, 180, or 270 degrees.
    public static func rotate(url: URL,
                              degrees: Int,
                              progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                              shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> URL {
        guard let doc = PDFDocument(url: url) else {
            throw PDFMergeError.unreadableFile(url.lastPathComponent)
        }
        let total = doc.pageCount
        for i in 0..<total {
            if shouldCancel() { throw CancellationError() }
            progress(Double(i) / Double(total), "Rotating page \(i + 1) of \(total)…")
            guard let page = doc.page(at: i) else { continue }
            page.rotation = (page.rotation + degrees) % 360
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-rotate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard doc.write(to: temp) else { throw PDFMergeError.writeFailed }
        return try OutputName.publish(temp, beside: url, suffix: "-rotated", extraExtension: "pdf")
    }

    /// Reorders pages in a PDF document given a new 0-indexed ordering of page indices.
    public static func reorder(url: URL,
                               pageOrder: [Int],
                               progress: @Sendable @escaping (Double, String) -> Void = { _, _ in }) throws -> URL {
        guard let doc = PDFDocument(url: url) else {
            throw PDFMergeError.unreadableFile(url.lastPathComponent)
        }
        let reorderedDoc = PDFDocument()
        for (newPos, origPos) in pageOrder.enumerated() {
            guard origPos >= 0, origPos < doc.pageCount, let page = doc.page(at: origPos) else { continue }
            reorderedDoc.insert(page, at: newPos)
        }
        guard reorderedDoc.pageCount > 0 else { throw PDFMergeError.noInputs }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-reorder-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard reorderedDoc.write(to: temp) else { throw PDFMergeError.writeFailed }
        return try OutputName.publish(temp, beside: url, suffix: "-reordered", extraExtension: "pdf")
    }

    /// Converts PDF pages to high-quality images (PNG format).
    public static func renderPagesToImages(url: URL,
                                          dpi: CGFloat = 300,
                                          progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                                          shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else {
            throw PDFMergeError.unreadableFile(url.lastPathComponent)
        }
        var outputs: [URL] = []
        let total = doc.pageCount
        let scale = dpi / 72.0

        for i in 0..<total {
            if shouldCancel() { throw CancellationError() }
            progress(Double(i) / Double(total), "Rendering page \(i + 1) of \(total)…")
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pixelWidth = Int(bounds.width * scale)
            let pixelHeight = Int(bounds.height * scale)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                continue
            }

            // Fill white background
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            guard let cgImage = context.makeImage() else { continue }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-page-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temp) }

            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { continue }

            let pub = try OutputName.publish(temp, beside: url, suffix: "-page-\(i + 1)", extraExtension: "png")
            outputs.append(pub)
        }
        return outputs
    }

    /// Extracts embedded images from a PDF using pdfimages if available, falling back to page rendering if no images found.
    public static func extractImages(url: URL,
                                     progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                                     shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> [URL] {
        let parentDir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let outputFolder = parentDir.appendingPathComponent("\(stem)-images", isDirectory: true)

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        var extractedURLs: [URL] = []

        // Try pdfimages tool first
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/pdfimages") {
            let prefix = outputFolder.appendingPathComponent("img").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pdfimages")
            process.arguments = ["-png", url.path, prefix]
            try? process.run()
            process.waitUntilExit()

            let contents = (try? FileManager.default.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: nil)) ?? []
            extractedURLs = contents.filter { $0.pathExtension.lowercased() == "png" || $0.pathExtension.lowercased() == "jpg" }
        }

        // If no embedded images extracted or tool unavailable, do not claim page screenshots are extracted images
        if extractedURLs.isEmpty {
            progress(1.0, "No embedded raster assets found in document.")
        }

        return extractedURLs
    }

    /// Performs on-device Optical Character Recognition (OCR) via Apple Vision framework.
    /// Injects an invisible searchable text layer positioned over the original PDF imagery.
    public static func ocr(url: URL,
                           progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                           shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> URL {
        guard let doc = PDFDocument(url: url) else {
            throw PDFMergeError.unreadableFile(url.lastPathComponent)
        }
        let total = doc.pageCount
        guard total > 0 else { throw PDFMergeError.unreadableFile("Empty document") }

        let searchableDoc = PDFDocument()

        for i in 0..<total {
            if shouldCancel() { throw CancellationError() }
            progress(Double(i) / Double(total), "Recognizing text on page \(i + 1) of \(total)…")
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)

            // Render page at 300 DPI for optimal Vision accuracy
            let scale: CGFloat = 300.0 / 72.0
            let pixelW = Int(bounds.width * scale)
            let pixelH = Int(bounds.height * scale)

            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                searchableDoc.insert(page, at: searchableDoc.pageCount)
                continue
            }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            guard let renderedPageImg = ctx.makeImage() else {
                searchableDoc.insert(page, at: searchableDoc.pageCount)
                continue
            }

            // Run VNRecognizeTextRequest
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: renderedPageImg, options: [:])
            try? handler.perform([request])

            guard let observations = request.results, !observations.isEmpty else {
                searchableDoc.insert(page, at: searchableDoc.pageCount)
                continue
            }

            // Create new searchable PDF page with original graphic + invisible text layer
            let pagePDFData = NSMutableData()
            guard let consumer = CGDataConsumer(data: pagePDFData as CFMutableData),
                  let pdfCtx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
                searchableDoc.insert(page, at: searchableDoc.pageCount)
                continue
            }

            var mediaBox = bounds
            pdfCtx.beginPage(mediaBox: &mediaBox)

            // Draw original page appearance
            pdfCtx.saveGState()
            page.draw(with: .mediaBox, to: pdfCtx)
            pdfCtx.restoreGState()

            // Invert coordinate space for text placement
            // Vision coordinates are normalized (0,0 bottom-left to 1,1 top-right)
            for obs in observations {
                guard let topCandidate = obs.topCandidates(1).first else { continue }
                let text = topCandidate.string

                // Bounding box in PDF point space
                let normBox = obs.boundingBox
                let box = CGRect(
                    x: normBox.origin.x * bounds.width,
                    y: normBox.origin.y * bounds.height,
                    width: normBox.size.width * bounds.width,
                    height: normBox.size.height * bounds.height
                )

                // Invisible text rendering
                pdfCtx.saveGState()
                pdfCtx.setTextDrawingMode(.invisible)
                let fontSize = max(8.0, box.height * 0.85)
                let font = NSFont.systemFont(ofSize: fontSize)
                let attrString = NSAttributedString(string: text, attributes: [
                    .font: font
                ])
                let line = CTLineCreateWithAttributedString(attrString)
                pdfCtx.textPosition = CGPoint(x: box.origin.x, y: box.origin.y + (box.height - fontSize) / 2)
                CTLineDraw(line, pdfCtx)
                pdfCtx.restoreGState()
            }

            pdfCtx.endPage()
            pdfCtx.closePDF()

            if let newPageDoc = PDFDocument(data: pagePDFData as Data),
               let newPage = newPageDoc.page(at: 0) {
                searchableDoc.insert(newPage, at: searchableDoc.pageCount)
            } else {
                searchableDoc.insert(page, at: searchableDoc.pageCount)
            }
        }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard searchableDoc.write(to: temp) else { throw PDFMergeError.writeFailed }
        return try OutputName.publish(temp, beside: url, suffix: "-ocr", extraExtension: "pdf")
    }
}
