import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Focused regressions for bugs found in the pre-release audit.
@main
struct CompressionHygieneTests {
    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("tuck-hygiene-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let image = dir.appendingPathComponent("source.png")
        guard let context = CGContext(data: nil, width: 12, height: 12,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.makeImage(),
              let encoder = CGImageDestinationCreateWithURL(
                image as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Could not create source image fixture.")
        }
        CGImageDestinationAddImage(encoder, pixels, nil)
        assert(CGImageDestinationFinalize(encoder))

        // An encoder's previous winning candidate must not disappear when
        // another encode runs in the same WorkArea.
        let work = try WorkArea(beside: image)
        defer { work.clean() }
        let maker = ImageIOJPEGMaker(shouldCancel: { false })
        guard let first = try maker.encode(image: pixels, quality: 0.85, into: work),
              let second = try maker.encode(image: pixels, quality: 0.95, into: work) else {
            fatalError("JPEG candidate encoder failed.")
        }
        assert(first.file != second.file)
        assert(fm.fileExists(atPath: first.file.path))
        assert(fm.fileExists(atPath: second.file.path))
        try ImageFacts.validate(first.file, expecting: .jpeg, pixelSize: nil)

        // Regression: the sender permits 256 but the worker used to silently
        // process only the first 16 inputs.
        let originalHash = try CopyAsToolkit.sha256(url: image)
        let result = CompressionEngine.compress(paths: Array(repeating: image.path, count: 17),
             target: CompressionTarget(megabytes: 1), progress: { _ in }, shouldCancel: { false })
        assert(result.failures.isEmpty, "Every input in the batch must be processed.")
        assert(result.results.count == 17, "Compression must not truncate at 16 inputs.")
        assert(result.results.allSatisfy { $0.resultBytes < 1_000_000 })
        let unchangedHash = try CopyAsToolkit.sha256(url: image)
        assert(unchangedHash == originalHash)

        let inputs = (0..<17).map { index -> URL in
            let url = dir.appendingPathComponent("archive-\(index).txt")
            try! Data("item-\(index)".utf8).write(to: url)
            return url
        }
        let zip = try FileWork.zip(inputs.map(\.path), progress: { _ in }, shouldCancel: { false })
        assert(zip.file.pathExtension == "zip", "ZIP output must have a .zip extension.")
        assert(fm.fileExists(atPath: zip.file.path))
        let unzip = Tool(name: "unzip", url: URL(fileURLWithPath: "/usr/bin/unzip"))
        try Toolchain.run(unzip, ["-t", zip.file.path], timeout: 30)
        for url in inputs {
            assert(fm.fileExists(atPath: url.path))
        }
        // Repeat an archive operation without overwriting the original result.
        let again = try FileWork.zip([inputs[0].path], progress: { _ in }, shouldCancel: { false })
        assert(again.file.pathExtension == "zip")
        assert(zip.file != again.file)
        print("CompressionHygieneTests passed")
    }
}
