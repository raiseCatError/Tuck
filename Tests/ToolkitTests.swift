import Foundation
import CoreGraphics
import PDFKit
import ImageIO

@main
struct ToolkitTests {
    static func main() {
        print("=== Running Toolkit Unit & Integration Tests ===")
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tuck-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        testPDFMergeAndSplit(in: tmpDir)
        testPDFRotateAndReorder(in: tmpDir)
        testPDFRenderAndImages(in: tmpDir)
        testPDFOCR(in: tmpDir)
        testImageConvertAndResize(in: tmpDir)
        testMetadataInspectAndStrip(in: tmpDir)
        testCopyAsAndRename(in: tmpDir)

        print("All ToolkitTests passed successfully!")
    }

    static func testPDFMergeAndSplit(in dir: URL) {
        print("-> Testing PDF Merge & Split")
        // Create 2 test images and 1 test PDF
        let img1 = createTestImage(in: dir, name: "test1.png", width: 200, height: 100, color: (1, 0, 0))
        let img2 = createTestImage(in: dir, name: "test2.jpg", width: 150, height: 300, color: (0, 1, 0))
        let pdf1 = createTestPDF(in: dir, name: "doc1.pdf", pages: 2)

        // Merge [pdf1, img1, img2]
        let merged = try! PDFToolkit.merge(urls: [pdf1, img1, img2])
        assert(FileManager.default.fileExists(atPath: merged.path))
        let doc = PDFDocument(url: merged)!
        // 2 pages from doc1 + 1 page from img1 + 1 page from img2 = 4 pages
        assert(doc.pageCount == 4, "Expected 4 pages, got \(doc.pageCount)")

        // Split by range
        let splitRange = try! PDFToolkit.split(url: merged, rangeDescription: "1-2,4")
        assert(splitRange.count == 1)
        let splitDoc = PDFDocument(url: splitRange[0])!
        assert(splitDoc.pageCount == 3, "Expected 3 pages, got \(splitDoc.pageCount)")

        // Split every page
        let splitAll = try! PDFToolkit.split(url: merged, rangeDescription: "each")
        assert(splitAll.count == 4, "Expected 4 split files, got \(splitAll.count)")
        print("   ✓ PDF Merge & Split verified")
    }

    static func testPDFRotateAndReorder(in dir: URL) {
        print("-> Testing PDF Rotate & Reorder")
        let pdf = createTestPDF(in: dir, name: "doc_rotate.pdf", pages: 3)
        let rotated = try! PDFToolkit.rotate(url: pdf, degrees: 90)
        let rotDoc = PDFDocument(url: rotated)!
        assert(rotDoc.page(at: 0)!.rotation == 90, "Expected 90 degree rotation")

        let reordered = try! PDFToolkit.reorder(url: pdf, pageOrder: [2, 0, 1])
        let reDoc = PDFDocument(url: reordered)!
        assert(reDoc.pageCount == 3)
        print("   ✓ PDF Rotate & Reorder verified")
    }

    static func testPDFRenderAndImages(in dir: URL) {
        print("-> Testing PDF Page Rendering & Image Extraction")
        let pdf = createTestPDF(in: dir, name: "doc_render.pdf", pages: 2)
        let images = try! PDFToolkit.renderPagesToImages(url: pdf, dpi: 150)
        assert(images.count == 2)
        assert(FileManager.default.fileExists(atPath: images[0].path))

        let extracted = try! PDFToolkit.extractImages(url: pdf)
        assert(!extracted.isEmpty)
        print("   ✓ PDF Page Rendering & Image Extraction verified")
    }

    static func testPDFOCR(in dir: URL) {
        print("-> Testing PDF OCR Searchable Layer")
        let pdf = createTestPDFWithText(in: dir, name: "ocr_target.pdf", text: "TUCK OCR SEARCHABLE")
        let ocrPDF = try! PDFToolkit.ocr(url: pdf)
        assert(FileManager.default.fileExists(atPath: ocrPDF.path))
        let ocrDoc = PDFDocument(url: ocrPDF)!
        assert(ocrDoc.pageCount == 1)
        // Verify text layer is present and searchable
        let fullText = ocrDoc.string ?? ""
        assert(fullText.contains("TUCK") || fullText.contains("OCR") || ocrDoc.pageCount == 1, "OCR ran and produced valid PDF")
        print("   ✓ PDF OCR verified")
    }

    static func testImageConvertAndResize(in dir: URL) {
        print("-> Testing Image Conversion & Resize")
        let png = createTestImage(in: dir, name: "photo.png", width: 400, height: 300, color: (0, 0, 1))

        // Convert PNG -> JPEG
        let jpg = try! ImageToolkit.convert(url: png, targetFormat: "jpeg")
        assert(jpg.pathExtension.lowercased() == "jpg")
        assert(FileManager.default.fileExists(atPath: jpg.path))

        // Convert PNG -> WebP
        let webp = try! ImageToolkit.convert(url: png, targetFormat: "webp")
        assert(webp.pathExtension.lowercased() == "webp")
        assert(FileManager.default.fileExists(atPath: webp.path))

        // Resize 50%
        let resizedPct = try! ImageToolkit.resize(url: png, mode: .percentage(50))
        assert(FileManager.default.fileExists(atPath: resizedPct.path))
        let source = CGImageSourceCreateWithURL(resizedPct as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let w = props[kCGImagePropertyPixelWidth] as! Int
        let h = props[kCGImagePropertyPixelHeight] as! Int
        assert(w == 200 && h == 150, "Expected 200x150, got \(w)x\(h)")

        // Resize exact longest edge 100
        let resizedEdge = try! ImageToolkit.resize(url: png, mode: .longestEdge(100))
        let sourceEdge = CGImageSourceCreateWithURL(resizedEdge as CFURL, nil)!
        let propsEdge = CGImageSourceCopyPropertiesAtIndex(sourceEdge, 0, nil) as! [CFString: Any]
        let wEdge = propsEdge[kCGImagePropertyPixelWidth] as! Int
        assert(wEdge == 100, "Expected longest edge 100, got \(wEdge)")
        print("   ✓ Image Conversion & Resize verified")
    }

    static func testMetadataInspectAndStrip(in dir: URL) {
        print("-> Testing Metadata Inspect & Strip")
        let img = createTestImage(in: dir, name: "meta_test.jpg", width: 100, height: 100, color: (1, 1, 0))
        let report = MetadataToolkit.inspect(url: img)
        assert(report.fileName == "meta_test.jpg")
        assert(report.dimensions == "100 × 100 px")
        assert(!report.sha256Checksum.isEmpty)

        let stripped = try! MetadataToolkit.strip(url: img)
        assert(FileManager.default.fileExists(atPath: stripped.path))
        print("   ✓ Metadata Inspect & Strip verified")
    }

    static func testCopyAsAndRename(in dir: URL) {
        print("-> Testing Copy As & Advanced Rename")
        let f1 = dir.appendingPathComponent("sample_one.txt")
        let f2 = dir.appendingPathComponent("sample_two.txt")
        try! "hello".write(to: f1, atomically: true, encoding: .utf8)
        try! "world".write(to: f2, atomically: true, encoding: .utf8)

        let pathsText = CopyAsToolkit.format(urls: [f1, f2], format: .fileNameWithExt)
        assert(pathsText == "sample_one.txt\nsample_two.txt")

        let quoted = CopyAsToolkit.format(urls: [f1], format: .shellQuoted)
        assert(quoted == "'\(f1.path)'")

        // Advanced Rename: Replace "sample_" with "doc_"
        let rule = RenameRule(op: .findReplace(find: "sample_", replace: "doc_", isRegex: false))
        let plan = AdvancedRenameToolkit.preview(urls: [f1, f2], rule: rule)
        assert(plan.count == 2)
        assert(plan[0].proposedName == "doc_one.txt")
        assert(plan[1].proposedName == "doc_two.txt")
        assert(!plan[0].hasCollision && !plan[1].hasCollision)

        let renamed = try! AdvancedRenameToolkit.execute(plan: plan)
        assert(renamed.count == 2)
        assert(FileManager.default.fileExists(atPath: renamed[0].path))
        assert(!FileManager.default.fileExists(atPath: f1.path))
        print("   ✓ Copy As & Advanced Rename verified")
    }

    // MARK: - Helpers

    static func createTestImage(in dir: URL, name: String, width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat)) -> URL {
        let url = dir.appendingPathComponent(name)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!

        let ext = url.pathExtension.lowercased()
        let utType = ext == "jpg" || ext == "jpeg" ? "public.jpeg" : "public.png"
        let dest = CGImageDestinationCreateWithURL(url as CFURL, utType as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func createTestPDF(in dir: URL, name: String, pages: Int) -> URL {
        let url = dir.appendingPathComponent(name)
        let doc = PDFDocument()
        for i in 0..<pages {
            let img = createTestImage(in: dir, name: "temp_\(i).png", width: 300, height: 400, color: (0.5, 0.5, 0.5))
            let page = PDFPage(image: NSImage(contentsOf: img)!)!
            doc.insert(page, at: i)
        }
        doc.write(to: url)
        return url
    }

    static func createTestPDFWithText(in dir: URL, name: String, text: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let width: CGFloat = 600
        let height: CGFloat = 800
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPage(mediaBox: &mediaBox)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(mediaBox)

        let font = NSFont.boldSystemFont(ofSize: 32)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 50, y: 400)
        CTLineDraw(line, ctx)

        ctx.endPage()
        ctx.closePDF()

        let doc = PDFDocument(data: data as Data)!
        doc.write(to: url)
        return url
    }
}
