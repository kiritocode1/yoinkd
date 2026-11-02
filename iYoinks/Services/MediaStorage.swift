import AVFoundation
import Foundation
import ImageIO
import UIKit
import YoinksCore

enum MediaStorageError: Error, LocalizedError {
    case unsupportedMedia
    case protectedMedia
    case missingFile

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia: "This file can't play on this iPhone. Choose a supported video or audio file."
        case .protectedMedia: "This file is protected and can't be saved for offline playback."
        case .missingFile: "The saved file is missing. Import it again or retry the download."
        }
    }
}

struct MediaInspection: Sendable {
    let title: String
    let details: MediaDetails
    let thumbnail: Data?
}

struct MediaRecovery: Sendable {
    let commits: [PendingMedia]
    let deletions: [PendingDeletion]
}

/// Coordinates Files imports, inspects real media, and keeps file work off the main actor.
actor MediaStorage {
    let files: MediaFileStore

    init(files: MediaFileStore) { self.files = files }

    func prepare() throws -> MediaRecovery {
        try files.prepareDirectories()
        return try MediaRecovery(commits: files.pendingMedia(), deletions: files.pendingDeletions())
    }

    func stageImport(_ source: URL) throws -> StagedMedia {
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<StagedMedia, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinated in
            result = Result {
                try files.stage(from: coordinated, id: UUID(), operationID: UUID(), originalName: source.lastPathComponent, move: false)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    func inspect(_ staged: StagedMedia) async throws -> MediaInspection {
        let url = files.stagedURL(staged)
        let size = try files.validateStagedFile(staged)

        let asset = AVURLAsset(url: url)
        let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
        guard !protected else { throw MediaStorageError.protectedMedia }
        guard playable, duration.seconds.isFinite, duration.seconds > 0 else { throw MediaStorageError.unsupportedMedia }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw MediaStorageError.unsupportedMedia }
        try Task.checkCancellation()

        let kind: MediaKind = videoTracks.isEmpty ? .audio : .video
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let titleItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first
        let embeddedTitle = try? await titleItem?.load(.stringValue)
        let fallback = URL(fileURLWithPath: staged.originalName).deletingPathExtension().lastPathComponent
        let title = embeddedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let details = MediaDetails(kind: kind, duration: duration.seconds, byteCount: size, originalName: staged.originalName)
        let thumbnail = await thumbnail(url: url, kind: kind, duration: duration.seconds, metadata: metadata)
        return MediaInspection(title: title.isEmpty ? (fallback.isEmpty ? "Untitled media" : fallback) : title, details: details, thumbnail: thumbnail)
    }

    private func thumbnail(url: URL, kind: MediaKind, duration: Double, metadata: [AVMetadataItem]) async -> Data? {
        if kind == .video {
            return await Self.videoThumbnail(url: url, duration: duration)
        }
        guard let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await artwork.load(.dataValue),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    @concurrent
    private nonisolated static func videoThumbnail(url: URL, duration: Double) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 480)
        guard let generated = try? await generator.image(at: CMTime(seconds: min(1, duration / 10), preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: generated.image).jpegData(compressionQuality: 0.8)
    }

    func prepareCommit(_ staged: StagedMedia, title: String, details: MediaDetails) throws -> PendingMedia {
        try files.prepareCommit(staged, title: title, details: details)
    }
    func commitFile(_ pending: PendingMedia) throws { try files.commitFile(pending) }
    func rollbackCommit(_ pending: PendingMedia) throws { try files.rollbackCommit(pending) }
    func finishCommit(_ pending: PendingMedia) throws { try files.finishCommit(pending) }
    func discard(_ staged: StagedMedia) throws { try files.discard(staged) }
    func stagedMedia() throws -> [StagedMedia] { try files.stagedMedia() }
    func stageDeletion(id: UUID, file: MediaFileName) throws -> PendingDeletion { try files.stageDeletion(id: id, file: file) }
    func restoreDeletion(_ pending: PendingDeletion) throws { try files.restoreDeletion(pending) }
    func finishDeletion(_ pending: PendingDeletion) throws { try files.finishDeletion(pending) }
    func saveThumbnail(_ data: Data, id: UUID) throws { try files.saveThumbnail(data, id: id) }
    func readThumbnail(id: UUID) -> Data? { try? Data(contentsOf: files.thumbnailURL(id: id)) }
    func resumeData(_ name: MediaFileName) throws -> Data { try files.resumeData(name) }
    func saveResumeData(_ data: Data, id: UUID) throws -> MediaFileName { try files.saveResumeData(data, id: id) }
    func removeResumeData(_ name: MediaFileName) throws { try files.removeResumeData(name) }

    func sourceWorkDirectory(id: UUID) throws -> URL {
        let directory = files.root.appendingPathComponent("Downloads/Sources/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func sourceCacheDirectory() throws -> URL {
        let directory = files.root.appendingPathComponent("Downloads/SourceCache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func stageSourceFile(_ file: ExtractedFile, id: UUID, attemptID: UUID, sourceURL: URL) throws -> StagedMedia {
        let directory = try sourceWorkDirectory(id: id)
        return try files.stage(from: directory.appendingPathComponent(file.fileName.value), id: id, operationID: attemptID,
                               originalName: file.fileName.value, sourceURL: sourceURL, move: true)
    }

    func removeSourceWork(id: UUID) throws {
        let directory = files.root.appendingPathComponent("Downloads/Sources/\(id)", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func loadDetails(ids: [UUID]) throws -> [UUID: MediaDetails] {
        var result: [UUID: MediaDetails] = [:]
        for id in ids { result[id] = try files.details(id: id) }
        return result
    }

    func availableURL(_ name: MediaFileName) throws -> URL {
        let url = files.mediaURL(name)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaStorageError.missingFile }
        return url
    }
}
