import Foundation

public enum MediaResponseError: Error, LocalizedError, Equatable, Sendable {
    case badStatus(Int)
    case webpage
    case playlist
    case invalidAddress
    case emptyFile

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): "The server returned HTTP \(code). Check the link or try again."
        case .webpage: "This link opens a webpage. Use a direct video or audio file link."
        case .playlist: "This is a streaming playlist. Use a video or audio file instead."
        case .invalidAddress: "The download must use HTTPS without a username or password."
        case .emptyFile: "The file is empty. Choose another file or check the link."
        }
    }
}

public enum MediaResponse {
    public static func validate(statusCode: Int, finalURL: URL?, mimeType: String?) throws {
        guard (200..<300).contains(statusCode) else { throw MediaResponseError.badStatus(statusCode) }
        guard let finalURL, (try? MediaLink(finalURL.absoluteString)) != nil else {
            throw MediaResponseError.invalidAddress
        }
        let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if ["text/html", "application/xhtml+xml"].contains(mime) { throw MediaResponseError.webpage }
        if mime.contains("mpegurl") || mime == "application/dash+xml" ||
            ["m3u", "m3u8", "mpd"].contains(finalURL.pathExtension.lowercased()) {
            throw MediaResponseError.playlist
        }
    }

    public static func validateHeader(_ data: Data) throws {
        guard !data.isEmpty else { throw MediaResponseError.emptyFile }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return }
        if text.hasPrefix("#extm3u") || text.contains("<mpd") { throw MediaResponseError.playlist }
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") { throw MediaResponseError.webpage }
    }

    public static func fileExtension(name: String, mimeType: String? = nil) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 10, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return ext
        }
        switch mimeType?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return "media"
        }
    }
}
