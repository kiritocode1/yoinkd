import Foundation

/// Links the share extension hands to the app, one JSON file per `CaptureRequest`.
///
/// The extension saves a request here before it tries to open the app. If opening works, the app
/// removes the file when it shows the link. If it doesn't, the app finds the file the next time it
/// comes to the foreground. Both processes use the App Group container, so every operation is a
/// single atomic file write, read, or delete.
public struct CaptureInbox: Sendable {
    public static let appGroup = "group.com.maynkudu.iyoinks"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The App Group inbox, or nil when the process lacks the App Group entitlement.
    public static func shared(fileManager: FileManager = .default) -> CaptureInbox? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { CaptureInbox(directory: $0.appendingPathComponent("CaptureInbox", isDirectory: true)) }
    }

    public func add(_ request: CaptureRequest, at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Entry(request: request, created: date))
        try data.write(to: file(request.id), options: .atomic)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// The oldest saved request. Unreadable files are deleted so one bad file can't block the rest.
    public func next() -> CaptureRequest? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var oldest: Entry?
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  url.lastPathComponent == entry.request.id.uuidString + ".json" else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if oldest.map({ entry.created < $0.created }) ?? true { oldest = entry }
        }
        return oldest?.request
    }

    private func file(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    private struct Entry: Codable {
        let request: CaptureRequest
        let created: Date
    }
}
