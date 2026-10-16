import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import PDFKit

// Generates disposable fixtures for compression testing. Nothing here ships in
// the app; it exists so engine behaviour can be compared on real bitstreams.
// Usage: compile with Sources/Shared and run:  fixtures <output-directory>

@main
struct Fixtures {
    static func main() {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tuck-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("fixtures: \(root.path)")

        let photo = renderPhoto(width: 4000, height: 3000)
        write(photo, to: root.appendingPathComponent("photo.jpg"), type: .jpeg, quality: 0.98)
        write(photo, to: root.appendingPathComponent("photo.heic"), type: UTType.heic, quality: 0.95)
        write(photo, to: root.appendingPathComponent("flat.tiff"), type: .tiff, quality: nil)
        write(photo, to: root.appendingPathComponent("flat.bmp"), type: .bmp, quality: nil)

        let shot = renderScreenshot(width: 2560, height: 1440)
        write(shot, to: root.appendingPathComponent("screenshot.png"), type: .png, quality: nil)

        let alpha = renderAlpha(width: 3000, height: 2000)
        write(alpha, to: root.appendingPathComponent("alpha.png"), type: .png, quality: nil)

        makeTextPDF(at: root.appendingPathComponent("text.pdf"))
        makeScannedPDF(at: root.appendingPathComponent("scanned.pdf"), image: photo)

        let mixed = root.appendingPathComponent("mixed", isDirectory: true)
        try? FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: true)
        let text = "The quick brown fox jumps over the lazy dog. ".repeatingCount(400)
        try? text.write(to: mixed.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? Swift.String(repeating: "let value = compute(a: 1, b: 2)\n", count: 800)
            .write(to: mixed.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        var rng = SystemRandomNumberGenerator()
        var bytes = Data(count: 700_000)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &rng) }
        try? bytes.write(to: mixed.appendingPathComponent("noise.bin"))
        try? FileManager.default.createSymbolicLink(at: mixed.appendingPathComponent("link.txt"), withDestinationURL: mixed.appendingPathComponent("notes.txt"))
        try? FileManager.default.createDirectory(at: mixed.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
        try? text.write(to: mixed.appendingPathComponent("nested/deep/unicode-éü-你好.txt"), atomically: true, encoding: .utf8)

        var sizes: [(String, Int)] = []
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if let size = values?.fileSize, values?.isDirectory != true { sizes.append((url.lastPathComponent, size)) }
        }
        for (name, size) in sizes.sorted(by: { $0.0 < $1.0 }) {
            print(String(format: "  %-20@ %10d bytes", name as NSString, size))
        }
    }

    /// Smooth gradients plus fine grain: compresses like a photograph.
    static func renderPhoto(width: Int, height: Int) -> CGImage {
        var rng = SystemRandomNumberGenerator()
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { pixels.deallocate() }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                let base = (sin(fx * 9) * cos(fy * 7) + sin((fx + fy) * 13)) * 0.25 + 0.5
                let grain = Double.random(in: -0.035 ... 0.035, using: &rng)
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(clamping: Int((base + grain + fx * 0.18) * 255))
                pixels[offset + 1] = UInt8(clamping: Int((base + grain + fy * 0.15) * 255))
                pixels[offset + 2] = UInt8(clamping: Int((base * 0.8 + grain + 0.2) * 255))
                pixels[offset + 3] = 255
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    /// UI-like content: flat areas, sharp text blocks, full alpha.
    static func renderScreenshot(width: Int, height: Int) -> CGImage {
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { pixels.deallocate() }
        var rng = SystemRandomNumberGenerator()
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let stripe = (y / 3) % 2 == 0 ? 242 : 226
                let grain = UInt8(Double.random(in: 0 ... 5, using: &rng))
                pixels[offset] = UInt8(clamping: stripe - Int(grain))
                pixels[offset + 1] = UInt8(clamping: stripe - Int(grain))
                pixels[offset + 2] = UInt8(clamping: min(255, stripe + 2) - Int(grain))
                pixels[offset + 3] = 255
            }
        }
        let image = makeImage(pixels, width: width, height: height)
        return drawBlocks(on: image, seed: 97)
    }

    /// Transparency that matters: gradients behind an alpha mask.
    static func renderAlpha(width: Int, height: Int) -> CGImage {
        var rng = SystemRandomNumberGenerator()
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { pixels.deallocate() }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                let colour = (sin(fx * 11 + fy * 5) + 1) / 2
                pixels[offset] = UInt8(clamping: Int(colour * 255))
                pixels[offset + 1] = UInt8(clamping: Int((1 - colour) * 255))
                pixels[offset + 2] = UInt8(clamping: Int(colour * 220))
                pixels[offset + 3] = UInt8(clamping: Int(((fx > 0.15 && fx < 0.85 && fy > 0.15 && fy < 0.85) ? 255 : 90) + Double.random(in: -2 ... 2, using: &rng)))
            }
        }
        return makeImage(pixels, width: width, height: height)
    }

    static func makeImage(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("context")
        }
        return context.makeImage()!
    }

    static func drawBlocks(on image: CGImage, seed: UInt64) -> CGImage {
        var rng = SystemRandomNumberGenerator()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for _ in 0 ..< 260 {
            let w = Int.random(in: 60 ... 900, using: &rng)
            let h = Int.random(in: 14 ... 90, using: &rng)
            let x = Int.random(in: 0 ... max(1, image.width - w), using: &rng)
            let y = Int.random(in: 0 ... max(1, image.height - h), using: &rng)
            context.setFillColor(red: Double.random(in: 0.1 ... 0.9, using: &rng),
                                 green: Double.random(in: 0.1 ... 0.9, using: &rng),
                                 blue: Double.random(in: 0.1 ... 0.9, using: &rng), alpha: 0.85)
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        return context.makeImage() ?? image
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double?) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            print("cannot create \(url.lastPathComponent)")
            return
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        options[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            print("failed to write \(url.lastPathComponent)")
            return
        }
    }

    static func makeTextPDF(at url: URL) {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: [page], nil) else { return }
        let body = "Tuck compression sample. Searchable text must survive optimisation.".repeatingCount(60)
        for pageIndex in 0 ..< 12 {
            context.beginPDFPage(nil)
            var y = page.height - 72
            let title = "Section \(pageIndex + 1)"
            let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
            title.draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: titleFont, .foregroundColor: NSColor.black])
            y -= 40
            let font = NSFont.systemFont(ofSize: 11)
            for line in body.split(separator: "\n") {
                (String(line.prefix(96)) as NSString).draw(in: CGRect(x: 72, y: y, width: 451, height: 16), withAttributes: [.font: font])
                y -= 15
                if y < 72 { break }
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func makeScannedPDF(at url: URL, image: CGImage) {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: [page], nil) else { return }
        for _ in 0 ..< 6 {
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 30, y: 60, width: page.width - 60, height: page.height - 120))
            context.endPDFPage()
        }
        context.closePDF()
    }
}

extension String {
    func repeatingCount(_ count: Int) -> String {
        String(repeating: self + "\n", count: count)
    }
}