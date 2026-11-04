import ActivityKit
import AppIntents
import Foundation

/// The Live Activity for one download. Compiled into the app (which starts and updates it) and the
/// YoinkActivity widget extension (which draws it on the Lock Screen and in the Dynamic Island).
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The Downloads row's status text, such as "Downloading" or "Preparing media".
        var status: String
        /// 0...1 when the download or processing has a known size or length.
        var fraction: Double?
        /// "372 MB / 722.6 MB", or empty.
        var detail: String
        var isPaused: Bool
        var isFinished: Bool
    }

    var jobID: String
    var title: String
    var isAudio: Bool
}

/// Pause or resume a download from its Live Activity. Runs in the app process; the app installs
/// the handler when its queue opens, so the extension's copy is never asked to perform.
struct ToggleDownloadIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume download"
    static let isDiscoverable = false

    @Parameter(title: "Download") var jobID: String

    init() {}
    init(jobID: String) { self.jobID = jobID }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: jobID) { await DownloadActivityActions.toggle?(id) }
        return .result()
    }
}

@MainActor
enum DownloadActivityActions {
    /// Set by the app: pauses a running download or resumes a paused one.
    static var toggle: ((UUID) async -> Void)?
}
