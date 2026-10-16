import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// JPEG work. Every encoder is fed the same sRGB pixels, so the only difference
// between candidates is the encoder itself. Nothing here is user selectable:
// the search picks whatever is most faithful under the limit.

/// External `cjpeg` (Jpegli, MozJPEG or libjpeg-turbo). They share a CLI, so
/// one implementation covers all three.
final class CjpegMaker: CandidateMaker {
    let name: String
    let maximumQuality = 1.0
    private let tool: Tool
    private let shouldCancel: @Sendable () -> Bool
    private let progressive: Bool

    init(name: String, tool: Tool, shouldCancel: @escaping @Sendable () -> Bool, progressive: Bool = true) {
        self.name = name
        self.tool = tool
        self.shouldCancel = shouldCancel
        self.progressive = progressive
    }

    func encode(image: CGImage, quality: Double, into work: WorkArea) throws -> EncodeOutcome? {
        let ppm = work.makeTemporary("cjpeg-in-\(UUID().uuidString)", extension: "ppm")
        try ImageFacts.writePPM(image, to: ppm)
        defer { work.discard(ppm) }
        let output = work.makeTemporary("cjpeg-out-\(UUID().uuidString)", extension: "jpg")
        // MozJPEG and Jpegli both expose -quality as 1...100; jpegli also accepts
        // a distance, but quality keeps the ladder comparable across encoders.
        let qualityNumber = String(Int((quality * 100).rounded()))
        let arguments: [String]
        if tool.name == "cjpegli" {
            // Jpegli uses positional INPUT OUTPUT followed by -q quality.
            arguments = [ppm.path, output.path, "-q", qualityNumber]
        } else {
            // MozJPEG and libjpeg-turbo use portable libjpeg -outfile syntax.
            arguments = ["-quality", qualityNumber] +
                (progressive ? ["-progressive"] : []) +
                ["-optimize", "-outfile", output.path, ppm.path]
        }
        guard (try? Toolchain.run(tool, arguments, timeout: 120, shouldCancel: shouldCancel)) != nil else {
            work.discard(output)
            return nil
        }
        let bytes = ImageFacts.byteSize(output)
        guard bytes > 0 else { work.discard(output); return nil }
        return EncodeOutcome(file: output, bytes: bytes, lossless: false, note: "quality \(Int(quality * 100))")
    }
}

/// Apple's own JPEG writer, always available.
final class ImageIOJPEGMaker: CandidateMaker {
    let name = "ImageIO JPEG"
    let maximumQuality = 1.0
    private let shouldCancel: @Sendable () -> Bool

    init(shouldCancel: @escaping @Sendable () -> Bool) {
        self.shouldCancel = shouldCancel
    }

    func encode(image: CGImage, quality: Double, into work: WorkArea) throws -> EncodeOutcome? {
        if shouldCancel() { return nil }
        let output = work.makeTemporary("imageio-\(UUID().uuidString)", extension: "jpg")
        do {
            try ImageFacts.encode(image, to: output, type: .jpeg, quality: quality,
                                  extra: [kCGImagePropertyOrientation: 1])
        } catch {
            work.discard(output)
            return nil
        }
        let bytes = ImageFacts.byteSize(output)
        guard bytes > 0 else { return nil }
        return EncodeOutcome(file: output, bytes: bytes, lossless: false, note: "quality \(String(format: "%.2f", quality))")
    }
}

/// HEIC keeps its own format: only ImageIO can write it here, so the search
/// varies quality and resolution instead of the encoder.
final class ImageIOCodecMaker: CandidateMaker {
    let name: String
    let maximumQuality = 1.0
    var supportsQuality: Bool { !type.conforms(to: .bmp) }
    private let type: UTType
    private let shouldCancel: @Sendable () -> Bool

    init(name: String, type: UTType, shouldCancel: @escaping @Sendable () -> Bool) {
        self.name = name
        self.type = type
        self.shouldCancel = shouldCancel
    }

    func encode(image: CGImage, quality: Double, into work: WorkArea) throws -> EncodeOutcome? {
        if shouldCancel() { return nil }
        let output = work.makeTemporary("codec-\(UUID().uuidString.prefix(6))", extension: type.preferredFilenameExtension ?? "bin")
        var extra: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if type.conforms(to: .tiff) { extra[kCGImagePropertyTIFFCompression] = 7 /* JPEG */ }
        do {
            try ImageFacts.encode(image, to: output, type: type, quality: quality, extra: extra)
        } catch {
            work.discard(output)
            return nil
        }
        let bytes = ImageFacts.byteSize(output)
        guard bytes > 0 else { return nil }
        return EncodeOutcome(file: output, bytes: bytes, lossless: false, note: "quality \(String(format: "%.2f", quality))")
    }
}

/// Reversible JPEG clean-up: re-optimises Huffman tables and progressive scan
/// script. Mathematically lossless, so it is preferred whenever it helps.
/// `-copy all` keeps colour and metadata markers intact.
enum LosslessJPEG {
    static func attempt(_ source: URL, into work: WorkArea, shouldCancel: @escaping @Sendable () -> Bool) -> EncodeOutcome? {
        for tool in [Toolchain.mozjpegTran, Toolchain.turboTran] {
            guard let tool else { continue }
            if shouldCancel() { return nil }
            let output = work.makeTemporary("jpegtran-\(UUID().uuidString)", extension: "jpg")
            let arguments = ["-optimize", "-progressive", "-copy", "all", "-outfile", output.path, source.path]
            guard (try? Toolchain.run(tool, arguments, timeout: 120, shouldCancel: shouldCancel)) != nil else {
                work.discard(output)
                continue
            }
            let bytes = ImageFacts.byteSize(output)
            if bytes > 0, bytes <= ImageFacts.byteSize(source) {
                return EncodeOutcome(file: output, bytes: bytes, lossless: true, note: "lossless Huffman/progressive rewrite")
            }
            work.discard(output)
        }
        return nil
    }
}

enum JPEGPlan {
    static func makers(facts: SourceFacts, shouldCancel: @escaping @Sendable () -> Bool) -> [CandidateMaker] {
        var makers: [CandidateMaker] = []
        if let jpegli = Toolchain.jpegli {
            makers.append(CjpegMaker(name: "Jpegli", tool: jpegli, shouldCancel: shouldCancel))
        }
        if let mozjpeg = Toolchain.mozjpeg {
            makers.append(CjpegMaker(name: "MozJPEG", tool: mozjpeg, shouldCancel: shouldCancel))
        }
        if let turbo = Toolchain.turboJPEG {
            makers.append(CjpegMaker(name: "libjpeg-turbo", tool: turbo, shouldCancel: shouldCancel))
        }
        makers.append(ImageIOJPEGMaker(shouldCancel: shouldCancel))
        _ = facts
        return makers
    }
}