import Foundation

public enum DownloadPhase: String, Codable, Sendable {
    case queued, extracting, downloading, waiting, pausing, paused, processing, saving, cancelling, completed, failed, cancelled

    public var occupiesTransferSlot: Bool {
        self == .extracting || self == .downloading || self == .waiting || self == .pausing || self == .cancelling
    }

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public struct TransferIdentity: Hashable, Codable, Sendable {
    public let jobID: UUID
    public let attemptID: UUID

    public init(jobID: UUID, attemptID: UUID) {
        self.jobID = jobID
        self.attemptID = attemptID
    }

    public init?(taskDescription: String?) {
        guard let parts = taskDescription?.split(separator: ":"), parts.count == 2,
              let jobID = UUID(uuidString: String(parts[0])),
              let attemptID = UUID(uuidString: String(parts[1])) else { return nil }
        self.init(jobID: jobID, attemptID: attemptID)
    }

    public var taskDescription: String { "\(jobID):\(attemptID)" }
}

public struct DownloadJob: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let createdAt: Date
    public let sourceSelection: SourceSelection?
    public var title: String
    public var phase: DownloadPhase = .queued
    public var attemptID: UUID?
    public var taskIdentifier: Int?
    public var receivedBytes: Int64 = 0
    public var expectedBytes: Int64?
    public var processedSeconds: Double?
    public var expectedSeconds: Double?
    public var message: String?
    public var resumeFile: MediaFileName?
    public var storedFile: MediaFileName?

    public init(link: MediaLink, title: String? = nil, selection: SourceSelection? = nil, id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        sourceURL = link.url
        self.createdAt = createdAt
        sourceSelection = selection
        let proposed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileTitle = link.url.deletingPathExtension().lastPathComponent
        self.title = !proposed.isEmpty ? proposed : (!fileTitle.isEmpty ? fileTitle : "Media from \(link.url.host ?? "link")")
    }

    public var identity: TransferIdentity? {
        attemptID.map { TransferIdentity(jobID: id, attemptID: $0) }
    }

    public var progress: TransferProgress? {
        try? TransferProgress(receivedBytes: receivedBytes, expectedBytes: expectedBytes)
    }

    public var processingFraction: Double? {
        guard let processedSeconds, processedSeconds.isFinite, processedSeconds >= 0,
              let expectedSeconds, expectedSeconds.isFinite, expectedSeconds > 0 else { return nil }
        return min(1, processedSeconds / expectedSeconds)
    }
}

public struct DownloadSnapshot: Codable, Sendable {
    public let version: Int
    public let revision: UInt64
    public let jobs: [DownloadJob]

    public init(revision: UInt64, jobs: [DownloadJob]) {
        version = 1
        self.revision = revision
        self.jobs = jobs
    }
}

/// Writes complete snapshots atomically and refuses a stale concurrent write.
public actor DownloadJournal {
    private let url: URL
    private var latestRevision: UInt64 = 0

    public init(url: URL) { self.url = url }

    public func load() throws -> DownloadSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DownloadSnapshot(revision: 0, jobs: [])
        }
        let snapshot = try JSONDecoder().decode(DownloadSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1,
              Set(snapshot.jobs.map(\.id)).count == snapshot.jobs.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for job in snapshot.jobs {
            _ = try MediaLink(job.sourceURL.absoluteString)
            _ = try TransferProgress(receivedBytes: job.receivedBytes, expectedBytes: job.expectedBytes)
            if job.phase == .completed && job.storedFile == nil {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        latestRevision = snapshot.revision
        return snapshot
    }

    public func save(_ snapshot: DownloadSnapshot) throws {
        guard snapshot.revision >= latestRevision else { return }
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        latestRevision = snapshot.revision
    }
}
