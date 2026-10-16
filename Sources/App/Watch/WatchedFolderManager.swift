import AppKit
import Dispatch
import Darwin

/// Lightweight, opt-in, top-level folder observer. Nothing is scanned or
/// watched when all rules are disabled or globally paused. Existing files form
/// the baseline at startup; only stable subsequent changes trigger processing.
@MainActor
final class WatchedFolderManager {
    static let shared = WatchedFolderManager()

    private struct Stamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: UInt64
        let modified: Date
    }
    private struct Watch {
        let rule: WatchedFolderRule
        let folder: URL
        let source: DispatchSourceFileSystemObject
        var known: [String: Stamp]
    }
    private var watches: [UUID: Watch] = [:]
    private var checks = Set<UUID>()
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: WatchRulePreferences.changed,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
        }
    }

    func reload() {
        for (_, watch) in watches { watch.source.cancel() }
        watches.removeAll()
        checks.removeAll()
        guard !WatchRulePreferences.paused else { return }
        let recipes = RecipePreferences.all
        for rule in WatchRulePreferences.all where rule.enabled {
            guard recipes.contains(where: { $0.id == rule.recipeID }),
                  let folder = try? rule.resolveFolder(),
                  let baseline = snapshot(folder) else { continue }
            let handle = open(folder.path, O_EVTONLY)
            guard handle >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: handle,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleScan(id: rule.id) }
            }
            source.setCancelHandler { close(handle) }
            watches[rule.id] = Watch(rule: rule, folder: folder, source: source,
                                     known: baseline)
            source.resume()
        }
    }

    private func snapshot(_ folder: URL) -> [String: Stamp]? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                         .isUbiquitousItemKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]), urls.count <= 10_000 else { return nil }
        var result: [String: Stamp] = [:]
        for url in urls where RecipeRunner.allowedImageFormats.contains(url.pathExtension.lowercased()) {
            guard let v = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true, v.isUbiquitousItem != true,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let device = attrs[.systemNumber] as? NSNumber,
                  let inode = attrs[.systemFileNumber] as? NSNumber,
                  let size = attrs[.size] as? NSNumber,
                  let modified = attrs[.modificationDate] as? Date else { continue }
            result[url.path] = Stamp(device: device.uint64Value,
                                     inode: inode.uint64Value,
                                     bytes: size.uint64Value, modified: modified)
        }
        return result
    }

    private func scheduleScan(id: UUID) {
        guard watches[id] != nil, checks.insert(id).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await self?.checkChanges(id: id)
        }
    }

    private func checkChanges(id: UUID) async {
        defer { checks.remove(id) }
        guard let watch = watches[id], !WatchRulePreferences.paused else { return }
        guard let first = snapshot(watch.folder) else { return }
        let new = first.filter { watch.known[$0.key] != $0.value }
        guard !new.isEmpty else {
            watches[id]?.known = first
            return
        }
        // A copied/downloaded image must be stable over a second before any
        // recipe begins. Never process a partial/in-progress download.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let live = watches[id], live.folder == watch.folder else { return }
        guard let second = snapshot(watch.folder) else { return }
        let recipe = RecipePreferences.all.first { $0.id == watch.rule.recipeID }
        if let recipe {
            for (path, stamp) in new where second[path] == stamp &&
                stamp.bytes > 0 && Date().timeIntervalSince(stamp.modified) >= 1 {
                if watches[id]?.known[path] == stamp { continue }
                let input = path
                JobManager.shared.enqueue(title: "Watched: \(watch.rule.name)",
                    operation: "watchedRecipe", paths: [input], canUndo: true) { token, progress in
                    try RecipeRunner.execute(recipe, paths: [input],
                                             shouldCancel: { token.isCancelled }, progress: progress)
                }
            }
        }
        watches[id]?.known = second
        // Files still arriving may not emit another directory event when only
        // bytes change; check one more time after a slow writer is observed.
        if new.contains(where: { second[$0.key] != $0.value }) {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.scheduleScan(id: id)
            }
        }
    }
}
