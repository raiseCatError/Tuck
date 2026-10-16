import Foundation
import CryptoKit

/// Proof that a generated file is still the exact file Tuck originally wrote.
/// Never treat a historical path alone as authorization to remove a file.
public struct OutputIdentity: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: UInt64
    public let sha256: String
    public let device: UInt64
    public let inode: UInt64

    public static func capture(_ url: URL) throws -> OutputIdentity {
        let before = try attributes(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        let after = try attributes(url)
        guard before == after else {
            throw UndoError.unsafe("File changed while Tuck was recording it.")
        }
        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
        return OutputIdentity(path: url.path, bytes: before.bytes, sha256: digest,
                              device: before.device, inode: before.inode)
    }

    public func verifyUnchanged() throws {
        let current = try Self.capture(URL(fileURLWithPath: path))
        guard current == self else {
            throw UndoError.unsafe("Generated file was moved, replaced or modified. Undo refused.")
        }
    }

    private struct Attributes: Equatable {
        let bytes: UInt64
        let device: UInt64
        let inode: UInt64
        let modified: Date?
    }

    private static func attributes(_ url: URL) throws -> Attributes {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw UndoError.unsafe("Undo supports only ordinary files; links and folders are not removed.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else {
            throw UndoError.unsafe("Unable to verify the file identity.")
        }
        return Attributes(bytes: size.uint64Value, device: device.uint64Value,
                          inode: inode.uint64Value, modified: attrs[.modificationDate] as? Date)
    }
}

public enum UndoError: LocalizedError {
    case unsafe(String)

    public var errorDescription: String? {
        switch self { case .unsafe(let reason): reason }
    }
}

/// Operates only on positively identified outputs. There is deliberately no
/// fallback that deletes files from old, unverified history entries.
enum ProtectedUndo {
    static func validatedProofs(for job: JobRecord) throws -> [OutputIdentity] {
        guard job.canUndo, !job.isUndone, job.status == .completed || job.status == .failed else {
            throw UndoError.unsafe("This operation is not eligible for undo.")
        }
        guard let proofs = job.outputProofs, !proofs.isEmpty,
              proofs.count == job.outputs.count,
              Set(proofs.map(\.path)).count == proofs.count,
              Set(proofs.map(\.path)) == Set(job.outputs) else {
            throw UndoError.unsafe("No verified output fingerprints are available for this operation.")
        }
        for proof in proofs { try proof.verifyUnchanged() }
        return proofs
    }

    static func execute(_ job: JobRecord) throws {
        let proofs = try validatedProofs(for: job)
        if job.operation == "advancedRename" {
            try reverseRename(job, proofs: proofs)
        } else {
            let fm = FileManager.default
            // Preflight above ensures no known changes before touching any file.
            // Trash is deliberately used instead of permanent deletion.
            for proof in proofs {
                try proof.verifyUnchanged()
                try fm.trashItem(at: URL(fileURLWithPath: proof.path), resultingItemURL: nil)
            }
        }
    }

    private struct Move {
        let source: URL
        let destination: URL
        let staging: URL
        var staged = false
        var committed = false
    }

    private static func reverseRename(_ job: JobRecord, proofs: [OutputIdentity]) throws {
        let fm = FileManager.default
        var moves: [Move] = []
        let proofPaths = Set(proofs.map(\.path))
        for item in job.items {
            guard let output = item.outputPath, proofPaths.contains(output) else {
                throw UndoError.unsafe("Rename history lacks a complete input/output mapping.")
            }
            if item.inputPath == output { continue }
            let source = URL(fileURLWithPath: output)
            let destination = URL(fileURLWithPath: item.inputPath)
            if fm.fileExists(atPath: destination.path) && !proofPaths.contains(destination.path) {
                throw UndoError.unsafe("The original filename is now occupied. Rename undo refused.")
            }
            let staging = source.deletingLastPathComponent()
                .appendingPathComponent(".tuck-undo-\(UUID().uuidString)")
            moves.append(Move(source: source, destination: destination, staging: staging))
        }
        guard Set(moves.map { $0.destination.path }).count == moves.count else {
            throw UndoError.unsafe("Multiple renamed files target the same original path.")
        }

        do {
            for index in moves.indices {
                try fm.moveItem(at: moves[index].source, to: moves[index].staging)
                moves[index].staged = true
            }
            for index in moves.indices {
                try fm.moveItem(at: moves[index].staging, to: moves[index].destination)
                moves[index].committed = true
            }
        } catch {
            // Roll back in two passes to avoid collisions even when names swap.
            var rollbackErrors: [String] = []
            for move in moves.reversed() where move.committed {
                do { try fm.moveItem(at: move.destination, to: move.staging) }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            for move in moves.reversed() where move.staged {
                if fm.fileExists(atPath: move.staging.path) {
                    do { try fm.moveItem(at: move.staging, to: move.source) }
                    catch { rollbackErrors.append(error.localizedDescription) }
                }
            }
            if !rollbackErrors.isEmpty {
                throw UndoError.unsafe("Rename undo failed and rollback was incomplete. Inspect the affected folder before retrying. \(rollbackErrors.joined(separator: "; "))")
            }
            throw error
        }
    }
}
