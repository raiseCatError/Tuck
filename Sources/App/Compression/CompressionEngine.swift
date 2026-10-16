import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit

// The one parameter the user controls is the maximum output size. Everything
// else is decided here: the original is measured, the best available strategy is
// searched, the result is verified, and only then is it published atomically
// next to the original.

enum CompressionEngine {
    struct Outcome: Sendable {
        var results: [CompressionResult] = []
        var failures: [(URL, CompressionFailure)] = []
    }

    static func compress(paths: [String],
                         target: CompressionTarget,
                         progress: @Sendable @escaping (CompressionProgress) -> Void,
                         shouldCancel: @Sendable @escaping () -> Bool) -> Outcome {
        var outcome = Outcome()
        let sources = paths.map { URL(fileURLWithPath: $0) }
        let total = max(1, sources.count)
        for (index, source) in sources.enumerated() {
            if shouldCancel() {
                outcome.failures.append((source, .cancelled))
                continue
            }
            let base = Double(index) / Double(total)
            let report: @Sendable (Double, String) -> Void = { fraction, note in
                progress(CompressionProgress(index: index, total: total,
                                            fileName: source.lastPathComponent,
                                            fraction: base + fraction / Double(total),
                                            note: note))
            }
            do {
                let result = try compressOne(source: source, target: target, report: report, shouldCancel: shouldCancel)
                outcome.results.append(result)
                TuckLog.compressionLogger.info("compress.result file=\(source.lastPathComponent, privacy: .private) original=\(result.originalBytes) output=\(result.resultBytes) strategy=\(result.strategy, privacy: .public) withinLimit=\(result.resultBytes < target.maxBytes)")
            } catch let error as CompressionFailure {
                outcome.failures.append((source, error))
                TuckLog.compressionLogger.error("compress.failed file=\(source.lastPathComponent, privacy: .private) reason=\(error.description, privacy: .private)")
            } catch {
                outcome.failures.append((source, .unreadableSource(error.localizedDescription)))
            }
        }
        progress(CompressionProgress(index: total, total: total, fileName: "", fraction: 1, note: "Done"))
        return outcome
    }

    // MARK: - One file

    static func compressOne(source: URL,
                            target: CompressionTarget,
                            report: @Sendable @escaping (Double, String) -> Void,
                            shouldCancel: @Sendable @escaping () -> Bool) throws -> CompressionResult {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isReadableKey])
        guard values.isReadable == true else {
            throw CompressionFailure.permissionDenied("Tuck cannot read \(source.lastPathComponent).")
        }
        guard values.isDirectory != true else {
            throw CompressionFailure.unsupportedFormat("Folders are handled by Create ZIP Archive.")
        }
        let originalBytes = values.fileSize ?? 0
        guard originalBytes > 0 else {
            throw CompressionFailure.corruptedSource("The file is empty.")
        }
        // PDFs are not images, so they are routed by extension before any
        // ImageIO inspection is attempted.
        let type = UTType(filenameExtension: source.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true || type == .pdf {
            return try compressPDF(source: source, originalBytes: originalBytes, target: target,
                                   report: report, shouldCancel: shouldCancel)
        }
        let facts = try ImageFacts.analyze(source)
        report(0.05, "Reading \(facts.pixelWidth)×\(facts.pixelHeight)")
        guard facts.family != .other else {
            throw CompressionFailure.unsupportedFormat(
                "\(source.pathExtension.uppercased()) files are not supported for size reduction. Use Create ZIP Archive instead.")
        }
        guard !facts.isAnimatedOrMultiFrame else {
            throw CompressionFailure.unsupportedFormat("Animated or multi-frame images are left untouched.")
        }

        let work = try WorkArea(beside: source)
        defer { work.clean() }

        // Already small enough: ship a lossless or byte identical copy.
        if originalBytes < target.maxBytes {
            report(0.3, "Already under the limit, optimising losslessly")
            if let copy = try losslessCopy(source: source, facts: facts, work: work, shouldCancel: shouldCancel) {
                let published = try OutputName.publish(copy.file, beside: source)
                return CompressionResult(source: source, output: published, originalBytes: originalBytes,
                                         resultBytes: copy.bytes, strategy: copy.note, alreadyWithinLimit: true)
            }
            throw CompressionFailure.unattainableSize(target: target, bestBytes: originalBytes,
                                                             bestStrategy: "the original file")
        }

        // Needs real work: decode once, bounded so a huge photo cannot explode memory.
        let decodeLimit = 30_000_000.0
        let boundedMaxEdge = Int(decodeLimit.squareRoot() * 3)
        let reference = try ImageFacts.frame(source, maxPixel: Double(facts.pixelCount) > decodeLimit ? boundedMaxEdge : 0)
        try work.requireSpace(bytes: reference.width * reference.height * 4)

        var candidates: [CompressionCandidate] = []
        switch facts.family {
        case .jpegLike:
            candidates = imageCandidates(source: source, facts: facts, reference: reference,
                                         target: target, work: work, report: report, shouldCancel: shouldCancel,
                                         makers: JPEGPlan.makers(facts: facts, shouldCancel: shouldCancel),
                                         losslessName: "lossless JPEG rewrite")
        case .pngLike:
            candidates = try pngCandidates(source: source, facts: facts, reference: reference,
                                           target: target, work: work, report: report, shouldCancel: shouldCancel)
        case .heicLike, .tiffLike, .bmpLike:
            let type = facts.type ?? .data
            candidates = imageCandidates(source: source, facts: facts, reference: reference,
                                         target: target, work: work, report: report, shouldCancel: shouldCancel,
                                         makers: [ImageIOCodecMaker(name: "\(type.localizedDescription ?? "ImageIO")", type: type, shouldCancel: shouldCancel)],
                                         losslessName: "lossless recompression")
        default:
            break
        }

        guard let best = select(candidates: candidates, target: target, logLabel: "image") else {
            for candidate in candidates { work.discard(candidate.file) }
            let smallest = candidates.map(\.bytes).min() ?? originalBytes
            let strategy = candidates.first?.strategy ?? "available encoders"
            throw CompressionFailure.unattainableSize(target: target, bestBytes: smallest, bestStrategy: strategy)
        }
        report(0.92, "Verifying \(best.strategy)")
        try validate(best, facts: facts, source: source)
        for candidate in candidates where candidate.file != best.file { work.discard(candidate.file) }
        _ = work.track(best.file)
        let published = try OutputName.publish(best.file, beside: source)
        report(1.0, "Finished")
        return CompressionResult(source: source, output: published, originalBytes: originalBytes,
                                 resultBytes: best.bytes, strategy: best.strategy, alreadyWithinLimit: false)
    }

    // MARK: - Ranking

    /// Most faithful first; lossless beats lossy, then larger resolution, then
    /// fewer bytes. This is the "do not take the first result that fits" rule.
///
/// The comparisons are *quantised*, not tolerance based: `max(by:)` requires a
    /// strict weak ordering, and a "close enough" tolerance on fidelity breaks
    /// transitivity (A ~ B by fidelity, B ~ C by bytes, yet A > C), which makes
    /// the winner depend on iteration order.
    static func better(_ lhs: CompressionCandidate, _ rhs: CompressionCandidate) -> Bool {
        let fidelityRank = (lhs.fidelity * 20_000).rounded()   // 0.00005 steps
        let otherRank = (rhs.fidelity * 20_000).rounded()
        if fidelityRank != otherRank { return fidelityRank > otherRank }
        if lhs.lossless != rhs.lossless { return lhs.lossless }
        let scaleRank = (lhs.scale * 1_000).rounded()
        let otherScale = (rhs.scale * 1_000).rounded()
        if scaleRank != otherScale { return scaleRank > otherScale }
        return lhs.bytes < rhs.bytes
    }

    /// The single place a winner is chosen, with the full comparison logged.
    ///
    /// `max(by:)` is deliberately not used: the standard library compares every
    /// element against the *first* one, so a merely ordered comparison chain
    /// cascades downwards and the last candidate can win. An explicit fold over
    /// a transitive comparator returns the true maximum.
    static func select(candidates: [CompressionCandidate], target: CompressionTarget, logLabel: String) -> CompressionCandidate? {
        let eligible = candidates.filter { $0.bytes < target.maxBytes }
        var best: CompressionCandidate?
        for candidate in eligible {
            if let current = best {
                if better(candidate, current) { best = candidate }
            } else {
                best = candidate
            }
        }
        for candidate in candidates {
            TuckLog.compressionLogger.info("compress.candidate kind=\(logLabel, privacy: .public) bytes=\(candidate.bytes) fidelity=\(String(format: "%.4f", candidate.fidelity), privacy: .public) scale=\(String(format: "%.2f", candidate.scale), privacy: .public) lossless=\(candidate.lossless) fits=\(candidate.bytes < target.maxBytes) chosen=\(best?.file == candidate.file) strategy=\(candidate.strategy, privacy: .public)")
        }
        return best
    }

    // MARK: - Images

    private static func imageCandidates(source: URL, facts: SourceFacts, reference: CGImage, target: CompressionTarget,
                                       work: WorkArea, report: @Sendable @escaping (Double, String) -> Void,
                                       shouldCancel: @Sendable @escaping () -> Bool,
                                       makers: [CandidateMaker],
                                       losslessName: String) -> [CompressionCandidate] {
        var candidates: [CompressionCandidate] = []
        report(0.1, "Trying lossless optimisation")
        if let lossless = LosslessJPEG.attempt(source, into: work, shouldCancel: shouldCancel) {
            candidates.append(CompressionCandidate(file: lossless.file, bytes: lossless.bytes, strategy: losslessName,
                                                   fidelity: 1.0, scale: 1.0, lossless: true))
        }
        var policy = SearchPolicy.default
        policy.shouldCancel = shouldCancel
        let outcome = Searcher.search(makers: makers, reference: reference, target: target, work: work,
                                      strategy: { "\($0)" }, policy: policy)
        report(0.85, "Compared \(outcome.encodes) encodes")
        TuckLog.compressionLogger.info("compress.search encodes=\(outcome.encodes) seconds=\(String(format: "%.1f", outcome.seconds))")
        if let best = outcome.best {
            candidates.append(best)
        }
        _ = facts
        return candidates
    }

    private static func pngCandidates(source: URL, facts: SourceFacts, reference: CGImage, target: CompressionTarget,
                                      work: WorkArea, report: @Sendable @escaping (Double, String) -> Void,
                                      shouldCancel: @Sendable @escaping () -> Bool) throws -> [CompressionCandidate] {
        var candidates = PNGPlan.lossless(source: source, target: target, work: work, shouldCancel: shouldCancel)
        if candidates.contains(where: { $0.bytes < target.maxBytes && $0.bytes < facts.byteSize }) {
            report(0.9, "Lossless PNG optimisation")
            return candidates
        }
        report(0.4, "Trying lossless downscaling")
        candidates += PNGPlan.downscaled(source: source, reference: reference, target: target,
                                        work: work, shouldCancel: shouldCancel)
        if candidates.contains(where: { $0.bytes < target.maxBytes }) { return candidates }
        if PNGPlan.paletteAllowed(facts) {
            report(0.7, "Trying palette optimisation")
            candidates += PNGPlan.palette(source: source, reference: reference, target: target,
                                          work: work, shouldCancel: shouldCancel)
        } else if facts.embedsProfile {
            TuckLog.compressionLogger.info("compress.png-skip-palette reason=embedded-icc-profile")
        }
        return candidates
    }

    /// Nothing to shrink: re-encode losslessly, or copy the bytes unchanged.
    private static func losslessCopy(source: URL, facts: SourceFacts, work: WorkArea,
                                     shouldCancel: @Sendable @escaping () -> Bool) throws -> EncodeOutcome? {
        var best: EncodeOutcome?
        switch facts.family {
        case .jpegLike:
            best = LosslessJPEG.attempt(source, into: work, shouldCancel: shouldCancel)
        case .pngLike:
            for candidate in PNGPlan.lossless(source: source, target: nil, work: work, shouldCancel: shouldCancel) {
                guard candidate.bytes < facts.byteSize else { work.discard(candidate.file); continue }
                best = EncodeOutcome(file: candidate.file, bytes: candidate.bytes, lossless: true, note: candidate.strategy)
                break
            }
        case .pdfLike:
            break
        default:
            break
        }
        if let best { return best }
        // Byte identical copy: the requested separate output, unchanged content.
        let copy = work.makeTemporary("verbatim", extension: source.pathExtension)
        if (try? FileManager.default.copyItem(at: source, to: copy)) != nil {
            return EncodeOutcome(file: copy, bytes: ImageFacts.byteSize(copy), lossless: true, note: "byte identical copy")
        }
        work.discard(copy)
        return nil
    }

    private static func validate(_ candidate: CompressionCandidate, facts: SourceFacts, source: URL) throws {
        let expected: CGSize? = abs(candidate.scale - 1.0) < 0.001
            ? CGSize(width: facts.pixelWidth, height: facts.pixelHeight)
            : nil
        let type: UTType?
        switch facts.family {
        case .jpegLike: type = .jpeg
        case .pngLike: type = .png
        case .heicLike: type = facts.type
        case .tiffLike: type = .tiff
        case .bmpLike: type = .bmp
        default: type = nil
        }
        guard let type else { throw CompressionFailure.verificationFailed("Unknown output format.") }
        try ImageFacts.validate(candidate.file, expecting: type, pixelSize: expected)
        // Alpha must survive only when the original is genuinely transparent.
        if facts.family == .pngLike, facts.hasAlpha {
            let output = try ImageFacts.frame(candidate.file)
            let sourceTransparent = ImageFacts.hasVisibleAlpha(try ImageFacts.frame(source))
            if sourceTransparent, !ImageFacts.hasVisibleAlpha(output) {
                throw CompressionFailure.verificationFailed("Transparency was lost.")
            }
        }
        _ = source
    }

    // MARK: - PDF

    private static func compressPDF(source: URL, originalBytes: Int, target: CompressionTarget,
                                    report: @Sendable @escaping (Double, String) -> Void,
                                    shouldCancel: @Sendable @escaping () -> Bool) throws -> CompressionResult {
        guard let original = PDFPlan.signature(source) else {
            throw CompressionFailure.corruptedSource("The PDF could not be opened.")
        }
        let work = try WorkArea(beside: source)
        defer { work.clean() }
        var candidates: [CompressionCandidate] = []

        report(0.15, "Optimising PDF structure")
        if let structural = PDFPlan.structural(source: source, work: work, shouldCancel: shouldCancel) {
            switch PDFPlan.verify(structural.file, against: original, keepsText: true) {
            case .success:
                candidates.append(CompressionCandidate(file: structural.file, bytes: structural.bytes,
                                                       strategy: "qpdf lossless optimisation", fidelity: 1.0,
                                                       scale: 1.0, lossless: true))
            case .failure(let failure):
                TuckLog.compressionLogger.error("pdf.structural-rejected reason=\(failure.description, privacy: .private)")
                work.discard(structural.file)
            }
        }
        if !candidates.contains(where: { $0.bytes < target.maxBytes }) {
            if originalBytes < target.maxBytes, candidates.isEmpty {
                let copy = work.makeTemporary("verbatim", extension: "pdf")
                try FileManager.default.copyItem(at: source, to: copy)
                candidates.append(CompressionCandidate(file: copy, bytes: ImageFacts.byteSize(copy),
                                                       strategy: "byte identical copy", fidelity: 1.0, scale: 1.0, lossless: true))
            } else if PDFPlan.looksImageHeavy(source) {
                report(0.4, "Recompressing embedded images")
                candidates += PDFPlan.imageRecompression(source: source, original: original, target: target,
                                                         work: work, shouldCancel: shouldCancel)
            }
        }
        guard let best = select(candidates: candidates, target: target, logLabel: "pdf") else {
            for candidate in candidates { work.discard(candidate.file) }
            let smallest = candidates.map(\.bytes).min() ?? originalBytes
            let strategy = candidates.first?.strategy ?? "lossless optimisation"
            throw CompressionFailure.unattainableSize(target: target, bestBytes: smallest, bestStrategy: strategy)
        }
        for candidate in candidates where candidate.file != best.file { work.discard(candidate.file) }
        report(0.95, "Verifying the PDF")
        let published = try OutputName.publish(best.file, beside: source)
        report(1, "Finished")
        return CompressionResult(source: source, output: published, originalBytes: originalBytes,
                                 resultBytes: best.bytes, strategy: best.strategy,
                                 alreadyWithinLimit: originalBytes < target.maxBytes)
    }
}