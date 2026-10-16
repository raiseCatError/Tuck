import Foundation
import AppKit
import CryptoKit



public enum CopyAsToolkit {

    /// A relative path is only meaningful when the selection has a common
    /// containing directory. Never use the helper process's working directory.
    private static func relativeRoot(for urls: [URL]) -> [String]? {
        guard let first = urls.first else { return nil }
        var shared = first.standardizedFileURL.deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let parts = url.standardizedFileURL.deletingLastPathComponent().pathComponents
            shared = Array(zip(shared, parts).prefix(while: { $0 == $1 }).map(\.0))
        }
        // "/" isn't a meaningful base when items live on unrelated volumes.
        return shared.count > 1 ? shared : nil
    }

    /// Compute SHA-256 incrementally rather than loading an entire file into RAM.
    static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func format(urls: [URL], format: CopyAsFormat) -> String {
        let relativeRoot = relativeRoot(for: urls)
        return urls.map { url -> String in
            switch format {
            case .absolutePath:
                return url.path
            case .relativePath:
                guard let root = relativeRoot else { return url.path }
                let components = url.standardizedFileURL.pathComponents
                guard components.starts(with: root) else { return url.path }
                return components.dropFirst(root.count).joined(separator: "/")
            case .fileNameWithExt:
                return url.lastPathComponent
            case .fileNameWithoutExt:
                return url.deletingPathExtension().lastPathComponent
            case .fileURL:
                return url.absoluteString
            case .shellQuoted:
                let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
                return "'\(escaped)'"
            case .sha256:
                guard let digest = try? sha256(url: url) else {
                    return "\(url.lastPathComponent): Unable to compute"
                }
                return "\(url.lastPathComponent): \(digest)"
            }
        }.joined(separator: "\n")
    }

    public static func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

public struct RenameRule: Sendable {
    public enum Operation: Sendable {
        case findReplace(find: String, replace: String, isRegex: Bool)
        case prefixSuffix(prefix: String, suffix: String)
        case numberedSequence(prefix: String, start: Int, digits: Int)
        case changeExtension(newExtension: String)
    }

    public let op: Operation
    public init(op: Operation) { self.op = op }
}

/// Lightweight source identity captured when the user previews a rename.
/// Rechecked immediately before execution so a replaced input is not renamed.
public struct RenameSourceIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let bytes: UInt64
    public let modified: Date?

    public static func capture(_ url: URL) throws -> RenameSourceIdentity {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true && values.isSymbolicLink != true else {
            throw TuckFailure.invalidInput("Safe batch rename currently supports regular files, not folders or symbolic links.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber else {
            throw TuckFailure.invalidInput("Cannot verify the original file identity.")
        }
        return RenameSourceIdentity(device: device.uint64Value,
                                    inode: inode.uint64Value,
                                    bytes: size.uint64Value,
                                    modified: attrs[.modificationDate] as? Date)
    }
}

public struct RenamePlanItem: Sendable {
    public let originalURL: URL
    public let proposedName: String
    public let proposedURL: URL
    public let hasCollision: Bool
    public let sourceIdentity: RenameSourceIdentity?
}

public enum AdvancedRenameToolkit {
    private static func key(_ url: URL) -> String {
        // Conservatively reject case-only conflicts on all filesystems.
        url.standardizedFileURL.path.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                             locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains(":") && !name.contains("\u{0}") &&
        name.utf8.count <= 255
    }

    public static func preview(urls: [URL], rule: RenameRule) -> [RenamePlanItem] {
        let originalKeys = Set(urls.map(key))
        var seenDestinations = Set<String>()
        var items: [RenamePlanItem] = []

        for (index, url) in urls.enumerated() {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var newStem = stem
            var newExt = ext

            switch rule.op {
            case .findReplace(let find, let replace, let regex):
                if regex {
                    if let expression = try? NSRegularExpression(pattern: find) {
                        let range = NSRange(location: 0, length: newStem.utf16.count)
                        newStem = expression.stringByReplacingMatches(
                            in: newStem, range: range, withTemplate: replace)
                    }
                } else if !find.isEmpty {
                    newStem = newStem.replacingOccurrences(of: find, with: replace)
                }
            case .prefixSuffix(let prefix, let suffix):
                newStem = "\(prefix)\(newStem)\(suffix)"
            case .numberedSequence(let prefix, let start, let digits):
                let number = start + index
                newStem = "\(prefix)" + String(format: "%0*d", max(1, min(digits, 12)), number)
            case .changeExtension(let value):
                newExt = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }

            let name = newExt.isEmpty ? newStem : "\(newStem).\(newExt)"
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            let destKey = key(destination)
            let originalKey = key(url)
            let fileExistsOutsideSelection = FileManager.default.fileExists(atPath: destination.path) &&
                !originalKeys.contains(destKey)
            let evidence = try? RenameSourceIdentity.capture(url)
            let collision = !validName(name) || evidence == nil ||
                !seenDestinations.insert(destKey).inserted ||
                fileExistsOutsideSelection ||
                (originalKey != destKey && url.standardizedFileURL.deletingLastPathComponent() !=
                    destination.standardizedFileURL.deletingLastPathComponent())
            items.append(RenamePlanItem(originalURL: url, proposedName: name,
                                        proposedURL: destination, hasCollision: collision,
                                        sourceIdentity: evidence))
        }
        return items
    }

    /// Execute as a two-phase same-volume transaction. Moving all originals
    /// to unique hidden staging names first permits swaps and cycles without
    /// deleting existing paths. On failure we roll back both phases.
    public static func execute(plan: [RenamePlanItem]) throws -> [URL] {
        guard !plan.isEmpty,
              !plan.contains(where: { $0.hasCollision }) else {
            throw TuckFailure.invalidInput("Rename plan is empty, invalid, or has conflicting names.")
        }
        let fm = FileManager.default
        let originals = plan.map { key($0.originalURL) }
        let destinations = plan.map { key($0.proposedURL) }
        guard Set(originals).count == originals.count,
              Set(destinations).count == destinations.count else {
            throw TuckFailure.invalidInput("Duplicate source or destination in rename plan.")
        }
        let originalsSet = Set(originals)
        for item in plan {
            guard validName(item.proposedName),
                  item.originalURL.deletingLastPathComponent().standardizedFileURL ==
                    item.proposedURL.deletingLastPathComponent().standardizedFileURL,
                  let expected = item.sourceIdentity,
                  try RenameSourceIdentity.capture(item.originalURL) == expected else {
                throw TuckFailure.invalidInput("An input changed or the proposed filename is invalid. Reopen the preview.")
            }
            if fm.fileExists(atPath: item.proposedURL.path) && !originalsSet.contains(key(item.proposedURL)) {
                throw TuckFailure.invalidInput("A destination filename is already occupied.")
            }
        }

        struct Move {
            let source: URL
            let staging: URL
            let destination: URL
            var staged = false
            var committed = false
        }

        var moves: [Move] = plan.filter { $0.originalURL.path != $0.proposedURL.path }.map {
            Move(source: $0.originalURL,
                 staging: $0.originalURL.deletingLastPathComponent()
                    .appendingPathComponent(".tuck-rename-\(UUID().uuidString)"),
                 destination: $0.proposedURL)
        }

        do {
            for i in moves.indices {
                try fm.moveItem(at: moves[i].source, to: moves[i].staging)
                moves[i].staged = true
            }
            for i in moves.indices {
                try fm.moveItem(at: moves[i].staging, to: moves[i].destination)
                moves[i].committed = true
            }
            return plan.map(\.proposedURL)
        } catch {
            var problems: [String] = []
            for move in moves.reversed() where move.committed {
                do { try fm.moveItem(at: move.destination, to: move.staging) }
                catch { problems.append("Cannot restage \(move.destination.lastPathComponent): \(error.localizedDescription)") }
            }
            for move in moves.reversed() where move.staged {
                guard fm.fileExists(atPath: move.staging.path) else { continue }
                do { try fm.moveItem(at: move.staging, to: move.source) }
                catch { problems.append("Cannot restore \(move.source.lastPathComponent): \(error.localizedDescription)") }
            }
            if !problems.isEmpty {
                throw TuckFailure.commandFailed(
                    "Rename failed and rollback needs manual attention: " + problems.joined(separator: "; "))
            }
            throw error
        }
    }
}
