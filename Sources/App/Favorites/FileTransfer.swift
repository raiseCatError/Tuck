import Foundation
import CryptoKit

public enum TransferMode: String, Codable, Sendable {
    case copy, move
}
public struct TransferSelection: Sendable {
    public let source: URL
    public let destination: URL
}

/// All paths are explicit; collisions are resolved before publication, and
/// copies are first constructed at an unguessable staging location on the
/// destination volume. No existing destination is ever overwritten.
public enum FileTransfer {
    private static let fm = FileManager.default

    public static func destination(for source: URL, in directory: URL) throws -> URL {
        let parent = directory.standardizedFileURL
        guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw UndoError.unsafe("Destination is not an accessible folder.")
        }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : "-\(index + 1)"
            let name = "\(stem)\(suffix)\(ext.isEmpty ? "" : ".\(ext)")"
            let target = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) { return target }
        }
        throw UndoError.unsafe("Unable to allocate a collision-safe destination filename.")
    }

    public static func transfer(paths: [String], to directory: URL, mode: TransferMode,
                                isCancelled: @escaping @Sendable () -> Bool = { false },
                                progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> JobOutcome {
        guard !paths.isEmpty else { throw UndoError.unsafe("Select at least one file or folder.") }
        let sources = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let destinationDir = directory.standardizedFileURL
        guard Set(sources.map(\.path)).count == sources.count else {
            throw UndoError.unsafe("The selection contains the same source more than once.")
        }
        var outputs: [URL] = []
        var failures: [JobFailure] = []
        for (index, source) in sources.enumerated() {
            if isCancelled() { break }
            progress(Double(index) / Double(sources.count), "Processing \(source.lastPathComponent)…")
            do {
                let output = try moveOrCopy(source, to: destinationDir, mode: mode,
                                            isCancelled: isCancelled)
                outputs.append(output)
            } catch {
                failures.append(JobFailure(inputPath: source.path, reason: error.localizedDescription))
            }
        }
        return JobOutcome(outputs: outputs, failures: failures)
    }

    private static func moveOrCopy(_ source: URL, to folder: URL, mode: TransferMode,
                                   isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        guard !isCancelled() else { throw CancellationError() }
        let src = source.standardizedFileURL
        let dst = folder.standardizedFileURL
        guard let attrs = try? fm.attributesOfItem(atPath: src.path),
              let kind = attrs[.type] as? FileAttributeType,
              kind == .typeRegular || kind == .typeDirectory else {
            throw UndoError.unsafe("Only regular files and directories may be transferred.")
        }
        guard dst.path != src.path, !dst.path.hasPrefix(src.path + "/") else {
            throw UndoError.unsafe("Cannot copy or move a folder into itself.")
        }
        if kind == .typeDirectory {
            // Avoid allowing an attacker-controlled link in a copied hierarchy
            // to turn a later traversal into a path escape.
            try verifyNoSymlinks(src)
        }
        let originalProof = try treeProof(src)
        let proposed = try destination(for: src, in: dst)
        let staging = dst.appendingPathComponent(".tuck-transfer-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        // A same-volume move has a single atomic rename; a cross-volume move
        // must copy, verify, then delete only the unchanged original.
        let srcVol = (attrs[.systemNumber] as? NSNumber)?.uint64Value
        let destAttrs = try fm.attributesOfItem(atPath: dst.path)
        let destVol = (destAttrs[.systemNumber] as? NSNumber)?.uint64Value
        if mode == .move && srcVol != nil && srcVol == destVol {
            guard !isCancelled() else { throw CancellationError() }
            guard try treeProof(src) == originalProof else {
                throw UndoError.unsafe("Source changed before the move. Nothing was moved.")
            }
            try fm.moveItem(at: src, to: proposed)
            return proposed
        }

        try fm.copyItem(at: src, to: staging)
        guard !isCancelled() else { throw CancellationError() }
        guard try treeProof(src) == originalProof,
              try treeProof(staging) == originalProof else {
            throw UndoError.unsafe("File content changed during transfer. Original remains intact.")
        }
        guard !fm.fileExists(atPath: proposed.path) else {
            throw UndoError.unsafe("Destination appeared during transfer. Original remains intact.")
        }
        try fm.moveItem(at: staging, to: proposed)
        if mode == .move {
            // If verification fails, retain the source *and* created copy,
            // and report this as a partial move rather than risking loss.
            guard try treeProof(src) == originalProof else {
                throw UndoError.unsafe("Source changed after copying; destination copy was retained and source was NOT removed.")
            }
            try fm.removeItem(at: src)
        }
        return proposed
    }

    /// Each regular file is fully hashed. Directory manifests include relative
    /// paths, sizes and hashes, so same-size but different-content trees differ.
    private static func treeProof(_ url: URL) throws -> String {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let kind = attrs[.type] as? FileAttributeType
        if kind == .typeRegular {
            return try CopyAsToolkit.sha256(url: url)
        }
        guard kind == .typeDirectory else {
            throw UndoError.unsafe("Unsupported file type in transfer.")
        }
        var lines: [String] = []
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                      options: []) else {
            throw UndoError.unsafe("Cannot verify directory tree.")
        }
        while let item = en.nextObject() as? URL {
            let relative = String(item.path.dropFirst(url.path.count + 1))
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw UndoError.unsafe("Directory contains symlinks; transfer refused.")
            }
            if values.isRegularFile == true {
                lines.append("F:\(relative):\(try CopyAsToolkit.sha256(url: item))")
            } else if values.isDirectory == true {
                lines.append("D:\(relative)")
            } else {
                throw UndoError.unsafe("Unsupported special file in directory.")
            }
        }
        let manifest = Data(lines.sorted().joined(separator: "\n").utf8)
        return SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyNoSymlinks(_ root: URL) throws {
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                     options: []) else {
            throw UndoError.unsafe("Cannot inspect source directory.")
        }
        while let url = en.nextObject() as? URL {
            if (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw UndoError.unsafe("Source tree contains symbolic links; transfer refused.")
            }
        }
    }
}
