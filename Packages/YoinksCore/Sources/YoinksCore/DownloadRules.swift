import Foundation

// Queue rules that do not depend on URLSession, files or the extractor.
// `DownloadQueue` performs the side effects; these decide what the job state becomes.

extension DownloadPhase {
    /// A source job's extraction task is running and can still be paused or cancelled.
    public var isSourceWorkRunning: Bool {
        switch self {
        case .extracting, .downloading, .processing: true
        case .queued, .waiting, .pausing, .paused, .saving, .cancelling, .completed, .failed, .cancelled: false
        }
    }
}

extension DownloadJob {
    /// The number of jobs that may occupy the queue at once.
    public static let slotLimit = 2

    /// Source jobs resolve a webpage through the extractor; other jobs are direct URLSession transfers.
    public var isSource: Bool { sourceSelection != nil }

    /// Source jobs keep their slot while preparing and saving, because that work runs in-process.
    public var occupiesSlot: Bool {
        phase.occupiesTransferSlot || (isSource && (phase == .processing || phase == .saving))
    }

    /// Returns a paused job to the queue. A new attempt identity is assigned when it starts.
    public mutating func requeue() {
        phase = .queued
        message = nil
        attemptID = nil
    }

    /// Prepares a failed or cancelled job for another attempt, keeping byte progress only when a resume file exists.
    public mutating func resetForRetry() {
        requeue()
        taskIdentifier = nil
        processedSeconds = nil
        expectedSeconds = nil
        if resumeFile == nil {
            receivedBytes = 0
            expectedBytes = nil
        }
    }

    /// Settles a job restored from the journal after the app was closed or relaunched.
    /// The caller performs the returned cleanup.
    public mutating func reconcileAfterRelaunch(_ evidence: RelaunchEvidence) -> RelaunchCleanup {
        if let saved = evidence.savedItem {
            phase = .completed
            storedFile = saved.file
            title = saved.title
            taskIdentifier = nil
            return isSource ? .removeSourceWork : .none
        }
        let wasRunning = phase.isSourceWorkRunning || [.saving, .pausing, .cancelling].contains(phase)
        if isSource, wasRunning, !evidence.hasStagedFile {
            let wasCancelling = phase == .cancelling
            phase = wasCancelling ? .cancelled : .paused
            taskIdentifier = nil
            attemptID = nil
            message = wasCancelling ? nil : "Paused when yoink'd closed. Resume to continue."
            return wasCancelling ? .removeSourceWork : .none
        }
        if phase == .pausing, !evidence.hasLiveTask {
            phase = .paused
            taskIdentifier = nil
            return .none
        }
        let neededWork = phase.occupiesTransferSlot || phase == .processing || phase == .saving
        if neededWork, !evidence.hasLiveTask, !evidence.hasStagedFile {
            phase = .failed
            taskIdentifier = nil
            message = "This download was interrupted. Tap Retry to continue."
        }
        return .none
    }
}

/// What the queue found for a restored job when the app relaunched.
public struct RelaunchEvidence: Sendable {
    /// The library item already committed for this job.
    public struct SavedItem: Sendable {
        public let file: MediaFileName
        public let title: String

        public init(file: MediaFileName, title: String) {
            self.file = file
            self.title = title
        }
    }

    public var savedItem: SavedItem?
    /// Staged media exists for the job's current attempt.
    public var hasStagedFile: Bool
    /// A background URLSession task is still attached to the job.
    public var hasLiveTask: Bool

    public init(savedItem: SavedItem? = nil, hasStagedFile: Bool = false, hasLiveTask: Bool = false) {
        self.savedItem = savedItem
        self.hasStagedFile = hasStagedFile
        self.hasLiveTask = hasLiveTask
    }
}

public enum RelaunchCleanup: Equatable, Sendable {
    case none
    case removeSourceWork
}

extension Collection<DownloadJob> {
    /// The next queued job to start, or nil when every slot is taken.
    /// Only one source job runs at a time, and only when background work is permitted.
    public func nextToStart(sourceRunning: Bool, canStartSource: Bool) -> DownloadJob? {
        guard count(where: \.occupiesSlot) < DownloadJob.slotLimit else { return nil }
        return first { $0.phase == .queued && (!$0.isSource || (!sourceRunning && canStartSource)) }
    }
}
