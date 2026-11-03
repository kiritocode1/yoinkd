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
    /// Stored jobs left out because they were unreadable, inconsistent or duplicated. Never written.
    public let discardedJobCount: Int

    private enum CodingKeys: String, CodingKey { case version, revision, jobs }

    public init(revision: UInt64, jobs: [DownloadJob]) {
        version = 1
        self.revision = revision
        self.jobs = jobs
        discardedJobCount = 0
    }

    /// Decodes each job independently, so one bad entry costs that entry instead of the whole queue.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        revision = try container.decode(UInt64.self, forKey: .revision)
        let stored = try container.decode([StoredJob].self, forKey: .jobs)
        var seen = Set<UUID>()
        jobs = stored.compactMap(\.job).filter { $0.isRestorable && seen.insert($0.id).inserted }
        discardedJobCount = stored.count - jobs.count
    }
}

/// One journal entry whose decoding failure is kept local to that entry.
private struct StoredJob: Decodable {
    let job: DownloadJob?
    init(from decoder: any Decoder) throws { job = try? DownloadJob(from: decoder) }
}

private extension DownloadJob {
    /// Decoded jobs can still violate invariants that the queue relies on.
    var isRestorable: Bool {
        (try? MediaLink(sourceURL.absoluteString)) != nil
            && progress != nil
            && (phase != .completed || storedFile != nil)
    }
}

/// Writes complete snapshots atomically and refuses a stale concurrent write.
public actor DownloadJournal {
    private let url: URL
    /// The original journal, kept when a load drops jobs that the next save would otherwise erase.
    public nonisolated let discardedURL: URL
    private var latestRevision: UInt64 = 0

    public init(url: URL) {
        self.url = url
        discardedURL = url.appendingPathExtension("discarded")
    }

    /// Throws only when the file itself is unreadable, from an unknown version, or its dropped jobs
    /// could not be backed up. Individual bad jobs are dropped and counted in `discardedJobCount`,
    /// and the original file is copied to `discardedURL` first.
    public func load() throws -> DownloadSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DownloadSnapshot(revision: 0, jobs: [])
        }
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(DownloadSnapshot.self, from: data)
        guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        if snapshot.discardedJobCount > 0 {
            // Throwing here keeps the queue closed, so nothing overwrites the only copy.
            try data.write(to: discardedURL, options: .atomic)
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
