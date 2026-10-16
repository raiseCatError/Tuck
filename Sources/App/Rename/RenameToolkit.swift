import Foundation
import AppKit
import CryptoKit



public enum CopyAsToolkit {

    public static func format(urls: [URL], format: CopyAsFormat) -> String {
        let results = urls.map { url -> String in
            switch format {
            case .absolutePath:
                return url.path
            case .relativePath:
                let current = FileManager.default.currentDirectoryPath
                if url.path.hasPrefix(current) {
                    let rel = String(url.path.dropFirst(current.count))
                    return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
                }
                return url.lastPathComponent
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
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    let digest = SHA256.hash(data: data)
                    return "\(url.lastPathComponent): " + digest.compactMap { String(format: "%02x", $0) }.joined()
                }
                return "\(url.lastPathComponent): Unable to compute"
            }
        }
        return results.joined(separator: "\n")
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
