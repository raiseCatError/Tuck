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
        // A path that names a symlink must still produce a private regular
        // snapshot. FileManager.copyItem can preserve the symlink and let
        // unzip reread its mutable target instead.
        let linkedArchive = tmp.appendingPathComponent("linked.zip")
        try fm.createSymbolicLink(at: linkedArchive, withDestinationURL: archive)
        let viaLink = try ZipInspector.extract(archive: linkedArchive,
                                              destinationFolder: tmp, selected: ["second.txt"])
        let linkedData = try String(contentsOf: viaLink.appendingPathComponent("second.txt"),
                                    encoding: .utf8)
        assert(linkedData == "second")


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
        // A benign central name with a different local-header filename is
        // unsafe: the extractor may interpret local headers during extraction.
        // Reject it even though the central directory alone looks valid.
        let validArchive = [UInt8](try Data(contentsOf: archive))
        guard let firstLocal = (0..<(validArchive.count - 4)).first(where: {
            validArchive[$0] == 0x50 && validArchive[$0 + 1] == 0x4b &&
            validArchive[$0 + 2] == 0x03 && validArchive[$0 + 3] == 0x04
        }) else { fatalError("Fixture has no local ZIP header") }
        let localNameOffset = firstLocal + 30
        var inconsistent = validArchive
        inconsistent[localNameOffset] = inconsistent[localNameOffset] == 0x78 ? 0x79 : 0x78
        let mismatched = tmp.appendingPathComponent("mismatched-local.zip")
        try Data(inconsistent).write(to: mismatched)
        var refusedLocalMismatch = false
        do { _ = try ZipInspector.inspect(mismatched) }
        catch { refusedLocalMismatch = true }
        assert(refusedLocalMismatch, "Local and central ZIP filenames must agree.")

        // Requesting an entry that isn't in the validated snapshot must
        // fail rather than silently extracting a different subset.
        var refusedSelection = false
        do {
            _ = try ZipInspector.extract(archive: archive, destinationFolder: tmp,
                                         selected: ["not-in-this-archive.txt"])
        } catch { refusedSelection = true }
        assert(refusedSelection, "Missing ZIP entries must be refused.")

        // unzip interprets entry selections as argv options or filename globs.
        // Refuse these at inspection instead of broadening a selective extract.
        let original = [UInt8](try Data(contentsOf: archive))
        for byte in [UInt8(45), UInt8(42), UInt8(63), UInt8(91)] {
            var edited = original
            edited[start] = byte
            let candidate = tmp.appendingPathComponent("selector-\(Int(byte)).zip")
            try Data(edited).write(to: candidate)
            var rejected = false
            do { _ = try ZipInspector.inspect(candidate) }
            catch { rejected = true }
            assert(rejected, "Option-like or wildcard ZIP entry names must be rejected.")
        }
        print("ZipInspectorTests passed")
    }
}
