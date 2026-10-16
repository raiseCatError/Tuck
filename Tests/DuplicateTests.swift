import Foundation

@main
struct DuplicateTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "tuck-duplicate-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("one.txt")
        let second = root.appendingPathComponent("two.txt")
        let different = root.appendingPathComponent("different.txt")
        try Data("12345".utf8).write(to: first)
        try Data("12345".utf8).write(to: second)
        try Data("54321".utf8).write(to: different)
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: first)
        let groups = try DuplicateScanner.scan([root], isCancelled: { false }, progress: { _ in })
        assert(groups.count == 1)
        assert(groups[0].members.count == 2)
        let expectedNames = Set(["one.txt", "two.txt"])
        assert(Set(groups[0].members.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == expectedNames)
        assert(groups[0].reclaimable == 5)

        // A changed file is no longer authorized by its old scan evidence.
        let proof = groups[0].members.first!
        try Data("new version".utf8).write(to: URL(fileURLWithPath: proof.path))
        var refused = false
        do { try proof.verifyUnchanged() }
        catch { refused = true }
        assert(refused)
        var cancelled = false
        do {
            _ = try DuplicateScanner.scan([root], isCancelled: { true }, progress: { _ in })
        } catch is CancellationError { cancelled = true }
        assert(cancelled)
        print("DuplicateTests passed")
    }
}
