import AppKit
import Dispatch
import Darwin

/// Lightweight, opt-in, top-level folder observer. Nothing is scanned or
/// watched when all rules are disabled or globally paused. Existing files form
/// the baseline at startup; only stable subsequent changes trigger processing.
@MainActor
final class WatchedFolderManager {
    static let shared = WatchedFolderManager()

    struct Stamp: Hashable {
        let device: UInt64
        let inode: UInt64
        let bytes: UInt64
        let modified: Date
    }

    struct Decision {
        let ready: [String]
        let known: [String: Stamp]
        let retry: Bool
    }

    /// Only acknowledge stamps that survived both observations and are old
    /// enough to be complete. Changes still arriving remain pending.
    static func decide(known: [String: Stamp], first: [String: Stamp],
                       second: [String: Stamp], now: Date) -> Decision {
        let observedBefore = Set(known.values)
        var acknowledged = known.filter { second[$0.key] != nil }
        var ready: [String] = []
        for (path, stamp) in first where known[path] != stamp {
            guard let later = second[path], later == stamp, later.bytes > 0,
                  now.timeIntervalSince(later.modified) >= 1 else { continue }
            acknowledged[path] = later
            // A rename of a previously seen file keeps its device/inode,
            // bytes and modification date. Acknowledge its new path without
            // treating the rename as another newly arrived file.
            if !observedBefore.contains(later) { ready.append(path) }
        }
        return Decision(ready: ready.sorted(), known: acknowledged,
                        retry: second.contains { acknowledged[$0.key] != $0.value })
    }
    private struct Watch {
        let generation: UUID
        let rule: WatchedFolderRule
        let folder: URL
        let source: DispatchSourceFileSystemObject
        var known: [String: Stamp]
    }
    private var watches: [UUID: Watch] = [:]
    private var checks: [UUID: UUID] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: WatchRulePreferences.changed,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        })
        observers.append(center.addObserver(forName: RecipePreferences.changed,
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
            watches[rule.id] = Watch(generation: UUID(), rule: rule, folder: folder, source: source,
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
        guard let watch = watches[id], checks[id] != watch.generation else { return }
        let generation = watch.generation
        checks[id] = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await self?.checkChanges(id: id, generation: generation)
        }
    }

    private func checkChanges(id: UUID, generation: UUID) async {
        defer {
            // Do not erase the state for a newer watcher if this task was
            // suspended while an old rule was disabled or reloaded.
            if checks[id] == generation { checks.removeValue(forKey: id) }
        }
        guard let watch = watches[id], watch.generation == generation,
              !WatchRulePreferences.paused else { return }
        guard let first = snapshot(watch.folder) else { return }
        let changed = first.filter { watch.known[$0.key] != $0.value }
        guard !changed.isEmpty else {
            watches[id]?.known = first
            return
        }

        // The second observation must match; an unstable download stays
        // pending instead of being marked processed and forgotten.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let live = watches[id], live.generation == generation,
              !WatchRulePreferences.paused else { return }
        guard let second = snapshot(watch.folder) else { return }
        let recipe = RecipePreferences.all.first { $0.id == watch.rule.recipeID }

        let decision = Self.decide(known: watch.known, first: first,
                                   second: second, now: Date())
        if let recipe {
            for path in decision.ready {
                guard watches[id]?.generation == generation,
                      !WatchRulePreferences.paused else { return }
                let input = path
                JobManager.shared.enqueue(title: "Watched: \(watch.rule.name)",
                    operation: "watchedRecipe", paths: [input], canUndo: true) { token, progress in
                    try RecipeRunner.execute(recipe, paths: [input],
                                             shouldCancel: { token.isCancelled }, progress: progress)
                }
            }
        }
        guard watches[id]?.generation == generation else { return }
        watches[id]?.known = decision.known
        if decision.retry {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.watches[id]?.generation == generation else { return }
                // Defer beyond the current check's cleanup so the next scan
                // obtains the guard and cannot be lost.
                self.scheduleScan(id: id)
            }
        }
    }
}
