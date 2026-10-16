import Foundation

// Scratch space. Encoders can need several times the size of the source, and the
// built-in disk is often the smallest volume on the machine, so intermediate
// files spill onto the first mounted volume that has room. Publishing always
// happens on the source's own volume through a staged copy, so the final rename
// stays atomic no matter where the scratch lived.

enum Spill {
    /// Free space we want before trusting a volume for scratch.
    static let preferredFreeBytes: Int64 = 2_000_000_000

    private static let resolved: URL? = {
        let fm = FileManager.default
        let volumes = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes", isDirectory: true),
                                                   includingPropertiesForKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityForImportantUsageKey])) ?? []
        for volume in volumes.sorted(by: { $0.path < $1.path }) {
            let values = try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityForImportantUsageKey])
            if values?.volumeIsReadOnly == true { continue }
            if let free = values?.volumeAvailableCapacityForImportantUsage, free < preferredFreeBytes { continue }
            let root = volume.appendingPathComponent("Tuck Work", isDirectory: true)
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                return root
            } catch { continue }
        }
        return nil
    }()

    /// Where scratch goes: a mounted volume with space, else the system temp dir.
    static func root() -> URL {
        if let resolved { return resolved }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func freeBytes(at url: URL) -> Int64 {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }

    static func describe() -> String {
        root().path
    }
}

final class WorkArea {
    let root: URL
    private var created: [URL] = []
    private let lock = NSLock()

    init(beside source: URL) throws {
        let spill = Spill.root().appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: spill, withIntermediateDirectories: true)
            root = spill
        } catch {
            let fallback = source.deletingLastPathComponent()
                .appendingPathComponent(".tuck-work-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            root = fallback
        }
    }

    /// Refuses to start when the scratch volume cannot hold the intermediates,
    /// instead of filling a nearly full disk.
    func requireSpace(bytes: Int) throws {
        let needed = Int64(max(bytes, 1)) * 2
        guard Spill.freeBytes(at: root) > needed else {
            throw CompressionFailure.permissionDenied("Not enough free space in \(root.deletingLastPathComponent().path) for temporary files.")
        }
    }

    func makeTemporary(_ name: String, extension ext: String) -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension(ext)
        _ = track(url)
        return url
    }

    func track(_ url: URL) -> URL {
        lock.lock()
        created.append(url)
        lock.unlock()
        return url
    }

    func discard(_ url: URL) {
        lock.lock()
        created.removeAll { $0 == url }
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    func clean() {
        lock.lock()
        let files = created
        created.removeAll()
        lock.unlock()
        for url in files { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: root)
    }

    deinit { clean() }
}

/// Collision safe output naming: `photo.jpg` becomes `photo-compressed.jpg`,
/// then `photo-compressed-2.jpg`. An existing file is never reused.
enum OutputName {
    static func destination(for source: URL, suffix: String = "-compressed", extraExtension: String? = nil) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = extraExtension ?? source.pathExtension
        let base = "\(stem)\(suffix)"
        let fm = FileManager.default
        for index in 1 ..< 10_000 {
            let name = index == 1 ? "\(base).\(ext)" : "\(base)-\(index).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    /// Stages the verified file beside the source and renames it into place, so
    /// a reader never sees a half written output and nothing is ever replaced.
    @discardableResult
    static func publish(_ temporary: URL, beside source: URL, suffix: String = "-compressed", extraExtension: String? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = source.deletingLastPathComponent()
        let ext = extraExtension ?? source.pathExtension
        let staged = folder.appendingPathComponent(".tuck-publish-\(UUID().uuidString).\(ext)")
        do {
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: temporary, to: staged)
            let destination = self.destination(for: source, suffix: suffix, extraExtension: extraExtension)
            do {
                try fm.moveItem(at: staged, to: destination)
                return destination
            } catch {
                // Name was taken between search and publish: retry once.
                let fallback = folder.appendingPathComponent(
                    "\(source.deletingPathExtension().lastPathComponent)\(suffix)-\(UUID().uuidString.prefix(6)).\(ext)")
                try fm.moveItem(at: staged, to: fallback)
                return fallback
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }
}