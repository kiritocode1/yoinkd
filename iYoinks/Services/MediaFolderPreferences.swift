import Foundation

struct MediaFolderPreferences {
    let root: URL

    struct Selection {
        let url: URL
        let scoped: Bool
        let error: String?
    }

    private struct Record: Codable {
        let bookmark: Data
        let url: URL
    }

    private var recordURL: URL { root.appendingPathComponent("media-folder.json") }

    var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? root.appendingPathComponent("Media", isDirectory: true)
    }

    func resolve() throws -> Selection {
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return Selection(url: defaultFolder, scoped: false, error: nil)
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: record.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = url.startAccessingSecurityScopedResource()
            if stale { try? save(url) }
            return Selection(url: url, scoped: scoped, error: nil)
        } catch {
            return Selection(url: record.url, scoped: false, error: "The download folder is unavailable. Choose it again in Settings.")
        }
    }

    func save(_ folder: URL?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let folder {
            let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try JSONEncoder().encode(Record(bookmark: bookmark, url: folder)).write(to: recordURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: recordURL.path) {
            try FileManager.default.removeItem(at: recordURL)
        }
    }
}
