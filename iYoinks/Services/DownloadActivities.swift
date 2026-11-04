import ActivityKit
import Combine
import Foundation
import YoinksCore

/// Keeps one Live Activity per unfinished download, mirroring the queue: started when a job begins,
/// updated as its phase and progress change, ended when it finishes. Updates are throttled to
/// phase changes and 2% steps so a fast download doesn't flood ActivityKit.
@MainActor
final class DownloadActivities {
    private var activities: [UUID: Activity<DownloadActivityAttributes>] = [:]
    private var lastStates: [UUID: DownloadActivityAttributes.ContentState] = [:]
    private var subscription: AnyCancellable?

    func start(observing queue: DownloadQueue) {
        DownloadActivityActions.toggle = { [weak queue] id in
            guard let queue, let job = queue.jobs.first(where: { $0.id == id }) else { return }
            if job.phase == .paused { try? await queue.resume(id) } else { await queue.pause(id) }
        }
        // Activities left over from a previous launch no longer match a running process.
        for activity in Activity<DownloadActivityAttributes>.activities {
            let handle = ActivityHandle(activity: activity)
            Task { await handle.activity.end(nil, dismissalPolicy: .immediate) }
        }
        subscription = queue.$jobs.sink { [weak self] jobs in self?.sync(jobs) }
    }

    private func sync(_ jobs: [DownloadJob]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let current = Set(jobs.map(\.id))
        for (id, activity) in activities where !current.contains(id) {
            end(id, activity, state: nil)
        }
        for job in jobs {
            let state = Self.state(for: job)
            if let activity = activities[job.id] {
                if job.phase.isTerminal {
                    end(job.id, activity, state: job.phase == .completed ? state : nil)
                } else if Self.changed(lastStates[job.id], state) {
                    lastStates[job.id] = state
                    let handle = ActivityHandle(activity: activity)
                    Task { await handle.activity.update(ActivityContent(state: state, staleDate: nil)) }
                }
            } else if !job.phase.isTerminal, job.phase != .queued {
                let attributes = DownloadActivityAttributes(jobID: job.id.uuidString, title: job.title,
                                                            isAudio: job.sourceSelection?.kind == .audio)
                if let activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil)) {
                    activities[job.id] = activity
                    lastStates[job.id] = state
                }
            }
        }
    }

    private func end(_ id: UUID, _ activity: Activity<DownloadActivityAttributes>, state: DownloadActivityAttributes.ContentState?) {
        activities[id] = nil
        lastStates[id] = nil
        let final = state.map { ActivityContent(state: $0, staleDate: nil) }
        let handle = ActivityHandle(activity: activity)
        Task { await handle.activity.end(final, dismissalPolicy: state == nil ? .immediate : .after(.now + 30)) }
    }

    private static func changed(_ old: DownloadActivityAttributes.ContentState?, _ new: DownloadActivityAttributes.ContentState) -> Bool {
        guard let old, old.status == new.status, old.isPaused == new.isPaused else { return true }
        switch (old.fraction, new.fraction) {
        case let (before?, after?): return abs(after - before) >= 0.02
        case (nil, nil): return false
        default: return true
        }
    }

    static func state(for job: DownloadJob) -> DownloadActivityAttributes.ContentState {
        let status: String = switch job.phase {
        case .queued: "Queued"
        case .extracting: "Checking source"
        case .downloading: "Downloading"
        case .waiting: "Waiting for connection"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .processing: "Preparing media"
        case .saving: "Saving to library"
        case .completed: "Saved to library"
        case .failed: "Download failed"
        case .cancelled: "Cancelled"
        case .cancelling: "Cancelling"
        }
        let fraction = job.phase == .processing ? job.processingFraction : job.progress?.fractionCompleted
        let detail: String
        if job.phase == .downloading || job.phase == .paused, let expected = job.expectedBytes {
            detail = "\(MediaPresentation.bytes(job.receivedBytes)) / \(MediaPresentation.bytes(expected))"
        } else {
            detail = ""
        }
        return .init(status: status, fraction: fraction, detail: detail,
                     isPaused: job.phase == .paused || job.phase == .pausing, isFinished: job.phase == .completed)
    }
}

/// ActivityKit's Activity is safe to use from any thread but isn't marked Sendable, so Swift 6
/// refuses to pass it into a Task. This handle carries it across.
private struct ActivityHandle: @unchecked Sendable {
    let activity: Activity<DownloadActivityAttributes>
}
