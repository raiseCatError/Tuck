import Foundation
import CoreGraphics

// Structural similarity between the original and a candidate. It is a ranking
// signal, not a verdict: it decides which of several valid files is the best
// one to publish. Both images are reduced to a common, bounded size first so a
// 50 megapixel original cannot blow up memory or time.

enum Fidelity {
    /// Upper bound for the comparison resolution. The comparison size is derived
    /// from the original, never from the candidate: a fixed comparison size can
    /// coincide exactly with a downscaled candidate, which then compares equal to
    /// itself and scores a meaningless 1.0.
    static let compareMaxPixel = 1600

    static func ssim(original: CGImage, candidate: CGImage) -> Double {
        let reference = ImageFacts.scale(original, toMaxPixel: compareMaxPixel)
        let width = reference.width, height = reference.height
        guard width > 8, height > 8 else { return 1 }
        guard let a = ImageFacts.srgbBytes(reference, width: width, height: height),
              let b = ImageFacts.srgbBytes(resized(candidate, width: width, height: height),
                                           width: width, height: height) else {
            return 0
        }
        return meanSSIM(a.pixels, b.pixels, width: width, height: height)
    }

    /// Decodes a file and compares it against a reference frame.
    static func ssim(original: CGImage, candidateFile url: URL) -> Double {
        guard let image = try? ImageFacts.frame(url) else { return 0 }
        return ssim(original: original, candidate: image)
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard image.width != width || image.height != height else { return image }
        guard let context = ImageFacts.makeContext(width: width, height: height, alpha: true) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Mean SSIM over 8x8 windows with a stride of 4, on luma. Standard
    /// constants: C1 = (0.01 * 255)^2, C2 = (0.03 * 255)^2.
    static func meanSSIM(_ lhs: [UInt8], _ rhs: [UInt8], width: Int, height: Int) -> Double {
        let window = 8, stride = 4
        guard width >= window, height >= window else { return 1 }
        var lumaA = [Double](repeating: 0, count: width * height)
        var lumaB = [Double](repeating: 0, count: width * height)
        for index in 0 ..< width * height {
            let base = index * 4
            lumaA[index] = 0.299 * Double(lhs[base]) + 0.587 * Double(lhs[base + 1]) + 0.114 * Double(lhs[base + 2])
            lumaB[index] = 0.299 * Double(rhs[base]) + 0.587 * Double(rhs[base + 1]) + 0.114 * Double(rhs[base + 2])
        }
        let c1 = 6.5025, c2 = 58.5225
        var total = 0.0, count = 0.0
        var y = 0
        while y + window <= height {
            var x = 0
            while x + window <= width {
                var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                for row in 0 ..< window {
                    let base = (y + row) * width + x
                    for column in 0 ..< window {
                        let a = lumaA[base + column]
                        let b = lumaB[base + column]
                        sumA += a; sumB += b
                        sumAA += a * a; sumBB += b * b; sumAB += a * b
                    }
                }
                let n = Double(window * window)
                let meanA = sumA / n, meanB = sumB / n
                let varianceA = max(0, sumAA / n - meanA * meanA)
                let varianceB = max(0, sumBB / n - meanB * meanB)
                let covariance = sumAB / n - meanA * meanB
                let numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2)
                let denominator = (meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2)
                total += denominator == 0 ? 1 : numerator / denominator
                count += 1
                x += stride
            }
            y += stride
        }
        guard count > 0 else { return 1 }
        return total / count
    }

    /// Peak signal to noise ratio, used only as a secondary signal and for logs.
    static func psnr(original: CGImage, candidate: CGImage) -> Double {
        let reference = ImageFacts.scale(original, toMaxPixel: compareMaxPixel)
        let width = reference.width, height = reference.height
        guard width > 0, height > 0,
              let a = ImageFacts.srgbBytes(reference, width: width, height: height),
              let b = ImageFacts.srgbBytes(resized(candidate, width: width, height: height), width: width, height: height) else {
            return 0
        }
        var sum = 0.0
        for index in 0 ..< width * height {
            let base = index * 4
            for channel in 0 ..< 3 {
                let difference = Double(a.pixels[base + channel]) - Double(b.pixels[base + channel])
                sum += difference * difference
            }
        }
        let mse = sum / Double(width * height * 3)
        guard mse > 0 else { return 99 }
        return 10 * log10(255.0 * 255.0 / mse)
    }
}