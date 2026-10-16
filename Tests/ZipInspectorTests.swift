import Foundation

@main
struct ZipInspectorTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "tuck-zip-inspect-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("first file.txt")
        let b = tmp.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)
        let archive = tmp.appendingPathComponent("test.zip")
        try Toolchain.run(Tool(name: "zip", url: URL(fileURLWithPath: "/usr/bin/zip")),
                          ["-q", archive.path, a.lastPathComponent, b.lastPathComponent],
                          timeout: 15, workingDirectory: tmp)
        let items = try ZipInspector.inspect(archive)
        assert(items.count == 2 && items.map(\.name).contains("first file.txt"))
        let exported = try ZipInspector.extract(archive: archive, destinationFolder: tmp,
                                               selected: ["second.txt"])
        assert(fm.fileExists(atPath: exported.appendingPathComponent("second.txt").path))
        assert(!fm.fileExists(atPath: exported.appendingPathComponent("first file.txt").path))
        let content = try String(contentsOf: exported.appendingPathComponent("second.txt"),
                                 encoding: .utf8)
        assert(content == "second")
        let exported2 = try ZipInspector.extract(archive: archive, destinationFolder: tmp,
                                                selected: nil)
        assert(exported != exported2 && fm.fileExists(atPath: exported2.appendingPathComponent("first file.txt").path))

        // Change central entry name into a parent-directory traversal. No
        // extraction should begin even if an external tool would normalize it.
        var corrupted = [UInt8](try Data(contentsOf: archive))
        guard let cd = (0..<corrupted.count - 4).first(where: {
            corrupted[$0] == 0x50 && corrupted[$0+1] == 0x4b &&
            corrupted[$0+2] == 0x01 && corrupted[$0+3] == 0x02
        }) else { fatalError("Fixture has no central directory") }
        let start = cd + 46
        let malicious = Array("../a.txt".utf8)
        // Replace only an existing, sufficiently long central name.
        let existingNameLength = Int(corrupted[cd+28]) + 256 * Int(corrupted[cd+29])
        if existingNameLength >= malicious.count {
            corrupted.replaceSubrange(start..<(start + malicious.count), with: malicious)
            let attack = tmp.appendingPathComponent("unsafe.zip")
            try Data(corrupted).write(to: attack)
            var rejected = false
            do { _ = try ZipInspector.inspect(attack) }
            catch { rejected = true }
            assert(rejected, "Traversal must be refused before extraction.")
        }
        print("ZipInspectorTests passed")
    }
}
