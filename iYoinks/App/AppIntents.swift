import AppIntents
import Foundation
import YoinksCore

/// Video or Audio, as a Shortcuts parameter.
enum MediaKindOption: String, AppEnum {
    case video, audio

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Media type"
    static let caseDisplayRepresentations: [MediaKindOption: DisplayRepresentation] = [.video: "Video", .audio: "Audio"]

    var kind: MediaKind { self == .video ? .video : .audio }
}

/// Opens the yoink! sheet with a link filled in, the same as a yoinkd://add link or the share
/// extension. Nothing downloads until the user taps yoink!.
struct AddToYoinkdIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to yoink'd"
    static let description = IntentDescription("Opens yoink'd with the link filled in. Nothing downloads until you tap yoink!.")
    static let openAppWhenRun = true

    @Parameter(title: "Link") var link: URL
    @Parameter(title: "Media type", default: .video) var kind: MediaKindOption

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.pendingCapture = CaptureRequest(link: link.absoluteString, kind: kind.kind)
        return .result()
    }
}

/// Checks a link and adds it to Downloads at the best available quality, without the sheet. For
/// automations the user built on purpose; the shared and in-app paths always confirm first.
struct DownloadWithYoinkdIntent: AppIntent {
    static let title: LocalizedStringResource = "Download with yoink'd"
    static let description = IntentDescription("Checks the link and adds it to Downloads at the best available quality.")
    static let openAppWhenRun = true

    @Parameter(title: "Link") var link: URL
    @Parameter(title: "Media type", default: .video) var kind: MediaKindOption

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let mediaLink: MediaLink
        do { mediaLink = try MediaLink(link.absoluteString) } catch { throw IntentFailure("Use a full HTTPS link.") }
        guard let queue = await AppRouter.shared.readyQueue() else {
            throw IntentFailure("Downloads are still opening. Try again in a moment.")
        }
        let media = try await NativeExtractor.inspect(mediaLink)
        let selection: SourceSelection
        do {
            selection = try media.selection(kind: kind.kind, formatID: nil, outputFormat: .automatic)
        } catch {
            throw IntentFailure(kind == .audio ? "This link has no audio to download." : "This link has no video to download.")
        }
        try await queue.enqueue(media, selection: selection)
        return .result(value: media.title, dialog: "Added \(media.title) to Downloads.")
    }
}

/// An intent error whose message Shortcuts and Siri show as written.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Makes both intents available in Siri, Spotlight and Shortcuts without any setup.
struct YoinkdShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddToYoinkdIntent(),
                    phrases: ["Add a link to \(.applicationName)", "Yoink a link with \(.applicationName)"],
                    shortTitle: "Add a link", systemImageName: "link")
        AppShortcut(intent: DownloadWithYoinkdIntent(),
                    phrases: ["Download with \(.applicationName)"],
                    shortTitle: "Download", systemImageName: "arrow.down.circle")
    }
}
