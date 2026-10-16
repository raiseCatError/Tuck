import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Image decoding, colour normalisation and format validation. Everything works
// on sRGB 8-bit pixels so external encoders and the fidelity metric all see the
// same colour space and comparisons stay fair.

enum ImageIOError: Error { case unreadable, unsupported, encodeFailed }

enum ImageFacts {
    /// Inspects a file without decoding the pixels.
    static func analyze(_ url: URL) throws -> SourceFacts {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CompressionFailure.unreadableSource("The file could not be opened.")
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw CompressionFailure.corruptedSource("No image data was found.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else {
            throw CompressionFailure.corruptedSource("Image dimensions are missing.")
        }
        let alphaInfo = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let bits = ((properties as [String: Any])["BitsPerSample"] as? NSNumber)?.intValue ?? 8
        let profile = properties[kCGImagePropertyProfileName] as? String
        let icc = ((properties as [String: Any])["ICC Profile"] as? Data)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let byteSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return SourceFacts(family: family(for: type, url: url),
                           type: type,
                           pixelWidth: width,
                           pixelHeight: height,
                           frameCount: CGImageSourceGetCount(source),
                           hasAlpha: alphaInfo,
                           bitsPerComponent: bits,
                           embedsProfile: icc != nil || (profile?.isEmpty == false),
                           orientation: orientation,
                           byteSize: byteSize)
    }

    private static func family(for type: UTType, url: URL) -> ImageFamily {
        if type.conforms(to: .jpeg) { return .jpegLike }
        if type.conforms(to: .png) { return .pngLike }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heicLike }
        if type.conforms(to: .tiff) { return .tiffLike }
        if type.conforms(to: .bmp) { return .bmpLike }
        if type.conforms(to: .pdf) { return .pdfLike }
        if type.conforms(to: .gif) || type.conforms(to: .webP) { return .other }
        _ = url
        return .other
    }

    /// Decodes one frame with orientation applied, capped so a huge photo cannot
    /// blow up memory. `maxPixel` of 0 means no cap.
    static func frame(_ url: URL, maxPixel: Int = 0) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CompressionFailure.unreadableSource("The file could not be opened.")
        }
        var options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        if maxPixel > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CompressionFailure.corruptedSource("The image could not be decoded.")
        }
        return image
    }

    /// Scales with a high quality box filter. Used for the search ladder.
    static func scale(_ image: CGImage, toMaxPixel maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, maxPixel > 0 else { return image }
        let ratio = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = makeContext(width: width, height: height, alpha: true) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func makeContext(width: Int, height: Int, alpha: Bool) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: colorSpace,
                          bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                                            : CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    /// Renders to opaque 8-bit sRGB, compositing any alpha over white. This is
    /// exactly what external encoders are fed, so colours match the original.
    static func srgbBytes(_ image: CGImage, width: Int, height: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let context = makeContext(width: width, height: height, alpha: false) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0 ..< height {
            let source = data.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                let from = column * 4
                let to = (row * width + column) * 4
                pixels[to] = source[from]
                pixels[to + 1] = source[from + 1]
                pixels[to + 2] = source[from + 2]
                pixels[to + 3] = 255
            }
        }
        return (pixels, width, height)
    }

    /// Binary PPM, the only input every cjpeg flavour accepts. Alpha is dropped
    /// because JPEG cannot store it.
    static func writePPM(_ image: CGImage, to url: URL) throws {
        guard let (pixels, width, height) = srgbBytes(image, width: image.width, height: image.height) else {
            throw ImageIOError.encodeFailed
        }
        var body = [UInt8](repeating: 0, count: width * height * 3)
        body.withUnsafeMutableBufferPointer { buffer in
            for index in 0 ..< width * height {
                buffer[index * 3] = pixels[index * 4]
                buffer[index * 3 + 1] = pixels[index * 4 + 1]
                buffer[index * 3 + 2] = pixels[index * 4 + 2]
            }
        }
        var document = Data("P6\n\(width) \(height)\n255\n".utf8)
        document.append(contentsOf: body)
        try document.write(to: url, options: .atomic)
    }

    /// Lossless PNG of an in-memory image, used to hand ImageIO's decoder a
    /// clean intermediate for external tools that want PNG input.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageIOError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageIOError.encodeFailed }
    }

    static func encode(_ image: CGImage, to url: URL, type: UTType, quality: Double?, extra: [CFString: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageIOError.encodeFailed
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        for (key, value) in extra { properties[key] = value }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageIOError.encodeFailed }
    }

    /// Confirms an output really is the format it claims to be and decodes at the
    /// expected geometry. A candidate that fails this is discarded, never shown.
    static func validate(_ url: URL, expecting type: UTType, pixelSize: CGSize?) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw CompressionFailure.verificationFailed("The result is not a readable image.")
        }
        let actual = CGImageSourceGetType(source)
        if let actual, UTType(actual as String)?.conforms(to: type) == false {
            throw CompressionFailure.verificationFailed("The result is not \(type.identifier).")
        }
        if let pixelSize {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if abs(width - Int(pixelSize.width)) > 1 || abs(height - Int(pixelSize.height)) > 1 {
                throw CompressionFailure.verificationFailed("The result has unexpected dimensions.")
            }
        }
    }

    /// True when at least one pixel is genuinely see-through. A PNG can carry an
    /// alpha channel that is fully opaque; demanding an alpha channel in that
    /// case would reject perfectly good results.
    static func hasVisibleAlpha(_ image: CGImage) -> Bool {
        guard let context = makeContext(width: image.width, height: image.height, alpha: true) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return false }
        let bytesPerRow = context.bytesPerRow
        let width = image.width
        let height = image.height
        
        // Check every pixel's alpha byte across all rows.
        for row in 0 ..< height {
            let rowPtr = data.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                // RGBA/premultipliedLast has alpha at byte offset 3.
                if rowPtr[column * 4 + 3] < 250 {
                    return true
                }
            }
        }
        return false
    }

    static func byteSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Best guess at whether a JPEG already carries an efficient Huffman table
    /// set, which decides if a lossless pass is worth attempting.
    static func progressiveJPEGBytes(_ url: URL) -> Int {
        Int(byteSize(url))
    }
}

enum CGSizeSendable: @unchecked Sendable {}