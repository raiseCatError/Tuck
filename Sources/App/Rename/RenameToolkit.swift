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

public struct RenamePlanItem: Sendable {
    public let originalURL: URL
    public let proposedName: String
    public let proposedURL: URL
    public let hasCollision: Bool
}

public enum AdvancedRenameToolkit {

    public static func preview(urls: [URL], rule: RenameRule) -> [RenamePlanItem] {
        var items: [RenamePlanItem] = []
        var proposedNamesSeen = Set<String>()

        for (index, url) in urls.enumerated() {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension

            var newStem = stem
            var newExt = ext

            switch rule.op {
            case .findReplace(let find, let replace, let isRegex):
                if isRegex {
                    if let regex = try? NSRegularExpression(pattern: find, options: []) {
                        let range = NSRange(location: 0, length: newStem.utf16.count)
                        newStem = regex.stringByReplacingMatches(in: newStem, options: [], range: range, withTemplate: replace)
                    }
                } else {
                    newStem = newStem.replacingOccurrences(of: find, with: replace)
                }

            case .prefixSuffix(let prefix, let suffix):
                newStem = "\(prefix)\(newStem)\(suffix)"

            case .numberedSequence(let prefix, let start, let digits):
                let num = start + index
                let format = "%0\(digits)d"
                let numStr = String(format: format, num)
                newStem = "\(prefix)\(numStr)"

            case .changeExtension(let nextExt):
                newExt = nextExt.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }

            let proposedName = newExt.isEmpty ? newStem : "\(newStem).\(newExt)"
            let proposedURL = url.deletingLastPathComponent().appendingPathComponent(proposedName)

            let fileExistsOnDisk = FileManager.default.fileExists(atPath: proposedURL.path) && proposedURL.path != url.path
            let duplicateInBatch = proposedNamesSeen.contains(proposedURL.path)
            let collision = fileExistsOnDisk || duplicateInBatch

            proposedNamesSeen.insert(proposedURL.path)

            items.append(RenamePlanItem(
                originalURL: url,
                proposedName: proposedName,
                proposedURL: proposedURL,
                hasCollision: collision
            ))
        }

        return items
    }

    /// Performs transactional rename with rollback support if any collision or failure occurs.
    public static func execute(plan: [RenamePlanItem]) throws -> [URL] {
        guard !plan.contains(where: { $0.hasCollision }) else {
            throw TuckFailure.invalidInput("Rename plan contains collisions or duplicate target names.")
        }

        let fm = FileManager.default
        var executedSteps: [(from: URL, to: URL)] = []

        do {
            for item in plan {
                if item.originalURL.path == item.proposedURL.path {
                    continue
                }
                try fm.moveItem(at: item.originalURL, to: item.proposedURL)
                executedSteps.append((from: item.originalURL, to: item.proposedURL))
            }
            return plan.map(\.proposedURL)
        } catch {
            // Rollback all executed moves
            for step in executedSteps.reversed() {
                try? fm.moveItem(at: step.to, to: step.from)
            }
            throw error
        }
    }
}
