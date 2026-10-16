import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum TuckFailure: LocalizedError {
    case invalidInput(String)
    case noGain(String)
    case commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidInput(let reason), .noGain(let reason), .commandFailed(let reason): reason
        }
    }
}

enum FileWork {
    static func uniqueDestination(for source: URL, suffix: String, ext: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        for i in 0..<10_000 {
            let postfix = i == 0 ? "" : "-\(i + 1)"
            let name = "\(stem)\(suffix)\(postfix)\(ext.isEmpty ? "" : ".\(ext)")"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    static func newFile(in folder: URL, name: String) throws -> URL {
        guard folder.isFileURL,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name.utf8.count < 200,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw TuckFailure.invalidInput("Choose a valid name and destination folder.")
        }
        // O_EXCL avoids overwriting an existing file, even if another process creates it first.
        for i in 0..<10_000 {
            let candidate: URL
            if i == 0 { candidate = folder.appendingPathComponent(name) }
            else {
                let url = URL(fileURLWithPath: name)
                let ext = url.pathExtension
                let stem = ext.isEmpty ? name : String(name.dropLast(ext.utf8.count + 1))
                candidate = folder.appendingPathComponent(stem + " \(i + 1)" + (ext.isEmpty ? "" : "." + ext))
            }
            let fd = candidate.withUnsafeFileSystemRepresentation { ptr -> Int32 in
                guard let ptr else { return -1 }
                return Darwin.open(ptr, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            }
            if fd >= 0 { Darwin.close(fd); return candidate }
            if errno != EEXIST { throw TuckFailure.commandFailed("Could not create \(candidate.lastPathComponent): \(String(cString: strerror(errno)))") }
        }
        throw TuckFailure.commandFailed("Too many files with that name.")
    }

    static func zip(_ paths: [String]) throws -> URL {
        guard let first = paths.first, paths.count <= 16 else {
            throw TuckFailure.invalidInput("Select one to sixteen files or folders.")
        }
        let source = URL(fileURLWithPath: first)
        let dest = uniqueDestination(for: source, suffix: "-compressed", ext: "zip")
        let temporary = dest.deletingLastPathComponent().appendingPathComponent(".tuck-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        if paths.count == 1 {
            guard FileManager.default.fileExists(atPath: source.path) else { throw TuckFailure.invalidInput("Selected item is missing.") }
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, temporary.path]
        } else {
            let parent = source.deletingLastPathComponent()
            let selected = paths.map { URL(fileURLWithPath: $0) }
            guard selected.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL && FileManager.default.fileExists(atPath: $0.path) }) else {
                throw TuckFailure.invalidInput("For a combined ZIP, select existing items from the same folder.")
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = parent
            process.arguments = ["-r", "-X", "-q", temporary.path, "--"] + selected.map(\.lastPathComponent)
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: temporary.path) else {
            throw TuckFailure.commandFailed("ZIP creation failed (exit \(process.terminationStatus)).")
        }
        try FileManager.default.moveItem(at: temporary, to: dest)
        return dest
    }

    static func compress(_ paths: [String], targetMB: Double) -> (files: [URL], errors: [String]) {
        guard (0.1...500).contains(targetMB) else { return ([], ["Choose a target between 0.1 and 500 MB."]) }
        let maxBytes = Int(targetMB * 1_000_000)
        var outputs: [URL] = []
        var failures: [String] = []
        for path in paths.prefix(16) {
            let url = URL(fileURLWithPath: path)
            do {
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    outputs.append(try compressPDF(url, targetBytes: maxBytes))
                } else if ["jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp"].contains(ext) {
                    outputs.append(try compressImage(url, targetBytes: maxBytes))
                } else {
                    throw TuckFailure.invalidInput("Size-target compression supports images and PDFs; use ZIP for other files.")
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (outputs, failures)
    }

    private static func bytes(at url: URL) throws -> Int {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard v.isRegularFile == true, let size = v.fileSize else { throw TuckFailure.invalidInput("Not a regular file.") }
        return size
    }

    private static func compressPDF(_ source: URL, targetBytes: Int) throws -> URL {
        let originalBytes = try bytes(at: source)
        guard originalBytes > targetBytes else { throw TuckFailure.noGain("Already below the size limit; original unchanged.") }
        guard let pdf = PDFDocument(url: source), !pdf.isEncrypted else {
            throw TuckFailure.invalidInput("PDF could not be read, or it is encrypted.")
        }
        let output = uniqueDestination(for: source, suffix: "-compressed", ext: "pdf")
        let temp = output.deletingLastPathComponent().appendingPathComponent(".tuck-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        let options: [PDFDocumentWriteOption: Any] = [
            .optimizeImagesForScreenOption: true,
            .saveImagesAsJPEGOption: true
        ]
        guard pdf.write(to: temp, withOptions: options) else {
            throw TuckFailure.commandFailed("PDFKit could not optimize this PDF.")
        }
        let resultBytes = try bytes(at: temp)
        guard resultBytes < originalBytes, resultBytes <= targetBytes else {
            throw TuckFailure.noGain("Couldn't safely reach the target while preserving PDF content. No output was saved.")
        }
        try FileManager.default.moveItem(at: temp, to: output)
        return output
    }

    private static func compressImage(_ source: URL, targetBytes: Int) throws -> URL {
        let originalBytes = try bytes(at: source)
        guard originalBytes > targetBytes else { throw TuckFailure.noGain("Already below the size limit; original unchanged.") }
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let attributes = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as NSDictionary?,
              let width = (attributes.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue,
              let height = (attributes.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue else {
            throw TuckFailure.invalidInput("This image can't be decoded.")
        }
        let format = source.pathExtension.lowercased()
        // PNG stays PNG to avoid destroying transparency. JPEG/HEIC/TIFF are saved as JPEG.
        let alphaInfo = CGImageSourceCreateImageAtIndex(input, 0, nil)?.alphaInfo
        let hasAlpha: Bool = {
            switch alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast: return true
            default: return false
            }
        }()
        let preservePNG = format == "png" || hasAlpha
        let outputExt = preservePNG ? "png" : "jpg"
        let outputType = (preservePNG ? UTType.png : UTType.jpeg).identifier as CFString
        let maximum = max(width, height)
        var selected: Data?
        for factor in [1.0, 0.88, 0.76, 0.64, 0.52, 0.40, 0.30, 0.20] {
            let side = max(96, Int(Double(maximum) * factor))
            let settings: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as! String: true,
                kCGImageSourceCreateThumbnailWithTransform as! String: true,
                kCGImageSourceThumbnailMaxPixelSize as! String: side
            ]
            guard let frame = CGImageSourceCreateThumbnailAtIndex(input, 0, settings as CFDictionary) else { continue }
            if preservePNG {
                if let candidate = encode(frame, type: outputType, quality: 1), candidate.count <= targetBytes {
                    selected = candidate; break
                }
            } else {
                var low = 0.12, high = 0.94
                var candidate: Data?
                for _ in 0..<9 {
                    let mid = (low + high) / 2
                    guard let attempt = encode(frame, type: outputType, quality: mid) else { break }
                    if attempt.count <= targetBytes {
                        candidate = attempt
                        low = mid
                    } else { high = mid }
                }
                if let candidate { selected = candidate; break }
            }
        }
        guard let result = selected, result.count < originalBytes else {
            throw TuckFailure.noGain("Couldn't reach that size while retaining a usable image. No output saved.")
        }
        let output = uniqueDestination(for: source, suffix: "-compressed", ext: outputExt)
        // Atomic exclusive write; never replace the user's originals or prior exports.
        try result.write(to: output, options: [.atomic, .withoutOverwriting])
        return output
    }

    private static func encode(_ image: CGImage, type: CFString, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, type, 1, nil) else { return nil }
        let options: [String: Any] = [kCGImageDestinationLossyCompressionQuality as! String: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
