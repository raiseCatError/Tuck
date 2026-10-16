import Foundation

@main
struct FileTransferTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "tuck-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = input.appendingPathComponent("file with spaces.txt")
        try Data("DO NOT MODIFY ORIGINAL".utf8).write(to: original)
        let originalHash = try CopyAsToolkit.sha256(url: original)
        let first = try FileTransfer.transfer(paths: [original.path], to: destination,
                                               mode: .copy)
        assert(first.failures.isEmpty && first.outputs.count == 1)
        assert(fm.fileExists(atPath: original.path))
        assert(try CopyAsToolkit.sha256(url: first.outputs[0]) == originalHash)
        let second = try FileTransfer.transfer(paths: [original.path], to: destination, mode: .copy)
        assert(second.outputs.count == 1 && first.outputs[0] != second.outputs[0])
        assert(try CopyAsToolkit.sha256(url: original) == originalHash)

        let folder = input.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("contents.txt")
        try Data("folder content".utf8).write(to: child)
        let recursive = try FileTransfer.transfer(paths: [folder.path],
            to: folder.appendingPathComponent("inner", isDirectory: true), mode: .copy)
        assert(recursive.outputs.isEmpty && recursive.failures.count == 1)
        assert(fm.fileExists(atPath: child.path))
        let moved = try FileTransfer.transfer(paths: [child.path], to: destination, mode: .move)
        assert(moved.failures.isEmpty && moved.outputs.count == 1)
        assert(!fm.fileExists(atPath: child.path))
        assert(String(data: try Data(contentsOf: moved.outputs[0]), encoding: .utf8) == "folder content")
        print("FileTransferTests passed")
    }
}
