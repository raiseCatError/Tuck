import Foundation

/// Saved by the Settings app, read-only from Finder Sync. On a non-sandboxed
/// personal build, a regular bookmark provides persistent path resolution;
/// public sandboxed distributions need scoped-bookmark entitlements reviewed.
struct FavoriteDestination: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let bookmark: Data

    static func create(title: String, url: URL) throws -> FavoriteDestination {
        guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        return FavoriteDestination(id: UUID(), title: title, bookmark: data)
    }

    func resolve() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale,
              (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

enum FavoritePreferences {
    static let key = "favoriteDestinationRecords"
    static var all: [FavoriteDestination] {
        guard let data = TuckPreferences.store.data(forKey: key),
              let value = try? JSONDecoder().decode([FavoriteDestination].self, from: data) else {
            return []
        }
        var seen = Set<UUID>()
        return Array(value.filter {
            !$0.title.isEmpty && $0.title.utf8.count <= 70 && seen.insert($0.id).inserted
        }.prefix(8))
    }

    static func write(_ items: [FavoriteDestination]) throws {
        guard items.count <= 8 else { throw CocoaError(.fileWriteOutOfSpace) }
        let data = try JSONEncoder().encode(items)
        TuckPreferences.store.set(data, forKey: key)
    }
}
