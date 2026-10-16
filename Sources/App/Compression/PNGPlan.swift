import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// PNG work, in the order that protects quality best:
//   1. lossless recompression (oxipng, including Zopfli)
//   2. lossless downscaling, still a real PNG with its alpha channel
//   3. palette optimisation, only when nothing lossless fits and only when it
//      cannot disturb colour appearance
// A PNG is never turned into a JPEG and the extension always stays .png.

enum PNGPlan {
    /// Lossless recompression, cheapest first. The search stops at the first
    /// pass that fits, so the slow Zopfli pass only runs when it can matter.
    static func lossless(source: URL, target: CompressionTarget? = nil, work: WorkArea,
                         shouldCancel: @escaping @Sendable () -> Bool) -> [CompressionCandidate] {
        guard let oxipng = Toolchain.oxipng else { return [] }
        var candidates: [CompressionCandidate] = []
        let sourceBytes = ImageFacts.byteSize(source)
        // (flags, label). Zopfli is last and by far the slowest.
        let passes: [([String], String)] = [
            (["-o", "2", "--quiet"], "Oxipng lossless (level 2)"),
            (["-o", "4", "--quiet"], "Oxipng lossless (level 4)"),
            (["-o", "max", "-Z", "--quiet"], "Oxipng lossless (level max + Zopfli)")
        ]
        for (pass, label) in passes {
            if shouldCancel() { break }
            let output = work.makeTemporary("oxipng-\(pass.joined(separator: "") .prefix(12))", extension: "png")
            let arguments = pass + ["--out", output.path, "--", source.path]
            guard (try? Toolchain.run(oxipng, arguments, timeout: 900, shouldCancel: shouldCancel)) != nil else {
                work.discard(output)
                continue
            }
            let bytes = ImageFacts.byteSize(output)
            guard bytes > 0 else { work.discard(output); continue }
            candidates.append(CompressionCandidate(file: output, bytes: bytes, strategy: label,
                                                   fidelity: 1.0, scale: 1.0, lossless: true))
            // Good enough: a lossless result that fits and is smaller than the
            // original ends the search. Anything else is wasted minutes.
            if let target, bytes < target.maxBytes, bytes < sourceBytes { break }
        }
        return candidates
    }

    /// High quality downscaling, then lossless recompression of the result.
    static func downscaled(source: URL, reference: CGImage, target: CompressionTarget,
                           work: WorkArea, shouldCancel: @escaping @Sendable () -> Bool) -> [CompressionCandidate] {
        guard let oxipng = Toolchain.oxipng else { return [] }
        var candidates: [CompressionCandidate] = []
        for scale in [0.75, 0.6, 0.5, 0.4, 0.3, 0.22] {
            if shouldCancel() { break }
            let scaled = ImageFacts.scale(reference, toMaxPixel: Int(Double(max(reference.width, reference.height)) * scale))
            guard scaled.width >= 64, scaled.height >= 64 else { break }
            let intermediate = work.makeTemporary("scaled-\(Int(scale * 100))", extension: "png")
            guard (try? ImageFacts.writePNG(scaled, to: intermediate)) != nil else { work.discard(intermediate); continue }
            let output = work.makeTemporary("oxipng-scaled-\(Int(scale * 100))", extension: "png")
            let arguments = ["-o", "2", "--quiet", "--out", output.path, "--", intermediate.path]
            let ok = (try? Toolchain.run(oxipng, arguments, timeout: 300, shouldCancel: shouldCancel)) != nil
            work.discard(intermediate)
            guard ok else { work.discard(output); continue }
            let bytes = ImageFacts.byteSize(output)
            guard bytes > 0 else { work.discard(output); continue }
            if bytes < target.maxBytes {
                candidates.append(CompressionCandidate(file: output, bytes: bytes,
                                                       strategy: "Oxipng at \(Int(scale * 100))% resolution",
                                                       fidelity: Fidelity.ssim(original: reference, candidate: scaled),
                                                       scale: scale, lossless: false))
            } else {
                work.discard(output)
            }
        }
        return candidates
    }

    /// Palette optimisation. pngquant cannot carry an ICC profile, so it is only
    /// offered when the image has no embedded profile whose removal could shift
    /// colour. Transparency is preserved by pngquant.
    static func paletteAllowed(_ facts: SourceFacts) -> Bool {
        !facts.isAnimatedOrMultiFrame && !facts.embedsProfile
    }

    static func palette(source: URL, reference: CGImage, target: CompressionTarget,
                        work: WorkArea, shouldCancel: @escaping @Sendable () -> Bool) -> [CompressionCandidate] {
        guard let pngquant = Toolchain.pngquant else { return [] }
        var candidates: [CompressionCandidate] = []
        // A few fidelity levels; pngquant's own quality gate stops it from
        // returning something visually unacceptable.
        for quality in [90, 75, 60] {
            if shouldCancel() { break }
            let output = work.makeTemporary("pngquant-\(quality)", extension: "png")
            let arguments = ["--force", "--quality", "\(quality)-\(quality)", "--speed", "1",
                             "--output", output.path, "--", source.path]
            guard (try? Toolchain.run(pngquant, arguments, timeout: 300, shouldCancel: shouldCancel)) != nil else {
                work.discard(output)
                continue
            }
            let bytes = ImageFacts.byteSize(output)
            guard bytes > 0 else { work.discard(output); continue }
            guard bytes < target.maxBytes else { work.discard(output); continue }
            guard let image = try? ImageFacts.frame(output) else { work.discard(output); continue }
            candidates.append(CompressionCandidate(file: output, bytes: bytes,
                                                   strategy: "pngquant palette (quality \(quality))",
                                                   fidelity: Fidelity.ssim(original: reference, candidate: image),
                                                   scale: 1.0, lossless: false))
        }
        return candidates
    }
}