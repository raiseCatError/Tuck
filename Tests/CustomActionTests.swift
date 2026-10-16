import Foundation

@main
struct CustomActionTests {
    static func main() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(
            "tuck-action-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("semi;quote' file.txt")
        try Data("untouched".utf8).write(to: input)
        let action = CustomFinderAction(
            id: UUID(), title: "Safe test executable", kind: .executable,
            target: "/usr/bin/true", selection: .files,
            requiresConfirmation: true, enabled: true)
        assert(action.valid)
        assert(CustomActionRunner.supports(action, paths: [input.path]))
        try CustomActionRunner.execute(action, paths: [input.path], shouldCancel: { false })
        let content = try String(contentsOf: input, encoding: .utf8)
        assert(content == "untouched")
        var cancelled = false
        do { try CustomActionRunner.execute(action, paths: [input.path], shouldCancel: { true }) }
        catch is CancellationError { cancelled = true }
        assert(cancelled)
        let unsafe = CustomFinderAction(id: UUID(), title: "Bad", kind: .executable,
            target: "echo hello", selection: .any, requiresConfirmation: true, enabled: true)
        assert(!unsafe.valid)
        let folderOnly = CustomFinderAction(id: UUID(), title: "Folder", kind: .executable,
            target: "/usr/bin/true", selection: .folders,
            requiresConfirmation: true, enabled: true)
        assert(!CustomActionRunner.supports(folderOnly, paths: [input.path]))
        print("CustomActionTests passed")
    }
}
