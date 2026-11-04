import Foundation
import YoinksCore

/// One place for requests that arrive from outside the app's screens: yoinkd:// links, App Intents
/// and Shortcuts. RootView shows `pendingCapture`; intents that add downloads wait for `queue`.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// A link to show in the yoink! sheet. RootView takes it and clears it.
    @Published var pendingCapture: CaptureRequest?
    /// Set once the library and download queue have opened.
    weak var queue: DownloadQueue?
    /// Live Activities for running downloads, started once the queue opens.
    let activities = DownloadActivities()

    /// The download queue once it is ready, or nil if it doesn't open within `timeout`.
    func readyQueue(timeout: Duration = .seconds(20)) async -> DownloadQueue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let queue, queue.isReady { return queue }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
