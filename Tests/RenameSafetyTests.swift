import Foundation

@main
struct RenameSafetyTests {
    static func main() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuck-rename-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let alpha = dir.appendingPathComponent("alpha.txt")
        let beta = dir.appendingPathComponent("beta.txt")
        let gamma = dir.appendingPathComponent("gamma.txt")
        try Data("alpha".utf8).write(to: alpha)
        try Data("beta".utf8).write(to: beta)
        try Data("gamma".utf8).write(to: gamma)

        let relative = CopyAsToolkit.format(urls: [alpha, beta], format: .relativePath)
        assert(relative == "alpha.txt\nbeta.txt")
        let digest = try CopyAsToolkit.sha256(url: alpha)
        assert(digest == "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccd8e3568eec7d5fd03f")
        let filename = CopyAsToolkit.format(urls: [alpha], format: .relativePath)
        assert(filename == "alpha.txt")

        // A two-file swap is not possible with sequential direct moves.
        // Staging each input first must allow it and preserve the contents.
        let swap = [
            RenamePlanItem(originalURL: alpha, proposedName: "beta.txt",
                           proposedURL: beta, hasCollision: false,
                           sourceIdentity: try RenameSourceIdentity.capture(alpha)),
            RenamePlanItem(originalURL: beta, proposedName: "alpha.txt",
                           proposedURL: alpha, hasCollision: false,
                           sourceIdentity: try RenameSourceIdentity.capture(beta))
        ]
        let output = try AdvancedRenameToolkit.execute(plan: swap)
        assert(output.count == 2)
        let aAfter = try String(contentsOf: alpha, encoding: .utf8)
        let bAfter = try String(contentsOf: beta, encoding: .utf8)
        assert(aAfter == "beta" && bAfter == "alpha")

        // Already-occupied external destination must be refused without
        // moving or modifying either original.
        let rule = RenameRule(op: .findReplace(find: "alpha", replace: "gamma", isRegex: false))
        let collision = AdvancedRenameToolkit.preview(urls: [alpha], rule: rule)
        assert(collision.count == 1 && collision[0].hasCollision)
        let before = try Data(contentsOf: gamma)
        assert(rejects { try AdvancedRenameToolkit.execute(plan: collision) })
        let unchanged = try Data(contentsOf: gamma)
        assert(before == unchanged)

        // Replacing a selected file between preview and execution must fail.
        let renamed = AdvancedRenameToolkit.preview(
            urls: [beta], rule: .init(op: .prefixSuffix(prefix: "old-", suffix: "")))
        try fm.removeItem(at: beta)
        try Data("replacement".utf8).write(to: beta)
        assert(rejects { try AdvancedRenameToolkit.execute(plan: renamed) })
        let replacement = try String(contentsOf: beta, encoding: .utf8)
        assert(replacement == "replacement")

        // Unsafe filenames and unsupported directory renames are rejected.
        let invalid = AdvancedRenameToolkit.preview(
            urls: [alpha], rule: .init(op: .prefixSuffix(prefix: "../", suffix: "")))
        assert(invalid.first?.hasCollision == true)
        let folders = AdvancedRenameToolkit.preview(
            urls: [dir], rule: .init(op: .prefixSuffix(prefix: "renamed-", suffix: "")))
        assert(folders.first?.hasCollision == true)

        print("RenameSafetyTests passed")
    }

    static func rejects(_ op: () throws -> Void) -> Bool {
        do { try op(); return false }
        catch { return true }
    }
}
