import Foundation

/// User-configured action. Never synthesize a shell command: paths are handed
/// to an executable or Shortcut as argument-array elements.
struct CustomFinderAction: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case executable, shortcut }
    enum Selection: String, Codable, Sendable { case files, folders, any }
    let id: UUID
    var title: String
    var kind: Kind
    var target: String
    var selection: Selection
    var requiresConfirmation: Bool
    var enabled: Bool

    var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        title.utf8.count <= 70 &&
        !target.isEmpty && target.utf8.count <= 2048 &&
        !target.contains("\0") &&
        (kind != .executable || target.hasPrefix("/"))
    }
}

enum CustomActionPreferences {
    private static let key = "customActionDefinitionsV1"
    static var all: [CustomFinderAction] {
        guard let data = TuckPreferences.store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CustomFinderAction].self, from: data) else {
            return []
        }
        var seen = Set<UUID>()
        return Array(decoded.filter { $0.valid && seen.insert($0.id).inserted }.prefix(16))
    }

    static func save(_ actions: [CustomFinderAction]) throws {
        guard actions.count <= 16, actions.allSatisfy(\.valid),
              Set(actions.map(\.id)).count == actions.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        TuckPreferences.store.set(try JSONEncoder().encode(actions), forKey: key)
    }
}
