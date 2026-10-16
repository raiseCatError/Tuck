import Foundation

// ZIP creation. Always a real, widely readable .zip using standard Deflate:
// 7-Zip's `-tzip -mx=9` when present, otherwise macOS ditto, otherwise zip.
// Alternative 7-Zip methods (LZMA, BZip2, Deflate64, PPMd) are deliberately not
// used because mainstream readers, including Finder, do not all handle them.

enum ZipEngine {
    struct Outcome: Sendable {
        let file: URL
        let bytes: Int
        let strategy: String
    }

    static func selectedStrategy() -> String {
        if sevenZip != nil { return "7-Zip Deflate (max)" }
        return "macOS ditto"
    }

    static var sevenZip: Tool? { Toolchain.sevenZip }

    static func archive(paths: [String], beside source: URL,
                        progress: @Sendable @escaping (Double) -> Void,
                        shouldCancel: @Sendable @escaping () -> Bool) throws -> Outcome {
        let fm = FileManager.default
        guard let first = paths.first else {
            throw CompressionFailure.invalidInput("Select one or more files or folders.")
        }
        guard paths.count <= 256 else {
            throw CompressionFailure.invalidInput("Select up to 256 items.")
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls where !fm.fileExists(atPath: url.path) {
            throw CompressionFailure.unreadableSource("\(url.lastPathComponent) no longer exists.")
        }
        let sourceURL = URL(fileURLWithPath: first)
        let parent = sourceURL.deletingLastPathComponent().standardizedFileURL
        if paths.count > 1 {
            let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent }
            guard sameParent else {
                throw CompressionFailure.invalidInput("For one archive, select items from the same folder.")
            }
        }
        if shouldCancel() { throw CompressionFailure.cancelled }

        let work = try WorkArea(beside: sourceURL)
        defer { work.clean() }

        if let sevenZip {
            progress(0.3)
            if let outcome = try withSevenZip(sevenZip, urls: urls, parent: parent, work: work, shouldCancel: shouldCancel) {
                let published = try OutputName.publish(outcome.file, beside: sourceURL, suffix: "-archive", extraExtension: "zip")
                progress(0.95)
                return Outcome(file: published, bytes: outcome.bytes, strategy: outcome.strategy)
            }
            TuckLog.compressionLogger.error("zip.sevenzip-failed; falling back to ditto")
        }
        progress(0.5)
        let outcome = try withDitto(urls: urls, source: sourceURL, work: work, shouldCancel: shouldCancel)
        let published = try OutputName.publish(outcome.file, beside: sourceURL, suffix: "-archive", extraExtension: "zip")
        progress(0.95)
        return Outcome(file: published, bytes: outcome.bytes, strategy: outcome.strategy)
    }

    /// 7-Zip, ZIP container, maximum Deflate. `-snl` keeps symlinks as links and
    /// `-spf` is deliberately not used; timestamps and the Unix mode bits are
    /// stored by the ZIP writer.
    private static func withSevenZip(_ tool: Tool, urls: [URL], parent: URL, work: WorkArea,
                                     shouldCancel: @escaping @Sendable () -> Bool) throws -> Outcome? {
        let temporary = work.makeTemporary("archive", extension: "zip")
        var arguments = ["a", "-tzip", "-mx=9", "-mmt=2", "-snl", "-bd", "-y", temporary.path, "--"]
        if urls.count == 1 {
            arguments.append(urls[0].lastPathComponent)
        } else {
            arguments.append(contentsOf: urls.map(\.lastPathComponent))
        }
        do {
            try Toolchain.run(tool, arguments, timeout: 900, shouldCancel: shouldCancel,
                              workingDirectory: parent)
        } catch ToolError.cancelled {
            work.discard(temporary)
            throw CompressionFailure.cancelled
        } catch ToolError.timedOut {
            work.discard(temporary)
            throw CompressionFailure.invalidInput("7-Zip timed out; the archive was not published.")
        } catch {
            work.discard(temporary)
            return nil
        }
        let bytes = ImageFacts.byteSize(temporary)
        guard bytes > 0 else { work.discard(temporary); return nil }
        _ = work.track(temporary)
        return Outcome(file: temporary, bytes: bytes, strategy: "7-Zip Deflate (max)")
    }

    /// Native ZIP fallback. Runs through the shared process supervisor so
    /// cancellation and timeout work for both ditto and zip.
    private static func withDitto(urls: [URL], source: URL, work: WorkArea,
                                  shouldCancel: @escaping @Sendable () -> Bool) throws -> Outcome {
        let temporary = work.makeTemporary("archive", extension: "zip")
        let arguments: [String]
        let command: Tool
        let workingDirectory: URL?
        if urls.count == 1 {
            command = Tool(name: "ditto", url: URL(fileURLWithPath: "/usr/bin/ditto"))
            arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                         urls[0].path, temporary.path]
            workingDirectory = nil
        } else {
            command = Tool(name: "zip", url: URL(fileURLWithPath: "/usr/bin/zip"))
            arguments = ["-r", "-y", "-X", "-q", temporary.path, "--"] + urls.map(\.lastPathComponent)
            workingDirectory = source.deletingLastPathComponent()
        }
        do {
            try Toolchain.run(command, arguments, timeout: 900,
                              shouldCancel: shouldCancel, workingDirectory: workingDirectory)
        } catch ToolError.cancelled {
            throw CompressionFailure.cancelled
        } catch ToolError.timedOut {
            throw CompressionFailure.invalidInput("The system archiver timed out.")
        } catch {
            throw CompressionFailure.unreadableSource(
                "The system archiver failed: \(error.localizedDescription)")
        }
        let bytes = ImageFacts.byteSize(temporary)
        guard bytes > 0 else { throw CompressionFailure.corruptedSource("The archive came out empty.") }
        return Outcome(file: temporary, bytes: bytes, strategy: "macOS ZIP")
    }
}