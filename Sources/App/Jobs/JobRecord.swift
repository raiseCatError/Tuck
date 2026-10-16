import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct JobItemStatus: Identifiable, Codable, Sendable {
    public let id: UUID
    public let inputPath: String
    public var outputPath: String?
    public var status: JobStatus
    public var errorMessage: String?

    public init(id: UUID = UUID(), inputPath: String, outputPath: String? = nil, status: JobStatus = .queued, errorMessage: String? = nil) {
        self.id = id
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct JobRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let operation: String
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var status: JobStatus
    public var progress: Double
    public var progressDetail: String
    public var items: [JobItemStatus]
    public var outputs: [String]
    public var canUndo: Bool
    public var isUndone: Bool
    /// Present only after the generated outputs have been fingerprinted.
    /// Older history entries lack this field and must never be deleted by Undo.
    public var outputProofs: [OutputIdentity]?

    public init(id: UUID = UUID(),
                title: String,
                operation: String,
                createdAt: Date = Date(),
                startedAt: Date? = nil,
                finishedAt: Date? = nil,
                status: JobStatus = .queued,
                progress: Double = 0.0,
                progressDetail: String = "Queued",
                items: [JobItemStatus] = [],
                outputs: [String] = [],
                canUndo: Bool = false,
                isUndone: Bool = false,
                outputProofs: [OutputIdentity]? = nil) {
        self.id = id
        self.title = title
        self.operation = operation
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.progress = progress
        self.progressDetail = progressDetail
        self.items = items
        self.outputs = outputs
        self.canUndo = canUndo
        self.isUndone = isUndone
        self.outputProofs = outputProofs
    }
}
