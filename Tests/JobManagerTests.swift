import Foundation
import AppKit

private final class WorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maximum = 0
    private(set) var started: [Int] = []

    func enter(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        running += 1
        maximum = max(maximum, running)
        started.append(index)
    }

    func leave() {
        lock.lock(); running -= 1; lock.unlock()
    }

    func result() -> (Int, [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (maximum, started)
    }
}

@main
struct JobManagerTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuck-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let manager = JobManager(historyFileOverride: dir.appendingPathComponent("history.json"))
        let probe = WorkProbe()

        manager.setQueuePaused(true)
        var ids: [UUID] = []
        for index in 0..<3 {
            let id = manager.enqueue(title: "Test \(index)", operation: "test", paths: ["/tmp/test"],
                                     canUndo: false) { token, progress in
                probe.enter(index)
                defer { probe.leave() }
                progress(0.5, "Working")
                try await Task.sleep(nanoseconds: 100_000_000)
                if token.isCancelled { throw CancellationError() }
                return JobOutcome()
            }
            ids.append(id)
        }
        assert(manager.jobs.filter { $0.status == .queued }.count == 3)
        manager.cancel(jobId: ids[1])
        assert(manager.jobs.first(where: { $0.id == ids[1] })?.status == .cancelled)
        manager.setQueuePaused(false)

        for _ in 0..<100 {
            if manager.jobs.first(where: { $0.id == ids[0] })?.status == .completed
                && manager.jobs.first(where: { $0.id == ids[2] })?.status == .completed { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        assert(probe.result().0 == 1, "Workers must never overlap")
        assert(probe.result().1 == [0, 2], "Queued jobs must start FIFO; cancelled jobs don't execute")
        assert(manager.jobs.first(where: { $0.id == ids[0] })?.status == .completed)
        assert(manager.jobs.first(where: { $0.id == ids[2] })?.status == .completed)

        // An active worker that publishes an output just before noticing
        // cancellation must retain that output and a usable undo proof.
        let partial = dir.appendingPathComponent("partial.png")
        try Data("partial result".utf8).write(to: partial)
        let partialId = manager.enqueue(title: "Partial", operation: "imageConvert",
                                        paths: ["/tmp/input"], canUndo: true) { token, progress in
            try await Task.sleep(nanoseconds: 60_000_000)
            return JobOutcome(outputs: [partial])
        }
        manager.cancel(jobId: partialId)
        for _ in 0..<100 {
            if let entry = manager.jobs.first(where: { $0.id == partialId }),
               entry.status == .cancelled && entry.outputProofs != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard let cancelled = manager.jobs.first(where: { $0.id == partialId }) else {
            fatalError("Cancelled job missing from history")
        }
        assert(cancelled.status == .cancelled)
        assert(cancelled.outputs == [partial.path])
        assert(cancelled.canUndo && cancelled.outputProofs?.count == 1)

        // A batch may succeed for one input and fail for another. Do not
        // label it fully completed, and preserve the successful generated copy.
        let succeeded = dir.appendingPathComponent("succeeded.jpg")
        try Data("generated output".utf8).write(to: succeeded)
        let good = dir.appendingPathComponent("good.jpg").path
        let bad = dir.appendingPathComponent("bad.jpg").path
        let mixedId = manager.enqueue(title: "Mixed", operation: "imageConvert",
                                      paths: [good, bad], canUndo: true) { _, _ in
            JobOutcome(outputs: [succeeded],
                       failures: [JobFailure(inputPath: bad, reason: "Unsupported test format")])
        }
        for _ in 0..<100 {
            if let record = manager.jobs.first(where: { $0.id == mixedId }),
               record.status == .partial && record.outputProofs != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard let mixed = manager.jobs.first(where: { $0.id == mixedId }) else {
            fatalError("Mixed batch missing from history")
        }
        assert(mixed.status == .partial)
        assert(mixed.outputs == [succeeded.path])
        assert(mixed.failures?.first?.inputPath == bad)
        assert(mixed.items.first(where: { $0.inputPath == bad })?.status == .failed)
        assert(mixed.canUndo && mixed.outputProofs?.count == 1)
        let encoded = try JSONEncoder().encode(mixed)
        let decoded = try JSONDecoder().decode(JobRecord.self, from: encoded)
        assert(decoded.status == .partial && decoded.failures?.count == 1)

        // Restarting Tuck must not show orphaned 'Running' forever.
        let interrupted = JobRecord(title: "Interrupted", operation: "test",
                                    status: .running, canUndo: false)
        try JSONEncoder().encode([interrupted]).write(
            to: dir.appendingPathComponent("restart.json"), options: .atomic)
        let restarted = JobManager(historyFileOverride: dir.appendingPathComponent("restart.json"))
        assert(restarted.jobs.first?.status == .failed)
        print("JobManagerTests passed")
    }
}
