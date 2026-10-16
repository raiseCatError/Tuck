import Foundation

@main
struct SafeUndoTests {
    static func main() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuck-undo-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let generated = dir.appendingPathComponent("generated.pdf")
        try Data("generated".utf8).write(to: generated)
        let proof = try OutputIdentity.capture(generated)
        let generatedJob = JobRecord(title: "Generate", operation: "pdfMerge",
                                     status: .completed, outputs: [generated.path],
                                     canUndo: true, outputProofs: [proof])
        let validated = try ProtectedUndo.validatedProofs(for: generatedJob)
        assert(validated.count == 1)

        // A same-name replacement must never be deleted.
        try fm.removeItem(at: generated)
        try Data("replacement".utf8).write(to: generated)
        assert(rejects { try ProtectedUndo.validatedProofs(for: generatedJob) })
        // A modification of the original file at the same inode must also fail.
        let editedProof = try OutputIdentity.capture(generated)
        let editedJob = JobRecord(title: "Generate", operation: "pdfMerge",
                                  status: .completed, outputs: [generated.path],
                                  canUndo: true, outputProofs: [editedProof])
        try Data("modified again".utf8).write(to: generated)
        assert(rejects { try ProtectedUndo.validatedProofs(for: editedJob) })
        // Older on-disk history with no fingerprint is not authorization.
        let legacy = JobRecord(title: "Old", operation: "zip", status: .completed,
                               outputs: [generated.path], canUndo: true)
        assert(rejects { try ProtectedUndo.validatedProofs(for: legacy) })

        let renamed = dir.appendingPathComponent("renamed.txt")
        let original = dir.appendingPathComponent("original.txt")
        try Data("keep me".utf8).write(to: renamed)
        let renameProof = try OutputIdentity.capture(renamed)
        let renameJob = JobRecord(
            title: "Rename", operation: "advancedRename", status: .completed,
            items: [JobItemStatus(inputPath: original.path, outputPath: renamed.path, status: .completed)],
            outputs: [renamed.path], canUndo: true, outputProofs: [renameProof])
        try ProtectedUndo.execute(renameJob)
        assert(fm.fileExists(atPath: original.path))
        assert(!fm.fileExists(atPath: renamed.path))
        let restored = try String(contentsOf: original, encoding: .utf8)
        assert(restored == "keep me")

        // Someone created a new original name: rollback must refuse to overwrite it.
        try fm.moveItem(at: original, to: renamed)
        try Data("do not touch".utf8).write(to: original)
        let collisionJob = JobRecord(
            title: "Rename", operation: "advancedRename", status: .completed,
            items: [JobItemStatus(inputPath: original.path, outputPath: renamed.path, status: .completed)],
            outputs: [renamed.path], canUndo: true,
            outputProofs: [try OutputIdentity.capture(renamed)])
        assert(rejects { try ProtectedUndo.execute(collisionJob) })
        let untouched = try String(contentsOf: original, encoding: .utf8)
        assert(untouched == "do not touch")
        print("SafeUndoTests passed")
    }

    static func rejects(_ body: () throws -> Any) -> Bool {
        do { _ = try body(); return false }
        catch { return true }
    }
}
