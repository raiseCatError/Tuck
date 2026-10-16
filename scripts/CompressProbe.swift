import AppKit
import Foundation
import CryptoKit

// Runs the shipped compression engine over fixtures and prints what it chose.
// Compiled against the app sources by scripts/compress-probe.sh.
// Usage: compress-probe <targetMB> <file> [file...]

@main
struct CompressProbe {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let target = Double(arguments[1]) else {
            print("usage: compress-probe <targetMB> <file>...")
            exit(2)
        }
        let paths = Array(arguments.dropFirst(2))
        let limit = CompressionTarget(megabytes: target)
        print(String(format: "target %.3f MB -> %d bytes (strictly under)", target, limit.maxBytes))
        var before: [URL: String] = [:]
        for path in paths { before[URL(fileURLWithPath: path)] = sha256(path) }

        let started = Date()
        let outcome = CompressionEngine.compress(paths: paths, target: limit,
                                                 progress: { _ in }, shouldCancel: { false })
        print(String(format: "took %.1fs", Date().timeIntervalSince(started)))

        for result in outcome.results {
            let megabytes = String(format: "%.3f", Double(result.resultBytes) / 1_000_000)
            let original = String(format: "%.3f", Double(result.originalBytes) / 1_000_000)
            let within = result.resultBytes < limit.maxBytes
            print("  \(result.source.lastPathComponent): \(original) MB -> \(megabytes) MB"
                  + " (\(String(format: "%.1f", result.reductionPercent))% smaller)"
                  + " underLimit=\(within) strategy=\(result.strategy)")
            if let output = result.output {
                let source = result.source
                let score = (try? score(source: source, candidate: output)) ?? 0
                print("      output: \(output.lastPathComponent)  ssim=\(String(format: "%.4f", score))")
            }
        }
        for (url, failure) in outcome.failures {
            print("  \(url.lastPathComponent): FAILED — \(failure.description)")
        }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let after = sha256(path)
            if before[url] != after {
                print("  !! ORIGINAL CHANGED: \(url.lastPathComponent)")
            }
        }
        print("  originals verified unchanged: \(before.count) file(s)")
    }

    static func sha256(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SSIM of a published result against its original, when both are images.
    static func score(source: URL, candidate: URL) throws -> Double {
        let original = try ImageFacts.frame(source, maxPixel: 4_000_000)
        let result = try ImageFacts.frame(candidate, maxPixel: 4_000_000)
        return Fidelity.ssim(original: original, candidate: result)
    }
}