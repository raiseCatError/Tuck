import Foundation

struct WatchedFolderRule: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var directoryBookmark: Data
    var recipeID: UUID
    var enabled = true

    static func create(name: String, folder: URL, recipeID: UUID) throws -> WatchedFolderRule {
        guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        return WatchedFolderRule(name: String(name.prefix(70)),
            directoryBookmark: try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                        relativeTo: nil),
            recipeID: recipeID)
    }

    func resolveFolder() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: directoryBookmark, options: [],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL,
              (try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url.standardizedFileURL
    }

    var valid: Bool { !name.isEmpty && name.utf8.count <= 70 && directoryBookmark.count <= 16_384 }
}

enum WatchRulePreferences {
    static let changed = Notification.Name("TuckWatchedFolderRulesDidChange")
    private static let key = "watchedFolderRulesV1"
    private static let pauseKey = "watchedFoldersPaused"

    static var paused: Bool {
        get { TuckPreferences.store.bool(forKey: pauseKey) }
        set {
            TuckPreferences.store.set(newValue, forKey: pauseKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static var all: [WatchedFolderRule] {
        guard let data = TuckPreferences.store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WatchedFolderRule].self, from: data) else {
            return []
        }
        var seen = Set<UUID>()
        return Array(decoded.filter { $0.valid && seen.insert($0.id).inserted }.prefix(8))
    }
    static func save(_ rules: [WatchedFolderRule]) throws {
        guard rules.count <= 8, rules.allSatisfy(\.valid),
              Set(rules.map(\.id)).count == rules.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        TuckPreferences.store.set(try JSONEncoder().encode(rules), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
