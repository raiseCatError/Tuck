import Foundation

struct RecipeStep: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case resizeLongestEdge, convert, stripMetadata }
    var id: UUID = UUID()
    var kind: Kind
    var value: String = ""
    var valid: Bool {
        switch kind {
        case .resizeLongestEdge:
            guard let n = Int(value) else { return false }
            return (16...4096).contains(n)
        case .convert:
            return ["jpeg", "png", "heic", "tiff", "webp"].contains(value)
        case .stripMetadata: return value.isEmpty
        }
    }
    var title: String {
        switch kind {
        case .resizeLongestEdge: "Resize longest edge to \(value)px"
        case .convert: "Convert to \(value.uppercased())"
        case .stripMetadata: "Remove supported metadata"
        }
    }
}

struct SavedRecipe: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var steps: [RecipeStep]
    var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        title.utf8.count <= 70 &&
        (1...8).contains(steps.count) && steps.allSatisfy(\.valid)
    }
}

enum RecipePreferences {
    private static let key = "savedRecipesV1"
    static var all: [SavedRecipe] {
        guard let data = TuckPreferences.store.data(forKey: key),
              let recipes = try? JSONDecoder().decode([SavedRecipe].self, from: data) else {
            return []
        }
        var seen = Set<UUID>()
        return Array(recipes.filter { $0.valid && seen.insert($0.id).inserted }.prefix(12))
    }
    static func save(_ recipes: [SavedRecipe]) throws {
        guard recipes.count <= 12, recipes.allSatisfy(\.valid),
              Set(recipes.map(\.id)).count == recipes.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        TuckPreferences.store.set(try JSONEncoder().encode(recipes), forKey: key)
    }
}

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
