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

// File creation and archiving stay here; size reduction lives in Compression/,
// which owns the encoder search, verification and publishing.
enum FileWork {
    static func newFile(in folder: URL, name: String) throws -> URL {
        guard folder.isFileURL,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name.utf8.count < 200,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw TuckFailure.invalidInput("Choose a valid name and destination folder.")
        }
        // O_EXCL avoids overwriting an existing file, even if another process creates it first.
        for i in 0 ..< 10_000 {
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

    /// Standard ZIP with Deflate. Returns the published archive.
    static func zip(_ paths: [String],
                    progress: @Sendable @escaping (Double) -> Void,
                    shouldCancel: @Sendable @escaping () -> Bool) throws -> (file: URL, strategy: String) {
        guard !paths.isEmpty else {
            throw TuckFailure.invalidInput("Select at least one file or folder.")
        }
        let first = URL(fileURLWithPath: paths[0])
        let outcome = try ZipEngine.archive(paths: paths, beside: first, progress: progress, shouldCancel: shouldCancel)
        progress(1)
        TuckLog.compressionLogger.info("zip.result outputs=1 bytes=\(outcome.bytes) strategy=\(outcome.strategy, privacy: .public)")
        return (outcome.file, outcome.strategy)
    }
}