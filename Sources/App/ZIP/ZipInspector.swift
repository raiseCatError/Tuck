import Foundation

public struct ZipEntry: Identifiable, Sendable {
    public let name: String
    public let uncompressed: UInt64
    public let compressed: UInt64
    public let modified: Date?
    public let isDirectory: Bool
    public var id: String { name }
}

/// ZIP central-directory reader; inspects only bounded metadata.
/// Encrypted, ZIP64, symlink, dangerous pathname and oversized payloads are
/// rejected *before* any extraction subprocess touches the destination.
public enum ZipInspector {
    public enum Invalid: LocalizedError {
        case malformed(String)
        public var errorDescription: String? {
            switch self { case .malformed(let text): text }
        }
    }

    private static let maxEntries = 10_000
    private static let maxCentralBytes = 16 * 1024 * 1024
    private static let maxExpandedBytes: UInt64 = 2_000_000_000
    private static let maxEntryBytes: UInt64 = 512_000_000

    private static func uint(_ bytes: [UInt8], _ offset: Int, _ width: Int) -> UInt64? {
        guard offset >= 0, width > 0, offset <= bytes.count - width else { return nil }
        var value: UInt64 = 0
        for index in 0..<width {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    public static func inspect(_ url: URL) throws -> [ZipEntry] {
        guard url.pathExtension.lowercased() == "zip" else {
            throw Invalid.malformed("Only .zip archives are supported.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end >= 22 else { throw Invalid.malformed("Archive is too small for ZIP.") }
        let tailLength = Int(min(end, 65_557))
        try handle.seek(toOffset: end - UInt64(tailLength))
        let tail = [UInt8](try handle.read(upToCount: tailLength) ?? Data())
        guard tail.count == tailLength else { throw Invalid.malformed("Cannot read ZIP footer.") }
        var eocd: Int?
        if tail.count >= 22 {
            for index in stride(from: tail.count - 22, through: 0, by: -1) {
                if uint(tail, index, 4) == 0x06054b50,
                   let comment = uint(tail, index + 20, 2),
                   index + 22 + Int(comment) == tail.count {
                    eocd = index
                    break
                }
            }
        }
        guard let eocd,
              let disk = uint(tail, eocd + 4, 2), disk == 0,
              let centralDisk = uint(tail, eocd + 6, 2), centralDisk == 0,
              let diskEntries = uint(tail, eocd + 8, 2),
              let entries = uint(tail, eocd + 10, 2), entries == diskEntries,
              let length = uint(tail, eocd + 12, 4),
              let start = uint(tail, eocd + 16, 4) else {
            throw Invalid.malformed("Invalid, incomplete, or multi-disk ZIP central directory.")
        }
        guard entries <= UInt64(maxEntries), length <= UInt64(maxCentralBytes),
              start <= end, length <= end - start,
              entries != 0xFFFF, length != 0xFFFF_FFFF, start != 0xFFFF_FFFF else {
            throw Invalid.malformed("ZIP64 or oversized archives are not supported for safe extraction.")
        }
        try handle.seek(toOffset: start)
        let metadata = [UInt8](try handle.read(upToCount: Int(length)) ?? Data())
        guard metadata.count == Int(length) else {
            throw Invalid.malformed("ZIP central directory is truncated.")
        }

        var result: [ZipEntry] = []
        var unique = Set<String>()
        var position = 0
        var expanded: UInt64 = 0
        for _ in 0..<entries {
            guard uint(metadata, position, 4) == 0x02014b50,
                  let flags = uint(metadata, position + 8, 2),
                  let method = uint(metadata, position + 10, 2),
                  let dosTime = uint(metadata, position + 12, 2),
                  let dosDate = uint(metadata, position + 14, 2),
                  let compressed = uint(metadata, position + 20, 4),
                  let uncompressed = uint(metadata, position + 24, 4),
                  let nameLen = uint(metadata, position + 28, 2),
                  let extraLen = uint(metadata, position + 30, 2),
                  let commentLen = uint(metadata, position + 32, 2),
                  let external = uint(metadata, position + 38, 4),
                  let local = uint(metadata, position + 42, 4) else {
                throw Invalid.malformed("Corrupt ZIP entry metadata.")
            }
            let endOfRecord = position + 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
            guard endOfRecord <= metadata.count,
                  position + 46 + Int(nameLen) <= metadata.count,
                  local < end else { throw Invalid.malformed("Invalid ZIP entry bounds.") }
            let rawName = Data(metadata[(position + 46)..<(position + 46 + Int(nameLen))])
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty else {
                throw Invalid.malformed("Archive contains invalid or non-UTF-8 filenames.")
            }
            try validatePath(name)
            guard (flags & 1) == 0 else {
                throw Invalid.malformed("Encrypted ZIP entries require another archive manager.")
            }
            guard (flags & 0x40) == 0, method == 0 || method == 8 else {
                throw Invalid.malformed("Unsupported ZIP compression or encryption method.")
            }
            let mode = (external >> 16) & 0xF000
            guard mode != 0xA000 else {
                throw Invalid.malformed("ZIP contains symbolic links; extraction refused.")
            }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF,
                  uncompressed <= maxEntryBytes,
                  compressed > 0 || uncompressed == 0,
                  compressed == 0 || uncompressed <= compressed * 200,
                  expanded <= maxExpandedBytes - uncompressed else {
                throw Invalid.malformed("Entry size or expansion ratio exceeds the extraction safety limit.")
            }
            expanded += uncompressed
            let comparison = name.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard unique.insert(comparison).inserted else {
                throw Invalid.malformed("Archive contains colliding or duplicated filenames.")
            }
            let modified = DateComponents(calendar: Calendar(identifier: .gregorian),
                year: 1980 + Int((dosDate >> 9) & 0x7F),
                month: Int((dosDate >> 5) & 0x0F),
                day: Int(dosDate & 0x1F),
                hour: Int((dosTime >> 11) & 0x1F),
                minute: Int((dosTime >> 5) & 0x3F),
                second: Int(dosTime & 0x1F) * 2).date
            result.append(ZipEntry(name: name, uncompressed: uncompressed,
                                   compressed: compressed, modified: modified,
                                   isDirectory: name.hasSuffix("/")))
            position = endOfRecord
        }
        guard result.count == entries else { throw Invalid.malformed("Incomplete ZIP directory.") }
        return result
    }

    private static func validatePath(_ name: String) throws {
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"),
              !name.contains("\\"), !name.contains("\0"), !name.contains(":"),
              !name.contains("//"), name.utf8.count <= 1024,
              !name.split(separator: "/").contains(where: {
                  $0 == ".." || $0 == "." || $0.hasPrefix("-")
              }),
              !name.hasPrefix("~") else {
            throw Invalid.malformed("ZIP includes an unsafe path and cannot be extracted.")
        }
    }

    /// Extract only preflight-validated entries into a fresh private staging
    /// directory beside the destination. The destination folder is published
    /// only after validation of the extracted file tree.
    public static func extract(archive: URL, destinationFolder: URL,
                               selected: Set<String>?,
                               shouldCancel: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        guard !shouldCancel() else { throw CancellationError() }
        let fm = FileManager.default
        let properties = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let bytes = (try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.uint64Value ?? UInt64.max
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              bytes <= maxExpandedBytes + UInt64(maxCentralBytes) else {
            throw Invalid.malformed("ZIP input is not a safe regular file or exceeds the size limit.")
        }
        let stage = destinationFolder.appendingPathComponent(
            ".tuck-zip-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        // Validate and extract the SAME private snapshot. Otherwise an archive
        // replaced between inspection and unzip could bypass path checks.
        let snapshot = stage.appendingPathComponent("source.zip")
        try fm.copyItem(at: archive, to: snapshot)
        let listing = try inspect(snapshot)
        let picked = listing.filter { selected == nil || selected!.contains($0.name) }
        guard !picked.isEmpty else { throw Invalid.malformed("No ZIP entries selected.") }
        let expanded = picked.reduce(UInt64(0)) { $0 + $1.uncompressed }
        let free = (try destinationFolder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 0, UInt64(free) > bytes + expanded + 100_000_000 else {
            throw Invalid.malformed("Not enough free space for a safe ZIP extraction.")
        }
        let extracted = stage.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        let tool = Tool(name: "unzip", url: URL(fileURLWithPath: "/usr/bin/unzip"))
        // The ZIP location is absolute. Arguments are passed individually,
        // never interpolated into a shell command.
        let arguments = ["-qq", "-n", snapshot.path] + picked.map(\.name) + ["-d", extracted.path]
        do {
            try Toolchain.run(tool, arguments, timeout: 600, shouldCancel: shouldCancel)
        } catch ToolError.cancelled {
            throw CancellationError()
        }
        if shouldCancel() { throw CancellationError() }
        let allowed = Set(picked.map(\.name))
        var extractedSize: UInt64 = 0
        guard let enumerator = fm.enumerator(at: extracted, includingPropertiesForKeys:
            [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else {
            throw Invalid.malformed("Cannot inspect extracted files.")
        }
        while let file = enumerator.nextObject() as? URL {
            let vals = try file.resourceValues(forKeys:
                [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard vals.isSymbolicLink != true else {
                throw Invalid.malformed("Unexpected symbolic link after ZIP extraction.")
            }
            let rootComponents = extracted.standardizedFileURL.pathComponents
            let fileComponents = file.standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else {
                throw Invalid.malformed("Extraction escaped the staging folder.")
            }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            if vals.isRegularFile == true {
                guard allowed.contains(relative),
                      let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let n = attrs[.size] as? NSNumber else {
                    throw Invalid.malformed("Extractor wrote unexpected or unreadable content.")
                }
                let bytes = n.uint64Value
                guard bytes <= maxEntryBytes, extractedSize <= maxExpandedBytes - bytes else {
                    throw Invalid.malformed("Extracted ZIP content exceeds its declared safety limit.")
                }
                extractedSize += bytes
            } else if vals.isDirectory != true {
                throw Invalid.malformed("Extractor produced unsupported file type.")
            }
        }
        let name = archive.deletingPathExtension().lastPathComponent
        let output = destinationFolder.appendingPathComponent(
            "\(name)-extracted-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.moveItem(at: extracted, to: output)
        return output
    }
}
