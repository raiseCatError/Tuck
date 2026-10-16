import Foundation
import UniformTypeIdentifiers

// The single user-facing parameter: the largest acceptable output size.
// Limits are decimal megabytes, so "Under 5 MB" means strictly below 5,000,000
// bytes, which satisfies conservative upload limits.
struct CompressionTarget: Sendable, Equatable {
    let maxBytes: Int

    init(megabytes: Double) {
        let bytes = (megabytes * 1_000_000).rounded(.down)
        self.maxBytes = max(1, Int(bytes))
    }

    var megabytes: Double { Double(maxBytes) / 1_000_000 }
    var description: String {
        let value = megabytes
        return value == value.rounded() ? "\(Int(value)) MB" : String(format: "%.2f MB", value)
    }
}

/// Why an operation could not produce a file. Every case becomes a sentence the
/// user can act on, so nothing fails silently.
enum CompressionFailure: Error, CustomStringConvertible {
    case invalidInput(String)
    case unsupportedFormat(String)
    case encoderUnavailable(String)
    case unattainableSize(target: CompressionTarget, bestBytes: Int, bestStrategy: String)
    case unreadableSource(String)
    case permissionDenied(String)
    case corruptedSource(String)
    case verificationFailed(String)
    case cancelled

    var description: String {
        switch self {
        case .invalidInput(let detail):
            return detail
        case .unsupportedFormat(let detail):
            return "Unsupported format. \(detail)"
        case .encoderUnavailable(let detail):
            return "No usable encoder. \(detail)"
        case .unattainableSize(let target, let bestBytes, let bestStrategy):
            let megabytes = String(format: "%.2f", Double(bestBytes) / 1_000_000)
            return "Could not reach \(target.description) without sacrificing quality. The best safe result (\(bestStrategy)) was \(megabytes) MB. The original is untouched."
        case .unreadableSource(let detail):
            return "Could not read the file. \(detail)"
        case .permissionDenied(let detail):
            return "Permission denied. \(detail)"
        case .corruptedSource(let detail):
            return "The file appears damaged. \(detail)"
        case .verificationFailed(let detail):
            return "The result failed verification and was discarded. \(detail)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// One candidate output considered during the search.
struct CompressionCandidate: Sendable {
    let file: URL
    let bytes: Int
    let strategy: String
    /// Mean SSIM against the original, 1.0 is identical. Ranking signal only.
    let fidelity: Double
    let scale: Double
    let lossless: Bool
}

struct CompressionProgress: Sendable {
    let index: Int
    let total: Int
    let fileName: String
    let fraction: Double
    let note: String
}

/// What happened to one input file.
struct CompressionResult: Sendable {
    let source: URL
    let output: URL?
    let originalBytes: Int
    let resultBytes: Int
    let strategy: String
    let alreadyWithinLimit: Bool

    var reductionPercent: Double {
        guard originalBytes > 0 else { return 0 }
        return (1 - Double(resultBytes) / Double(originalBytes)) * 100
    }
}

enum ImageFamily: Sendable {
    case jpegLike   // JPEG sources: baseline JPEG output
    case pngLike    // PNG sources: must stay PNG
    case heicLike   // HEIC sources: must stay HEIC
    case tiffLike   // TIFF sources: must stay TIFF
    case bmpLike    // BMP sources: must stay BMP
    case pdfLike
    case other
}

struct SourceFacts: Sendable {
    let family: ImageFamily
    let type: UTType?
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
    let hasAlpha: Bool
    let bitsPerComponent: Int
    let embedsProfile: Bool
    let orientation: Int
    let byteSize: Int

    var isAnimatedOrMultiFrame: Bool { frameCount > 1 }
    var pixelCount: Int { pixelWidth * pixelHeight }
    var aspect: Double { pixelHeight == 0 ? 1 : Double(pixelWidth) / Double(pixelHeight) }
}

// Failures are thrown as `CompressionFailure` directly; the enum conforms to
// `CustomStringConvertible` so every message is already user ready.