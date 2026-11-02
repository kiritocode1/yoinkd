import UIKit

@MainActor
final class IYoinksAppDelegate: NSObject, UIApplicationDelegate {
    let sourceBackgroundWork = SourceBackgroundWork()
    var onForeground: (@MainActor () -> Void)?
    private var backgroundCompletion: (() -> Void)?
    private var eventsFinished = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        sourceBackgroundWork.register()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) { onForeground?() }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadQueue.sessionIdentifier else { completionHandler(); return }
        backgroundCompletion = completionHandler
        completeIfReady()
    }

    func finishedBackgroundWork() {
        eventsFinished = true
        completeIfReady()
    }

    private func completeIfReady() {
        guard eventsFinished, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        eventsFinished = false
        completion()
    }
}
