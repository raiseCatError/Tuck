import Foundation
import AppKit
import PDFKit
import CoreGraphics

// PDF work. The order protects the document: structure first, images only when
// structure alone is not enough, and every candidate is verified before it can
// be published. Text, page geometry and page order must survive.

enum PDFPlan {
    struct DocumentSignature {
        let pageCount: Int
        let textLength: Int
        let annotationCount: Int
        let byteSize: Int

        var describesText: Bool { textLength > 40 }
    }

    static func signature(_ url: URL) -> DocumentSignature? {
        guard let document = PDFDocument(url: url) else { return nil }
        let text = document.string?.count ?? 0
        var annotations = 0
        for index in 0 ..< document.pageCount {
            annotations += document.page(at: index)?.annotations.count ?? 0
        }
        return DocumentSignature(pageCount: document.pageCount,
                                 textLength: text,
                                 annotationCount: annotations,
                                 byteSize: ImageFacts.byteSize(url))
    }

    /// A candidate is only usable when page count, text and interactive content
    /// are still intact.
    static func verify(_ candidate: URL, against original: DocumentSignature, keepsText: Bool) -> Result<DocumentSignature, CompressionFailure> {
        guard let signature = signature(candidate) else {
            return .failure(.verificationFailed("The result is not a readable PDF."))
        }
        guard signature.pageCount == original.pageCount else {
            return .failure(.verificationFailed("Page count changed."))
        }
        if original.describesText {
            guard keepsText else { return .failure(.verificationFailed("Text would have been rasterised.")) }
            guard signature.textLength >= Int(Double(original.textLength) * 0.98) else {
                return .failure(.verificationFailed("Searchable text was reduced from \(original.textLength) to \(signature.textLength) characters."))
            }
        }
        if original.annotationCount > 0, signature.annotationCount < original.annotationCount {
            return .failure(.verificationFailed("Annotations were lost."))
        }
        return .success(signature)
    }

    /// Structural pass. Lossless for text, fonts and vector art: object streams,
    /// maximum flate, cross reference streams.
    static func structural(source: URL, work: WorkArea, shouldCancel: @escaping @Sendable () -> Bool) -> EncodeOutcome? {
        guard let qpdf = Toolchain.qpdf else { return nil }
        let output = work.makeTemporary("qpdf-structural", extension: "pdf")
        // --deterministic-id avoids rewriting identifiers for no reason.
        let arguments = [source.path, output.path,
                         "--object-streams=generate",
                         "--compress-streams=y",
                         "--recompress-flate",
                         "--compression-level=9",
                         "--newline-before-endstream",
                         "--deterministic-id"]
        guard (try? Toolchain.run(qpdf, arguments, timeout: 600, shouldCancel: shouldCancel)) != nil else {
            work.discard(output)
            return nil
        }
        let bytes = ImageFacts.byteSize(output)
        guard bytes > 0 else { work.discard(output); return nil }
        return EncodeOutcome(file: output, bytes: bytes, lossless: true, note: "qpdf structural optimisation")
    }

    /// True when most of the bytes are images, which is the only case where
    /// recompression is worth the risk.
    static func looksImageHeavy(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        _ = source
        let total = (properties[kCGImagePropertyFileSize] as? NSNumber)?.intValue ?? 0
        _ = total
        // Sample a few pages: a page that is mostly one big image is a scan.
        guard let document = PDFDocument(url: url) else { return false }
        let pages = min(document.pageCount, 6)
        guard pages > 0 else { return false }
        var imagePages = 0
        for index in 0 ..< pages {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty, bounds.width > 200, bounds.height > 200 { imagePages += 1 }
        }
        return Double(imagePages) / Double(pages) > 0.5
    }

    /// Renders a page so two PDFs can be compared perceptually. This is the
    /// honest fidelity signal for scanned documents, where a text check says
    /// nothing.
    static func render(_ url: URL, pageIndex: Int, maxPixel: Int = 512) -> CGImage? {
        guard let document = PDFDocument(url: url), document.pageCount > pageIndex,
              let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let ratio = min(Double(maxPixel) / bounds.width, Double(maxPixel) / bounds.height)
        let size = NSSize(width: max(1, bounds.width * ratio), height: max(1, bounds.height * ratio))
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: thumbnail.size)
        return thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    static func pageFidelity(original: URL, candidate: URL) -> Double {
        guard let before = render(original, pageIndex: 0), let after = render(candidate, pageIndex: 0) else { return 0 }
        return Fidelity.ssim(original: before, candidate: after)
    }

    /// Ghostscript re-encodes embedded images while keeping the text layer as
    /// text. The parameter grid is searched, not guessed, and every attempt is
    /// logged with its measured fidelity.
    static func imageRecompression(source: URL, original: DocumentSignature, target: CompressionTarget,
                                   work: WorkArea, shouldCancel: @escaping @Sendable () -> Bool) -> [CompressionCandidate] {
        guard let gs = Toolchain.ghostscript else { return [] }
        var candidates: [CompressionCandidate] = []
        // (image DPI, JPEG quality, name). Higher fidelity first.
        let grid: [(Int, Int, String)] = [
            (300, 92, "300 dpi images, JPEG quality 92"),
            (300, 82, "300 dpi images, JPEG quality 82"),
            (220, 85, "220 dpi images, JPEG quality 85"),
            (220, 75, "220 dpi images, JPEG quality 75"),
            (150, 80, "150 dpi images, JPEG quality 80"),
            (150, 65, "150 dpi images, JPEG quality 65"),
            (110, 70, "110 dpi images, JPEG quality 70")
        ]
        for (index, setting) in grid.enumerated() {
            if shouldCancel() { break }
            let output = work.makeTemporary("gs-\(index)", extension: "pdf")
            let arguments = [
                "-sDEVICE=pdfwrite", "-dNOPAUSE", "-dQUIET", "-dBATCH", "-dSAFER",
                "-dCompatibilityLevel=1.7",
                "-dDetectDuplicateImages=true",
                "-dDownsampleColorImages=true", "-dColorImageDownsampleType=/Bicubic",
                "-dColorImageResolution=\(setting.0)",
                "-dAutoFilterColorImages=false",
                "-dColorImageFilter=/DCTEncode", "-dJPEGQ=\(setting.1)",
                "-dPassThroughJPEGImages=false",
                "-sOutputFile=\(output.path)", source.path
            ]
            guard (try? Toolchain.run(gs, arguments, timeout: 600, shouldCancel: shouldCancel, workingDirectory: work.root)) != nil else {
                TuckLog.compressionLogger.error("pdf.candidate dpi=\(setting.0) q=\(setting.1) verdict=tool-failed")
                work.discard(output)
                continue
            }
            let bytes = ImageFacts.byteSize(output)
            guard bytes > 0 else { work.discard(output); continue }
            guard bytes < target.maxBytes else {
                TuckLog.compressionLogger.info("pdf.candidate dpi=\(setting.0) q=\(setting.1) bytes=\(bytes) verdict=over-limit")
                work.discard(output)
                continue
            }
            switch verify(output, against: original, keepsText: true) {
            case .failure(let failure):
                TuckLog.compressionLogger.error("pdf.candidate dpi=\(setting.0) q=\(setting.1) bytes=\(bytes) verdict=rejected reason=\(failure.description, privacy: .private)")
                work.discard(output)
            case .success:
                let fidelity = pageFidelity(original: source, candidate: output)
                guard fidelity > minimumPageFidelity else {
                    TuckLog.compressionLogger.error("pdf.candidate dpi=\(setting.0) q=\(setting.1) bytes=\(bytes) fidelity=\(String(format: "%.3f", fidelity), privacy: .public) verdict=looks-destroyed")
                    work.discard(output)
                    continue
                }
                TuckLog.compressionLogger.info("pdf.candidate dpi=\(setting.0) q=\(setting.1) bytes=\(bytes) fidelity=\(String(format: "%.4f", fidelity), privacy: .public) verdict=accepted")
                // Resolution is the tie-break when fidelity differences are tiny:
                // a 300 dpi scan beats a 110 dpi one even at equal SSIM.
                candidates.append(CompressionCandidate(file: output, bytes: bytes, strategy: "Ghostscript: \(setting.2)",
                                                       fidelity: fidelity, scale: Double(setting.0) / 300.0, lossless: false))
            }
        }
        return candidates
    }

    /// A recompressed page that scores below this is not a trade-off, it is a
    /// broken document.
    static let minimumPageFidelity = 0.55
}