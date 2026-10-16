import Foundation
import AppKit

@MainActor
final class JobManager: ObservableObject {
    typealias Reporter = @Sendable (Double, String) -> Void
    typealias Executor = @Sendable (CancellationFlag, @escaping Reporter) async throws -> [URL]
    typealias Completion = @MainActor (JobRecord) -> Void

    static let shared = JobManager()

    @Published private(set) var jobs: [JobRecord] = []
    @Published private(set) var isQueuePaused = false

    // One heavyweight file operation at a time on the target 8 GB Mac.
    // This is deliberately bounded, not one detached task per Finder request.
    private let maximumConcurrentJobs = 1
    private var activeJobIDs = Set<UUID>()
    private var workQueue: [UUID] = []
    private var executors: [UUID: Executor] = [:]
    private var completions: [UUID: Completion] = [:]
    private var cancelTokens: [UUID: CancellationFlag] = [:]
    private var undoRequested = Set<UUID>()
    private var undoInProgress = Set<UUID>()
    private let historyFileURL: URL

    init(historyFileOverride: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tuck", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        historyFileURL = historyFileOverride ?? support.appendingPathComponent("history.json")
        loadHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              var saved = try? JSONDecoder().decode([JobRecord].self, from: data) else { return }
        for index in saved.indices {
            if saved[index].status == .running || saved[index].status == .queued {
                saved[index].status = .failed
                saved[index].progressDetail = "Interrupted when Tuck closed; previous worker is no longer running."
                saved[index].finishedAt = Date()
                saved[index].canUndo = false
            }
            if saved[index].outputProofs == nil {
                saved[index].canUndo = false
            }
        }
        jobs = saved
        persistHistory()
    }

    private func persistHistory() {
        let recent = Array(jobs.prefix(100))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        do {
            try data.write(to: historyFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: historyFileURL.path)
        } catch {
            TuckLog.helperLogger.error("history.persist-failed")
        }
    }

    /// Legacy callers may still finish work outside the queue. Protect any
    /// generated output before enabling Undo; previous history entries cannot
    /// acquire evidence retroactively.
    func recordCompletedJob(_ record: JobRecord) {
        var recorded = record
        let wantsUndo = record.canUndo && !record.outputs.isEmpty
        recorded.canUndo = false
        recorded.outputProofs = nil
        jobs.insert(recorded, at: 0)
        persistHistory()
        if wantsUndo { fingerprintOutputs(jobId: recorded.id, paths: recorded.outputs) }
    }

    @discardableResult
    func enqueue(title: String, operation: String, paths: [String],
                 canUndo: Bool = true,
                 historyItems: [JobItemStatus]? = nil,
                 onComplete: Completion? = nil,
                 executor: @escaping Executor) -> UUID {
        let record = JobRecord(title: title, operation: operation,
                               items: historyItems ?? paths.map { JobItemStatus(inputPath: $0) })
        jobs.insert(record, at: 0)
        executors[record.id] = executor
        if let onComplete { completions[record.id] = onComplete }
        cancelTokens[record.id] = CancellationFlag()
        if canUndo { undoRequested.insert(record.id) }
        workQueue.append(record.id)
        persistHistory()
        drainQueue()
        return record.id
    }

    func setQueuePaused(_ paused: Bool) {
        isQueuePaused = paused
        if !paused { drainQueue() }
    }

    private func drainQueue() {
        guard !isQueuePaused else { return }
        while activeJobIDs.count < maximumConcurrentJobs && !workQueue.isEmpty {
            let jobId = workQueue.removeFirst()
            guard let index = jobs.firstIndex(where: { $0.id == jobId }),
                  jobs[index].status == .queued,
                  let executor = executors[jobId],
                  let token = cancelTokens[jobId] else { continue }
            jobs[index].status = .running
            jobs[index].startedAt = Date()
            jobs[index].progressDetail = "Starting…"
            activeJobIDs.insert(jobId)
            persistHistory()

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let files = try await executor(token, { progress, detail in
                        Task { @MainActor in
                            self?.updateProgress(jobId: jobId, fraction: progress, detail: detail)
                        }
                    })
                    await self?.finishJob(jobId: jobId, outputs: files, error: nil,
                                          wasCancelled: token.isCancelled)
                } catch {
                    let cancelled = token.isCancelled || error is CancellationError
                    await self?.finishJob(jobId: jobId, outputs: [], error: cancelled ? nil : error.localizedDescription,
                                          wasCancelled: cancelled)
                }
            }
        }
    }

    private func updateProgress(jobId: UUID, fraction: Double, detail: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status == .running else { return }
        jobs[index].progress = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        jobs[index].progressDetail = detail
    }

    private func finishJob(jobId: UUID, outputs: [URL], error: String?, wasCancelled: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            activeJobIDs.remove(jobId)
            drainQueue()
            return
        }
        jobs[index].finishedAt = Date()
        jobs[index].outputs = outputs.map(\.path)
        if wasCancelled {
            jobs[index].status = .cancelled
            jobs[index].progressDetail = outputs.isEmpty
                ? "Cancelled" : "Cancelled; some outputs may have been published"
        } else if let error {
            jobs[index].status = .failed
            jobs[index].progressDetail = error
        } else {
            jobs[index].status = .completed
            jobs[index].progress = 1
            jobs[index].progressDetail = "Completed"
        }

        let canProtect = undoRequested.contains(jobId)
            && !outputs.isEmpty && error == nil
        if canProtect { undoRequested.remove(jobId) }
        cancelTokens.removeValue(forKey: jobId)
        activeJobIDs.remove(jobId)
        if jobs[index].status == .completed {
            executors.removeValue(forKey: jobId)
            if !outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        persistHistory()
        if canProtect { fingerprintOutputs(jobId: jobId, paths: outputs.map(\.path)) }
        // Start the next worker before an optional completion alert is shown.
        drainQueue()
        completions.removeValue(forKey: jobId)?(jobs[index])
    }

    private func fingerprintOutputs(jobId: UUID, paths: [String]) {
        Task.detached(priority: .utility) { [weak self] in
            let identities = paths.compactMap { try? OutputIdentity.capture(URL(fileURLWithPath: $0)) }
            await self?.completeFingerprint(jobId: jobId, paths: paths, identities: identities)
        }
    }

    private func completeFingerprint(jobId: UUID, paths: [String], identities: [OutputIdentity]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              !jobs[index].isUndone else { return }
        let complete = identities.count == paths.count && !paths.isEmpty
            && Set(identities.map(\.path)) == Set(paths)
        jobs[index].outputProofs = complete ? identities : nil
        jobs[index].canUndo = complete
        persistHistory()
    }

    func cancel(jobId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        guard jobs[index].status == .queued || jobs[index].status == .running else { return }
        cancelTokens[jobId]?.cancel()
        if jobs[index].status == .queued {
            workQueue.removeAll { $0 == jobId }
            jobs[index].status = .cancelled
            jobs[index].finishedAt = Date()
            jobs[index].progressDetail = "Cancelled before starting"
            executors.removeValue(forKey: jobId)
            completions.removeValue(forKey: jobId)
            cancelTokens.removeValue(forKey: jobId)
            undoRequested.remove(jobId)
            persistHistory()
            drainQueue()
        } else {
            jobs[index].progressDetail = "Cancellation requested…"
        }
    }

    @discardableResult
    func retry(jobId: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].status == .failed || jobs[index].status == .cancelled,
              executors[jobId] != nil, jobs[index].outputs.isEmpty else { return false }
        jobs[index].status = .queued
        jobs[index].progress = 0
        jobs[index].progressDetail = "Queued for retry"
        jobs[index].startedAt = nil
        jobs[index].finishedAt = nil
        jobs[index].canUndo = false
        jobs[index].outputProofs = nil
        cancelTokens[jobId] = CancellationFlag()
        workQueue.append(jobId)
        persistHistory()
        drainQueue()
        return true
    }

    func removeJob(jobId: UUID) {
        guard let job = jobs.first(where: { $0.id == jobId }),
              job.status != .running && job.status != .queued else { return }
        jobs.removeAll { $0.id == jobId }
        executors.removeValue(forKey: jobId)
        cancelTokens.removeValue(forKey: jobId)
        undoRequested.remove(jobId)
        persistHistory()
    }

    func clearCompleted() {
        let removed = Set(jobs.filter { $0.status == .completed || $0.status == .cancelled }
            .map(\.id))
        jobs.removeAll { removed.contains($0.id) }
        for id in removed {
            executors.removeValue(forKey: id)
            cancelTokens.removeValue(forKey: id)
            undoRequested.remove(id)
        }
        persistHistory()
    }

    /// Fails closed for old history and user-modified files. Hash verification
    /// and OS Trash operations are performed away from the main thread.
    func undo(jobId: UUID) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              !undoInProgress.contains(jobId) else {
            throw UndoError.unsafe("This action is unavailable or already being undone.")
        }
        let record = jobs[index]
        undoInProgress.insert(jobId)
        defer { undoInProgress.remove(jobId) }
        do {
            try await Task.detached(priority: .userInitiated) {
                try ProtectedUndo.execute(record)
            }.value
            guard let current = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[current].isUndone = true
            jobs[current].canUndo = false
            jobs[current].progressDetail = record.operation == "advancedRename"
                ? "Original names restored" : "Generated copies moved to Trash"
            persistHistory()
        } catch {
            // A Trash operation can partly succeed before an I/O failure.
            // Keep proofs for remaining files so a later retry is possible.
            if record.operation != "advancedRename",
               let current = jobs.firstIndex(where: { $0.id == jobId }) {
                let remaining = (record.outputProofs ?? []).filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                jobs[current].outputProofs = remaining.isEmpty ? nil : remaining
                jobs[current].outputs = remaining.map(\.path)
                jobs[current].canUndo = !remaining.isEmpty
                jobs[current].progressDetail = "Undo incomplete: \(error.localizedDescription)"
                persistHistory()
            }
            throw error
        }
    }
}
