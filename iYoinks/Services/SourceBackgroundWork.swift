import BackgroundTasks
import UIKit
import YoinksCore

/// Keeps user-started source work running when iOS permits, and pauses it on expiration.
@MainActor
final class SourceBackgroundWork {
    static let identifierPrefix = "com.maynkudu.iyoinks.source"
    private var registrationAttempted = false
    private var isRegistered = false
    private var entries: [String: Entry] = [:]

    var canStart: Bool { UIApplication.shared.applicationState != .background }

    func register() {
        guard #available(iOS 26.0, *), !registrationAttempted else { return }
        registrationAttempted = true
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifierPrefix + ".*", using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.started(task)
            }
        }
    }

    func begin(_ identity: TransferIdentity, title: String, selection: SourceSelection, onExpiration: @escaping @MainActor () -> Void) {
        let name = identifier(identity)
        guard entries[name] == nil else { return }
        let entry = Entry(identity: identity, title: title, onExpiration: onExpiration)
        entries[name] = entry
        entry.finiteTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.expire(name) }
        }
        guard #available(iOS 26.0, *), isRegistered, canStart else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: name, title: title,
                                                       subtitle: "\(selection.kind.rawValue.capitalized) · \(selection.quality)")
        request.strategy = .fail
        entry.submission = Task {
            do {
                if #available(iOS 27.0, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
                else { try BGTaskScheduler.shared.submit(request) }
                if entries[name] == nil { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: name) }
            } catch {
                // UIKit's finite background time remains available if scheduling is rejected.
            }
        }
    }

    func report(_ progress: ExtractorProgress, for identity: TransferIdentity) {
        guard #available(iOS 26.0, *), let entry = entries[identifier(identity)],
              let task = entry.continuedTask as? BGContinuedProcessingTask else { return }
        let subtitle: String
        switch progress.phase {
        case .extracting:
            subtitle = "Checking source"
        case .downloading:
            subtitle = "Downloading"
            if let expected = progress.expectedBytes, expected > 0, let received = progress.receivedBytes {
                task.progress.totalUnitCount = 1_000
                task.progress.completedUnitCount = min(899, Int64(900 * min(1, Double(received) / Double(expected))))
            } else if let received = progress.receivedBytes {
                task.progress.totalUnitCount = -1
                task.progress.completedUnitCount = received
            }
        case .processing:
            subtitle = "Preparing media"
            task.progress.totalUnitCount = 1_000
            var completed: Int64 = 900
            if let processed = progress.processedSeconds, let expected = progress.expectedSeconds,
               processed.isFinite, expected.isFinite, expected > 0 {
                completed += Int64(99 * min(1, max(0, processed / expected)))
            }
            task.progress.completedUnitCount = completed
        }
        if subtitle != entry.subtitle {
            entry.subtitle = subtitle
            task.updateTitle(entry.title, subtitle: subtitle)
        }
    }

    func end(_ identity: TransferIdentity, success: Bool) {
        let name = identifier(identity)
        guard let entry = entries.removeValue(forKey: name) else { return }
        entry.submission?.cancel()
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: name)
            if success, let task = entry.continuedTask as? BGContinuedProcessingTask {
                task.progress.totalUnitCount = 1_000
                task.progress.completedUnitCount = 1_000
            }
        }
        entry.continuedTask?.setTaskCompleted(success: success)
        endFiniteTask(entry)
    }

    @available(iOS 26.0, *)
    private func started(_ task: BGTask) {
        guard let entry = entries[task.identifier], let continued = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        entry.continuedTask = continued
        continued.progress.totalUnitCount = 1_000
        continued.progress.completedUnitCount = 0
        let name = task.identifier
        continued.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(name) }
        }
        endFiniteTask(entry)
    }

    private func expire(_ name: String) {
        guard let entry = entries[name] else { return }
        entry.onExpiration()
        end(entry.identity, success: false)
    }

    private func endFiniteTask(_ entry: Entry) {
        guard entry.finiteTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(entry.finiteTask)
        entry.finiteTask = .invalid
    }

    private func identifier(_ identity: TransferIdentity) -> String { Self.identifierPrefix + "." + identity.attemptID.uuidString }

    @MainActor
    private final class Entry {
        let identity: TransferIdentity
        let title: String
        let onExpiration: @MainActor () -> Void
        var subtitle = ""
        var finiteTask = UIBackgroundTaskIdentifier.invalid
        var continuedTask: BGTask?
        var submission: Task<Void, Never>?

        init(identity: TransferIdentity, title: String, onExpiration: @escaping @MainActor () -> Void) {
            self.identity = identity
            self.title = title
            self.onExpiration = onExpiration
        }
    }
}
