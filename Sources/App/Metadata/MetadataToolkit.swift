import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import CryptoKit
import UniformTypeIdentifiers

public struct MetadataReport: Sendable {
    public let fileName: String
    public let fileSizeDescription: String
    public let formatDescription: String
    public let dimensions: String?
    public let colorProfile: String?
    public let exifCamera: String?
    public let gpsLocation: String?
    public let pdfInfo: [String: String]?
    public let sha256Checksum: String

    public var summary: String {
        var lines: [String] = []
        lines.append("File: \(fileName)")
        lines.append("Size: \(fileSizeDescription)")
        lines.append("Format: \(formatDescription)")
        if let dimensions { lines.append("Dimensions: \(dimensions)") }
        if let colorProfile { lines.append("Color Profile: \(colorProfile)") }
        if let exifCamera { lines.append("Camera / EXIF: \(exifCamera)") }
        if let gpsLocation { lines.append("Location (GPS): \(gpsLocation)") }
        if let pdfInfo, !pdfInfo.isEmpty {
            lines.append("PDF Attributes:")
            for (k, v) in pdfInfo.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(k): \(v)")
            }
        }
        lines.append("SHA-256: \(sha256Checksum)")
        return lines.joined(separator: "\n")
    }
}

public enum MetadataToolkit {

    /// Inspects and extracts metadata from an image, PDF or arbitrary file.
    public static func inspect(url: URL) -> MetadataReport {
        let fileName = url.lastPathComponent
        let attr = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let byteSize = attr[.size] as? Int64 ?? 0
        let sizeDesc = String(format: "%.2f MB (%d bytes)", Double(byteSize) / 1_000_000.0, byteSize)

        // SHA-256 checksum
        let hashString: String
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let digest = SHA256.hash(data: data)
            hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
        } else {
            hashString = "Unable to compute"
        }

        let ext = url.pathExtension.lowercased()

        // Check PDF
        if ext == "pdf", let doc = PDFDocument(url: url) {
            var attributes: [String: String] = [:]
            if let dict = doc.documentAttributes {
                for (k, v) in dict {
                    attributes["\(k)"] = "\(v)"
                }
            }
            attributes["Page Count"] = "\(doc.pageCount)"
            return MetadataReport(
                fileName: fileName,
                fileSizeDescription: sizeDesc,
                formatDescription: "PDF Document",
                dimensions: "\(doc.pageCount) page(s)",
                colorProfile: nil,
                exifCamera: nil,
                gpsLocation: nil,
                pdfInfo: attributes,
                sha256Checksum: hashString
            )
        }

        // Check Image
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let dimDesc = width > 0 && height > 0 ? "\(width) × \(height) px" : nil
            let colorModel = props[kCGImagePropertyColorModel] as? String
            let profileName = props[kCGImagePropertyProfileName] as? String ?? colorModel

            var camera: String? = nil
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
                let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
                let combined = "\(make) \(model)".trimmingCharacters(in: .whitespaces)
                if !combined.isEmpty { camera = combined }
            }

            var gpsStr: String? = nil
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                let lat = gps[kCGImagePropertyGPSLatitude] as? Double ?? 0
                let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
                let lon = gps[kCGImagePropertyGPSLongitude] as? Double ?? 0
                let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
                gpsStr = String(format: "%.4f°%@, %.4f°%@", lat, latRef, lon, lonRef)
            }

            return MetadataReport(
                fileName: fileName,
                fileSizeDescription: sizeDesc,
                formatDescription: "\(ext.uppercased()) Image",
                dimensions: dimDesc,
                colorProfile: profileName,
                exifCamera: camera,
                gpsLocation: gpsStr,
                pdfInfo: nil,
                sha256Checksum: hashString
            )
        }

        return MetadataReport(
            fileName: fileName,
            fileSizeDescription: sizeDesc,
            formatDescription: ext.isEmpty ? "Binary File" : "\(ext.uppercased()) File",
            dimensions: nil,
            colorProfile: nil,
            exifCamera: nil,
            gpsLocation: nil,
            pdfInfo: nil,
            sha256Checksum: hashString
        )
    }

    /// Strips EXIF, GPS, camera and document metadata from images and PDFs, producing a new safe copy.
    public static func strip(url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else {
                throw TuckFailure.invalidInput("Could not read PDF document.")
            }
            let strippedDoc = PDFDocument()
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    strippedDoc.insert(page, at: i)
                }
            }
            // Clear document attributes dictionary
            strippedDoc.documentAttributes = [:]

            let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-strip-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temp) }

            guard strippedDoc.write(to: temp) else {
                throw TuckFailure.commandFailed("Failed to write stripped PDF.")
            }
            return try OutputName.publish(temp, beside: url, suffix: "-stripped", extraExtension: "pdf")
        }

        // Image stripping: decode pixel buffer into clean context and re-encode without metadata dictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TuckFailure.invalidInput("Could not decode image.")
        }

        let utType = UTType(filenameExtension: ext) ?? .png
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tuck-strip-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, utType.identifier as CFString, 1, nil) else {
            throw TuckFailure.commandFailed("Could not initialize image writer.")
        }

        // Write without passing any EXIF/GPS properties
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TuckFailure.commandFailed("Could not finalize stripped image.")
        }

        return try OutputName.publish(temp, beside: url, suffix: "-stripped", extraExtension: ext)
    }
}
