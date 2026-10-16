import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageConvertError: LocalizedError, Sendable {
    case unreadableImage(String)
    case unsupportedFormat(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let path): return "Could not decode image at: \(path)"
        case .unsupportedFormat(let fmt): return "Target format '\(fmt)' is not supported by installed encoders."
        case .writeFailed(let path): return "Failed writing converted image to: \(path)"
        }
    }
}

public enum ResizeMode: Sendable {
    case exact(width: Int, height: Int)
    case longestEdge(Int)
    case percentage(Double)
}

public enum ImageToolkit {

    /// Converts an image to the destination format (e.g. "jpeg", "png", "heic", "tiff", "webp").
    /// Preserves dimensions, transparency, color profile and orientation.
    public static func convert(url: URL,
                               targetFormat: String,
                               progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                               shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageConvertError.unreadableImage(url.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImageConvertError.unsupportedFormat(
                "Animated and multi-frame images cannot be processed without losing frames.")
        }

        let utType: UTType
        let ext: String
        switch targetFormat.lowercased() {
        case "jpeg", "jpg":
            utType = .jpeg
            ext = "jpg"
        case "png":
            utType = .png
            ext = "png"
        case "heic":
            utType = .heic
            ext = "heic"
        case "tiff", "tif":
            utType = .tiff
            ext = "tiff"
        case "webp":
            utType = .webP
            ext = "webp"
        case "avif":
            guard let avif = UTType("public.avif") else {
                throw ImageConvertError.unsupportedFormat("AVIF encoder unavailable")
            }
            utType = avif
            ext = "avif"
        default:
            throw ImageConvertError.unsupportedFormat(targetFormat)
        }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-convert-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temp) }

        if targetFormat.lowercased() == "webp", let cwebp = Toolchain.tool("cwebp") {
            // Encode temporary PNG first, then run cwebp
            let tempPNG = url.deletingLastPathComponent().appendingPathComponent(".tuck-webp-in-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tempPNG) }
            guard let pngDest = CGImageDestinationCreateWithURL(tempPNG as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ImageConvertError.writeFailed("PNG staging for WebP")
            }
            CGImageDestinationAddImage(pngDest, image, nil)
            guard CGImageDestinationFinalize(pngDest) else {
                throw ImageConvertError.writeFailed("PNG staging for WebP finalize")
            }

            do {
                try Toolchain.run(cwebp, ["-q", "90", tempPNG.path, "-o", temp.path],
                                  timeout: 180, shouldCancel: shouldCancel)
            } catch ToolError.cancelled {
                throw CancellationError()
            } catch {
                throw ImageConvertError.writeFailed("WebP encoder failed: \(error.localizedDescription)")
            }
            guard FileManager.default.fileExists(atPath: temp.path) else {
                throw ImageConvertError.writeFailed("WebP encoder did not create an output.")
            }
            return try OutputName.publish(temp, beside: url, suffix: "-converted", extraExtension: ext)
        }

        var properties: [CFString: Any] = [:]
        // Preserve orientation and metadata properties
        if let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let orientation = sourceProps[kCGImagePropertyOrientation] {
                properties[kCGImagePropertyOrientation] = orientation
            }
        }

        // Quality setting for lossy targets
        if utType == .jpeg || utType == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }

        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, utType.identifier as CFString, 1, nil) else {
            throw ImageConvertError.unsupportedFormat(targetFormat)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConvertError.writeFailed(temp.lastPathComponent)
        }

        return try OutputName.publish(temp, beside: url, suffix: "-converted", extraExtension: ext)
    }

    /// Resizes an image according to the specified ResizeMode (exact, longest edge, percentage).
    public static func resize(url: URL,
                              mode: ResizeMode,
                              maintainAspect: Bool = true,
                              progress: @Sendable @escaping (Double, String) -> Void = { _, _ in },
                              shouldCancel: @Sendable @escaping () -> Bool = { false }) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageConvertError.unreadableImage(url.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImageConvertError.unsupportedFormat(
                "Animated and multi-frame images cannot be processed without losing frames.")
        }

        if shouldCancel() { throw CancellationError() }
        let origW = image.width
        let origH = image.height
        guard origW > 0, origH > 0 else {
            throw ImageConvertError.unreadableImage(url.lastPathComponent)
        }
        // Bound decoded bitmap allocations, even for malformed caller arguments.
        let maxEdge = 16_384
        let maxPixels = 40_000_000

        let targetW: Int
        let targetH: Int

        switch mode {
        case .exact(let w, let h):
            guard w > 0, h > 0, w <= maxEdge, h <= maxEdge else {
                throw ImageConvertError.writeFailed("Dimensions must be between 1 and 16384 pixels.")
            }
            if maintainAspect {
                let ratio = min(Double(w) / Double(origW), Double(h) / Double(origH))
                targetW = max(1, Int(Double(origW) * ratio))
                targetH = max(1, Int(Double(origH) * ratio))
            } else {
                targetW = max(1, w)
                targetH = max(1, h)
            }
        case .longestEdge(let edge):
            guard edge > 0 && edge <= maxEdge else {
                throw ImageConvertError.writeFailed("Longest edge must be between 1 and 16384 pixels.")
            }
            let longest = max(origW, origH)
            let ratio = Double(edge) / Double(longest)
            targetW = max(1, Int(Double(origW) * ratio))
            targetH = max(1, Int(Double(origH) * ratio))
        case .percentage(let pct):
            guard pct.isFinite, pct > 0, pct <= 400 else {
                throw ImageConvertError.writeFailed("Resize percentage must be above 0 and at most 400%.")
            }
            let ratio = pct / 100.0
            targetW = max(1, Int(Double(origW) * ratio))
            targetH = max(1, Int(Double(origH) * ratio))
        }

        guard targetW <= maxEdge, targetH <= maxEdge,
              Double(targetW) * Double(targetH) <= Double(maxPixels) else {
            throw ImageConvertError.writeFailed("Resize exceeds Tuck's safe 40-megapixel working limit.")
        }
        if shouldCancel() { throw CancellationError() }

        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(data: nil, width: targetW, height: targetH,
                                      bitsPerComponent: 8,
                                      bytesPerRow: targetW * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            throw ImageConvertError.writeFailed("Failed to allocate graphics context")
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let resizedCG = context.makeImage() else {
            throw ImageConvertError.writeFailed("Failed to render resized image")
        }

        let ext = url.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext) ?? .png

        let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-resize-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, utType.identifier as CFString, 1, nil) else {
            throw ImageConvertError.writeFailed(temp.lastPathComponent)
        }

        CGImageDestinationAddImage(destination, resizedCG, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConvertError.writeFailed(temp.lastPathComponent)
        }

        let suffix = "-resized-\(targetW)x\(targetH)"
        return try OutputName.publish(temp, beside: url, suffix: suffix, extraExtension: ext)
    }
}
