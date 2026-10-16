import Foundation
import CoreGraphics

// The search itself. For every available encoder it walks a resolution ladder,
// finds the highest setting that fits under the hard limit, scores the result
// against the original, and keeps the most faithful file that fits. The first
// result that happens to fit is never taken on faith.

struct SearchPolicy: Sendable {
    var maxEncodes: Int = 30
    var timeBudget: TimeInterval = 120
    /// Stop descending once a step cannot beat the best fidelity so far.
    var fidelityPlateau: Double = 0.0008
    /// Above this the result is visually indistinguishable from the original.
    var excellentEnough: Double = 0.997
    var shouldCancel: @Sendable () -> Bool = { false }

    static let `default` = SearchPolicy()
}

struct EncodeOutcome: Sendable {
    let file: URL
    let bytes: Int
    let lossless: Bool
    let note: String
}

/// One encoder at one resolution. Implementations must be cheap to describe and
/// must never publish anything themselves: they only write into the work area.
protocol CandidateMaker: AnyObject {
    var name: String { get }
    /// Highest quality the encoder supports, in its own 0...1 space.
    var maximumQuality: Double { get }
    var supportsQuality: Bool { get }
    func encode(image: CGImage, quality: Double, into work: WorkArea) throws -> EncodeOutcome?
}

extension CandidateMaker {
    var supportsQuality: Bool { true }
}

enum Searcher {
    /// Resolution ladder. Full resolution first: downscaling is the most visible
    /// change, so it is only spent when full resolution cannot deliver.
    static let ladder: [Double] = [1.0, 0.85, 0.72, 0.6, 0.5, 0.4, 0.32, 0.25, 0.2, 0.15]

    struct Outcome: Sendable {
        var best: CompressionCandidate?
        var bestBytes: Int = 0
        var bestStrategy: String = "no encoder ran"
        var encodes: Int = 0
        var seconds: TimeInterval = 0
    }

    static func search(makers: [CandidateMaker],
                       reference: CGImage,
                       target: CompressionTarget,
                       work: WorkArea,
                       strategy: (String) -> String,
                       policy: SearchPolicy) -> Outcome {
        var outcome = Outcome()
        let started = Date()
        var best: CompressionCandidate?
        var bestFidelity = -1.0

        for maker in makers {
            if policy.shouldCancel() { break }
            if outcome.encodes >= policy.maxEncodes { break }
            if Date().timeIntervalSince(started) > policy.timeBudget { break }

            for scale in ladder {
                if policy.shouldCancel() { return outcome }
                if outcome.encodes >= policy.maxEncodes { break }
                if Date().timeIntervalSince(started) > policy.timeBudget { break }
                let scaled = scale == 1.0 ? reference : ImageFacts.scale(reference, toMaxPixel: Int(Double(max(reference.width, reference.height)) * scale))
                guard scaled.width >= 32, scaled.height >= 32 else { break }

                guard let attempt = bestFit(maker: maker, image: scaled, target: target, work: work,
                                            policy: policy, budget: &outcome.encodes, started: started) else { continue }
                let fidelity = Fidelity.ssim(original: reference, candidateFile: attempt.file)
                let candidate = CompressionCandidate(file: attempt.file, bytes: attempt.bytes,
                                                     strategy: strategy(maker.name), fidelity: fidelity,
                                                     scale: scale, lossless: attempt.lossless)
                outcome.bestBytes = max(outcome.bestBytes, candidate.bytes)
                outcome.bestStrategy = candidate.strategy
                if fidelity > bestFidelity {
                    // Only the leading candidate must survive until publishing.
                    if let previous = best, previous.file != candidate.file {
                        work.discard(previous.file)
                    }
                    bestFidelity = fidelity
                    best = candidate
                    if attempt.lossless { break }
                } else {
                    work.discard(candidate.file)
                }
                // A smaller image only earns its place if it is measurably better.
                if bestFidelity >= policy.excellentEnough { break }
                if scale > 1.0 && bestFidelity >= policy.excellentEnough { break }
                if scale > 0.2, best != nil, fidelity < bestFidelity - policy.fidelityPlateau,
                   let previous = best, previous.scale > scale, previous.fidelity >= bestFidelity - policy.fidelityPlateau {
                    break
                }
            }
            if bestFidelity >= policy.excellentEnough { break }
        }
        outcome.best = best
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    /// Binary search for the largest quality whose output still fits. Size grows
    /// monotonically with quality for every encoder used here.
    private static func bestFit(maker: CandidateMaker,
                                image: CGImage,
                                target: CompressionTarget,
                                work: WorkArea,
                                policy: SearchPolicy,
                                budget: inout Int,
                                started: Date) -> EncodeOutcome? {
        if !maker.supportsQuality {
            guard budget < policy.maxEncodes, Date().timeIntervalSince(started) <= policy.timeBudget else { return nil }
            guard !policy.shouldCancel() else { return nil }
            budget += 1
            guard let attempt = try? maker.encode(image: image, quality: maker.maximumQuality, into: work) else { return nil }
            if attempt.bytes < target.maxBytes { return attempt }
            work.discard(attempt.file)
            return nil
        }

        var low = 0.05, high = maker.maximumQuality
        var best: EncodeOutcome?
        while budget < policy.maxEncodes && Date().timeIntervalSince(started) <= policy.timeBudget {
            if policy.shouldCancel() { return best }
            let middle = (low + high) / 2
            guard let attempt = try? maker.encode(image: image, quality: middle, into: work) else { break }
            budget += 1
            if attempt.bytes < target.maxBytes {
                if let previous = best, previous.file != attempt.file {
                    work.discard(previous.file)
                }
                best = attempt
                low = middle
            } else {
                work.discard(attempt.file)
                high = middle
            }
            if high - low < 0.012 { break }
        }
        return best
    }
}