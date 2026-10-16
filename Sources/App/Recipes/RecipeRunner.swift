import Foundation

enum RecipeRunner {
    static let allowedImageFormats: Set<String> = ["jpg","jpeg","png","heic","tif","tiff","webp","bmp"]

    static func execute(_ recipe: SavedRecipe, paths: [String],
                        shouldCancel: @escaping @Sendable () -> Bool,
                        progress: @escaping @Sendable (Double,String) -> Void) throws -> JobOutcome {
        guard recipe.valid, !paths.isEmpty, paths.count <= 256 else {
            throw UndoError.unsafe("The saved recipe or input selection is invalid.")
        }
        var outputs: [URL] = []
        var failures: [JobFailure] = []
        for (index, path) in paths.enumerated() {
            if shouldCancel() { break }
            let source = URL(fileURLWithPath: path)
            progress(Double(index) / Double(paths.count), source.lastPathComponent)
            do {
                guard allowedImageFormats.contains(source.pathExtension.lowercased()),
                      (try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
                      (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw UndoError.unsafe("This recipe accepts regular image files only.")
                }
                outputs.append(try process(recipe, source: source, shouldCancel: shouldCancel))
            } catch {
                if !shouldCancel() {
                    failures.append(JobFailure(inputPath: path, reason: error.localizedDescription))
                }
            }
        }
        return JobOutcome(outputs: outputs, failures: failures)
    }

    private static func process(_ recipe: SavedRecipe, source: URL,
                                shouldCancel: @escaping @Sendable () -> Bool) throws -> URL {
        let fm = FileManager.default
        guard Spill.root().path.hasPrefix("/Volumes/") else {
            throw UndoError.unsafe("Connect a writable external scratch volume before running a recipe.")
        }
        let work = try WorkArea(beside: source)
        defer { work.clean() }
        // Recipes can create many encoded intermediates; require a mounted
        // external scratch volume instead of falling back to internal storage.
        guard work.root.path.hasPrefix("/Volumes/"),
              fm.fileExists(atPath: work.root.path) else {
            throw UndoError.unsafe("A mounted external scratch volume is required for recipes.")
        }
        let fileBytes = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 1_000_000
        try work.requireSpace(bytes: min(fileBytes, 1_000_000_000))
        var current = work.makeTemporary("recipe-source-\(UUID().uuidString)",
                                         extension: source.pathExtension)
        try fm.copyItem(at: source, to: current)
        for step in recipe.steps {
            if shouldCancel() { throw CancellationError() }
            let next: URL
            switch step.kind {
            case .resizeLongestEdge:
                guard let edge = Int(step.value) else {
                    throw UndoError.unsafe("Invalid resize step.")
                }
                next = try ImageToolkit.resize(url: current, mode: .longestEdge(edge),
                    shouldCancel: shouldCancel)
            case .convert:
                next = try ImageToolkit.convert(url: current, targetFormat: step.value,
                    shouldCancel: shouldCancel)
            case .stripMetadata:
                next = try MetadataToolkit.strip(url: current)
            }
            guard fm.fileExists(atPath: next.path) else {
                throw UndoError.unsafe("Recipe step did not create its expected output.")
            }
            current = work.track(next)
        }
        if shouldCancel() { throw CancellationError() }
        let export = source.deletingLastPathComponent().appendingPathComponent("export", isDirectory: true)
        try fm.createDirectory(at: export, withIntermediateDirectories: true)
        let outputOrigin = export.appendingPathComponent(source.lastPathComponent)
        return try OutputName.publish(current, beside: outputOrigin, suffix: "-export",
                                      extraExtension: current.pathExtension)
    }
}
