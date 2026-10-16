import Foundation

@main
struct WatchedFolderTests {
    @MainActor
    static func main() {
        typealias Gate = WatchedFolderManager
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = "/tmp/incoming/image.png"
        let partial = Gate.Stamp(device: 1, inode: 2, bytes: 100,
                                 modified: now.addingTimeInterval(-0.1))
        let complete = Gate.Stamp(device: 1, inode: 2, bytes: 700,
                                  modified: now.addingTimeInterval(-3))
        let pending = Gate.decide(known: [:], first: [file: partial],
                                  second: [file: complete], now: now)
        assert(pending.ready.isEmpty)
        assert(pending.known[file] == nil, "Unstable files must not be marked as processed.")
        assert(pending.retry)

        let ready = Gate.decide(known: pending.known, first: [file: complete],
                                second: [file: complete], now: now)
        assert(ready.ready == [file])
        assert(ready.known[file] == complete)
        assert(!ready.retry)
        let repeatScan = Gate.decide(known: ready.known, first: [file: complete],
                                     second: [file: complete], now: now)
        assert(repeatScan.ready.isEmpty, "Identical filesystem notifications must not duplicate work.")
        assert(!repeatScan.retry)

        let recentlyModified = Gate.Stamp(device: 1, inode: 3, bytes: 800,
                                          modified: now.addingTimeInterval(-0.2))
        let young = Gate.decide(known: [:], first: [file: recentlyModified],
                                second: [file: recentlyModified], now: now)
        assert(young.ready.isEmpty && young.retry)
        let later = Gate.decide(known: young.known, first: [file: recentlyModified],
                                second: [file: recentlyModified],
                                now: now.addingTimeInterval(2))
        assert(later.ready == [file] && !later.retry)

        let renamed = "/tmp/incoming/renamed.png"
        let renameEvent = Gate.decide(known: ready.known,
                                      first: [renamed: complete],
                                      second: [renamed: complete], now: now)
        assert(renameEvent.ready.isEmpty,
               "Renaming an already observed file must not enqueue another recipe.")
        assert(renameEvent.known[renamed] == complete)
        assert(!renameEvent.retry)

        let vanished = Gate.decide(known: ready.known, first: [:], second: [:], now: now)
        assert(vanished.ready.isEmpty && vanished.known.isEmpty && !vanished.retry)
        print("WatchedFolderTests passed")
    }
}
