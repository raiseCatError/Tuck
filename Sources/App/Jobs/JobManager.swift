import Foundation
import AppKit

@MainActor
final class JobManager: ObservableObject {
    static let shared = JobManager()

    @Published private(set) var jobs: [JobRecord] = []
    private var cancelTokens: [UUID: CancellationFlag] = [:]
    private var workQueue: [UUID] = []
    private var activeJobId: UUID?
    private let historyFileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tuck", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.historyFileURL = appSupport.appendingPathComponent("history.json")
        loadHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let saved = try? JSONDecoder().decode([JobRecord].self, from: data) else {
            return
        }
        self.jobs = saved
    }

    private func persistHistory() {
        // Keep most recent 100 jobs for memory and privacy efficiency
        let slice = Array(jobs.prefix(100))
        if let data = try? JSONEncoder().encode(slice) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }

    func recordCompletedJob(_ record: JobRecord) {
        jobs.insert(record, at: 0)
        persistHistory()
    }

    func enqueue(title: String,
                 operation: String,
                 paths: [String],
                 canUndo: Bool = false,
                 executor: @escaping @Sendable (CancellationFlag, @escaping @Sendable (Double, String) -> Void) async throws -> [URL]) {
        let items = paths.map { JobItemStatus(inputPath: $0) }
        let record = JobRecord(title: title, operation: operation, items: items, canUndo: canUndo)
        jobs.insert(record, at: 0)
        persistHistory()

        let token = CancellationFlag()
        cancelTokens[record.id] = token
        workQueue.append(record.id)

        processNext(executor: executor, jobId: record.id, token: token)
    }

    private func processNext(executor: @escaping @Sendable (CancellationFlag, @escaping @Sendable (Double, String) -> Void) async throws -> [URL],
                             jobId: UUID,
                             token: CancellationFlag) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].status = .running
        jobs[index].startedAt = Date()
        jobs[index].progressDetail = "Starting…"

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let outputs = try await executor(token, { fraction, detail in
                    Task { @MainActor in
                        self?.updateProgress(jobId: jobId, fraction: fraction, detail: detail)
                    }
                })

                await MainActor.run {
                    self?.finishJob(jobId: jobId, outputs: outputs, error: nil)
                }
            } catch {
                await MainActor.run {
                    let isCancel = (error is CancellationError) || token.isCancelled
                    self?.finishJob(jobId: jobId, outputs: [], error: isCancel ? nil : error.localizedDescription, wasCancelled: isCancel)
                }
            }
        }
    }

    private func updateProgress(jobId: UUID, fraction: Double, detail: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].progress = fraction
        jobs[index].progressDetail = detail
    }

    private func finishJob(jobId: UUID, outputs: [URL], error: String?, wasCancelled: Bool = false) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].finishedAt = Date()
        if wasCancelled {
            jobs[index].status = .cancelled
            jobs[index].progressDetail = "Cancelled"
        } else if let error {
            jobs[index].status = .failed
            jobs[index].progressDetail = error
        } else {
            jobs[index].status = .completed
            jobs[index].progress = 1.0
            jobs[index].progressDetail = "Completed"
            jobs[index].outputs = outputs.map(\.path)
            if !outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        cancelTokens.removeValue(forKey: jobId)
        persistHistory()
    }

    func cancel(jobId: UUID) {
        if let token = cancelTokens[jobId] {
            token.cancel()
        }
        if let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].status == .queued {
            jobs[index].status = .cancelled
            jobs[index].progressDetail = "Cancelled while queued"
            cancelTokens.removeValue(forKey: jobId)
            persistHistory()
        }
    }

    func removeJob(jobId: UUID) {
        cancel(jobId: jobId)
        jobs.removeAll { $0.id == jobId }
        persistHistory()
    }

    func clearCompleted() {
        jobs.removeAll { $0.status == .completed || $0.status == .cancelled }
        persistHistory()
    }

    // MARK: - Safe Undo Execution

    /// Undoes a batch rename or removes generated files after verification.
    func undo(jobId: UUID) throws {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].canUndo, !jobs[index].isUndone else {
            throw TuckFailure.invalidInput("This action cannot be undone.")
        }

        let job = jobs[index]
        let fm = FileManager.default

        if job.operation == "advancedRename" {
            // Reverse renames: outputs -> original inputs
            for item in job.items {
                guard let output = item.outputPath, fm.fileExists(atPath: output) else { continue }
                let original = item.inputPath
                if !fm.fileExists(atPath: original) {
                    try fm.moveItem(atPath: output, toPath: original)
                }
            }
        } else {
            // For generation actions (compression, merge, convert, etc.), remove Tuck-generated outputs safely
            for outPath in job.outputs {
                if fm.fileExists(atPath: outPath) {
                    try fm.removeItem(atPath: outPath)
                }
            }
        }

        jobs[index].isUndone = true
        jobs[index].progressDetail = "Undone"
        persistHistory()
    }
}
