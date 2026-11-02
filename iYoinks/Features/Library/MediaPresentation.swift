import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import YoinksCore

enum MediaPresentation {
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    static func duration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0 else { return "" }
        let seconds = Int(duration.rounded(.down))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct SharedMedia: Transferable {
    let url: URL
    let title: String
    let kind: MediaKind

    var fileName: String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clean.isEmpty ? "Media" : String(clean.prefix(120))).\(url.pathExtension)"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { media in
            guard FileManager.default.isReadableFile(atPath: media.url.path) else { throw MediaStorageError.missingFile }
            return SentTransferredFile(media.url)
        }
        .exportingCondition { $0.kind == .video }
        .suggestedFileName { $0.fileName }
        FileRepresentation(exportedContentType: .audio) { media in
            guard FileManager.default.isReadableFile(atPath: media.url.path) else { throw MediaStorageError.missingFile }
            return SentTransferredFile(media.url)
        }
        .exportingCondition { $0.kind == .audio }
        .suggestedFileName { $0.fileName }
    }
}
