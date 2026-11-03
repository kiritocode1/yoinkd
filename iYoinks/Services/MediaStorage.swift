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
    let folderError: String?
}

/// Coordinates Files imports, inspects real media, and keeps file work off the main actor.
actor MediaStorage {
    let files: MediaFileStore
    private let scopedFolder: URL?
    private let folderError: String?

    init(files: MediaFileStore, scopedFolder: URL? = nil, folderError: String? = nil) {
        self.files = files
        self.scopedFolder = scopedFolder
        self.folderError = folderError
    }

    deinit { scopedFolder?.stopAccessingSecurityScopedResource() }

    @concurrent
    nonisolated static func open(root: URL) async throws -> MediaStorage {
        let selection = try MediaFolderPreferences(root: root).resolve()
        return MediaStorage(files: MediaFileStore(root: root, mediaDirectory: selection.url),
                            scopedFolder: selection.scoped ? selection.url : nil, folderError: selection.error)
    }

    func prepare() throws -> MediaRecovery {
        let legacy = MediaFileStore(root: files.root)
        try legacy.prepareDirectories()
        if folderError == nil, files.mediaDirectory.standardizedFileURL == MediaFolderPreferences(root: files.root).defaultFolder.standardizedFileURL {
            let migration = try legacy.prepareRelocation(to: files.mediaDirectory)
            try? legacy.finishRelocation(migration)
        }
        return try MediaRecovery(commits: files.pendingMedia(), deletions: files.pendingDeletions(), folderError: folderError)
    }

    func relocate(to folder: URL?) throws -> MediaStorage {
        let preferences = MediaFolderPreferences(root: files.root)
        let destination = folder ?? preferences.defaultFolder
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let scoped = folder?.startAccessingSecurityScopedResource() ?? false
        do {
            var coordinationError: NSError?
            var result: Result<MediaRelocation, any Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forMerging, error: &coordinationError) { coordinated in
                result = Result { try files.prepareRelocation(to: coordinated) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileWriteUnknown) }
            let relocation = try result.get()
            do { try preferences.save(folder) } catch {
                try? files.rollbackRelocation(relocation)
                throw error
            }
            let storage = MediaStorage(files: MediaFileStore(root: files.root, mediaDirectory: destination), scopedFolder: scoped ? folder : nil)
            try? files.finishRelocation(relocation)
            return storage
        } catch {
            if scoped { folder?.stopAccessingSecurityScopedResource() }
            throw error
        }
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

        let audioExtensions = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "caf"]
        let kind: MediaKind = videoTracks.isEmpty || (!audioTracks.isEmpty && audioExtensions.contains(url.pathExtension.lowercased())) ? .audio : .video
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let titleItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first
        let embeddedTitle = try? await titleItem?.load(.stringValue)
        let artistItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first
        let embeddedArtist = try? await artistItem?.load(.stringValue)
        let fallback = URL(fileURLWithPath: staged.originalName).deletingPathExtension().lastPathComponent
        let title = embeddedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let details = MediaDetails(kind: kind, duration: duration.seconds, byteCount: size, originalName: staged.originalName,
                                   artist: embeddedArtist?.trimmingCharacters(in: .whitespacesAndNewlines))
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
    func commitFile(_ pending: PendingMedia) throws { try coordinateMedia { try $0.commitFile(pending) } }
    func rollbackCommit(_ pending: PendingMedia) throws { try coordinateMedia { try $0.rollbackCommit(pending) } }
    func finishCommit(_ pending: PendingMedia) throws { try files.finishCommit(pending) }
    func discard(_ staged: StagedMedia) throws { try files.discard(staged) }
    func stagedMedia() throws -> [StagedMedia] { try files.stagedMedia() }
    func stageDeletion(id: UUID, file: MediaFileName) throws -> PendingDeletion { try coordinateMedia { try $0.stageDeletion(id: id, file: file) } }
    func restoreDeletion(_ pending: PendingDeletion) throws { try coordinateMedia { try $0.restoreDeletion(pending) } }
    func finishDeletion(_ pending: PendingDeletion) throws { try files.finishDeletion(pending) }
    func saveThumbnail(_ data: Data, id: UUID) throws { try files.saveThumbnail(data, id: id) }
    func normalizedThumbnail(_ data: Data?) -> Data? {
        guard let data, data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 16_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 720]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let normalized = UIImage(cgImage: image).jpegData(compressionQuality: 0.85),
              normalized.count <= 1024 * 1024 else { return nil }
        return normalized
    }
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

    private func coordinateMedia<Value: Sendable>(_ operation: @Sendable (MediaFileStore) throws -> Value) throws -> Value {
        let currentFiles = files
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: currentFiles.mediaDirectory, options: .forMerging, error: &coordinationError) { coordinated in
            result = Result { try operation(MediaFileStore(root: currentFiles.root, mediaDirectory: coordinated)) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}
