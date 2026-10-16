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
    static let changed = Notification.Name("TuckSavedRecipesDidChange")
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
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
