import Foundation

public enum MediaFileStoreError: Error, LocalizedError {
    case recoveryRequired
    case incompleteFile

    public var errorDescription: String? {
        switch self {
        case .recoveryRequired: "A previous save needs recovery. Reopen iYoinks and try again."
        case .incompleteFile: "The file copy was interrupted. Import the file again or retry the download."
        }
    }
}

public struct MediaDetails: Codable, Equatable, Sendable {
    public let kind: MediaKind
    public let duration: Double
    public let byteCount: Int64
    public let originalName: String

    public init(kind: MediaKind, duration: Double, byteCount: Int64, originalName: String) {
        self.kind = kind
        self.duration = duration
        self.byteCount = byteCount
        self.originalName = originalName
    }
}

public struct StagedMedia: Codable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let fileName: MediaFileName
    public let originalName: String
    public let sourceURL: URL?
    public let expectedBytes: Int64

    public init(id: UUID, operationID: UUID, fileName: MediaFileName, originalName: String, sourceURL: URL?, expectedBytes: Int64) {
        self.id = id
        self.operationID = operationID
        self.fileName = fileName
        self.originalName = originalName
        self.sourceURL = sourceURL
        self.expectedBytes = expectedBytes
    }
}

public struct PendingMedia: Codable, Sendable {
    public let staged: StagedMedia
    public let storedFile: MediaFileName
    public let title: String
    public let addedAt: Date
    public let details: MediaDetails
}

public struct PendingDeletion: Codable, Sendable {
    public let id: UUID
    public let fileName: MediaFileName
}

/// Each operation has its own marker. Crash recovery can finish or reverse it using Core Data's actual state.
public struct MediaFileStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var queueURL: URL { root.appendingPathComponent("Downloads/queue.json") }
    private var stagingDirectory: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    private var pendingDirectory: URL { root.appendingPathComponent("Pending", isDirectory: true) }
    private var deletionDirectory: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    private var detailsDirectory: URL { root.appendingPathComponent("Details", isDirectory: true) }
    private var resumeDirectory: URL { root.appendingPathComponent("Downloads/Resume", isDirectory: true) }

    public func prepareDirectories() throws {
        for directory in [mediaDirectory, stagingDirectory, pendingDirectory, deletionDirectory, detailsDirectory, resumeDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func mediaURL(_ name: MediaFileName) -> URL { mediaDirectory.appendingPathComponent(name.value) }
    public func stagedURL(_ media: StagedMedia) -> URL { stagingDirectory.appendingPathComponent(media.fileName.value) }
    public func thumbnailURL(id: UUID) -> URL { detailsDirectory.appendingPathComponent("\(id).jpg") }

    public func stage(from source: URL, id: UUID, operationID: UUID, originalName: String, sourceURL: URL? = nil, mimeType: String? = nil, move: Bool) throws -> StagedMedia {
        try prepareDirectories()
        let ext = MediaResponse.fileExtension(name: originalName, mimeType: mimeType)
        let name = try MediaFileName("\(id)-\(operationID).\(ext)")
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize > 0 else { throw MediaResponseError.emptyFile }
        let staged = StagedMedia(id: id, operationID: operationID, fileName: name, originalName: originalName, sourceURL: sourceURL, expectedBytes: sourceSize)
        try write(staged, to: stageMarker(staged))
        do {
            if move {
                try FileManager.default.moveItem(at: source, to: stagedURL(staged))
            } else {
                try FileManager.default.copyItem(at: source, to: stagedURL(staged))
            }
            let copiedAttributes = try FileManager.default.attributesOfItem(atPath: stagedURL(staged).path)
            guard (copiedAttributes[.size] as? NSNumber)?.int64Value == sourceSize else { throw MediaFileStoreError.incompleteFile }
        } catch {
            try? removeIfPresent(stagedURL(staged))
            try? removeIfPresent(stageMarker(staged))
            throw error
        }
        return staged
    }

    public func stagedMedia() throws -> [StagedMedia] { try records(in: stagingDirectory) }
    public func pendingMedia() throws -> [PendingMedia] { try records(in: pendingDirectory) }
    public func pendingDeletions() throws -> [PendingDeletion] { try records(in: deletionDirectory) }

    public func validateStagedFile(_ staged: StagedMedia) throws -> Int64 {
        let url = stagedURL(staged)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw MediaResponseError.emptyFile }
        guard size == staged.expectedBytes else { throw MediaFileStoreError.incompleteFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try MediaResponse.validateHeader(try handle.read(upToCount: 512) ?? Data())
        return size
    }

    public func prepareCommit(_ staged: StagedMedia, title: String, details: MediaDetails) throws -> PendingMedia {
        guard !FileManager.default.fileExists(atPath: pendingMarker(staged.id).path) else { throw MediaFileStoreError.recoveryRequired }
        let ext = URL(fileURLWithPath: staged.fileName.value).pathExtension
        let pending = PendingMedia(staged: staged, storedFile: try MediaFileName("\(staged.id).\(ext)"), title: title, addedAt: .now, details: details)
        try write(pending, to: pendingMarker(staged.id))
        return pending
    }

    public func commitFile(_ pending: PendingMedia) throws {
        let target = mediaURL(pending.storedFile)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: stagedURL(pending.staged), to: target)
        }
        try write(pending.details, to: detailsURL(pending.staged.id))
    }

    public func rollbackCommit(_ pending: PendingMedia) throws {
        let target = mediaURL(pending.storedFile)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: stagedURL(pending.staged))
        }
        try removeIfPresent(detailsURL(pending.staged.id))
        try removeIfPresent(pendingMarker(pending.staged.id))
    }

    public func finishCommit(_ pending: PendingMedia) throws {
        try removeIfPresent(stageMarker(pending.staged))
        try removeIfPresent(pendingMarker(pending.staged.id))
    }

    public func discard(_ staged: StagedMedia) throws {
        guard !FileManager.default.fileExists(atPath: pendingMarker(staged.id).path) else { return }
        try removeIfPresent(stagedURL(staged))
        try removeIfPresent(stageMarker(staged))
    }

    public func details(id: UUID) throws -> MediaDetails? {
        let url = detailsURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MediaDetails.self, from: Data(contentsOf: url))
    }

    public func saveThumbnail(_ data: Data, id: UUID) throws { try data.write(to: thumbnailURL(id: id), options: .atomic) }

    public func stageDeletion(id: UUID, file: MediaFileName) throws -> PendingDeletion {
        let pending = PendingDeletion(id: id, fileName: file)
        try write(pending, to: deletionMarker(id))
        let source = mediaURL(file)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: trashURL(pending))
        }
        return pending
    }

    public func restoreDeletion(_ pending: PendingDeletion) throws {
        let source = trashURL(pending)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: mediaURL(pending.fileName))
        }
        try removeIfPresent(deletionMarker(pending.id))
    }

    public func finishDeletion(_ pending: PendingDeletion) throws {
        try removeIfPresent(trashURL(pending))
        try removeIfPresent(detailsURL(pending.id))
        try removeIfPresent(thumbnailURL(id: pending.id))
        try removeIfPresent(deletionMarker(pending.id))
    }

    public func saveResumeData(_ data: Data, id: UUID) throws -> MediaFileName {
        let name = try MediaFileName("\(id).resume")
        try data.write(to: resumeDirectory.appendingPathComponent(name.value), options: .atomic)
        return name
    }

    public func resumeData(_ name: MediaFileName) throws -> Data { try Data(contentsOf: resumeDirectory.appendingPathComponent(name.value)) }
    public func removeResumeData(_ name: MediaFileName) throws { try removeIfPresent(resumeDirectory.appendingPathComponent(name.value)) }

    private func stageMarker(_ staged: StagedMedia) -> URL { stagingDirectory.appendingPathComponent("\(staged.operationID).json") }
    private func pendingMarker(_ id: UUID) -> URL { pendingDirectory.appendingPathComponent("\(id).json") }
    private func deletionMarker(_ id: UUID) -> URL { deletionDirectory.appendingPathComponent("\(id).json") }
    private func detailsURL(_ id: UUID) -> URL { detailsDirectory.appendingPathComponent("\(id).json") }
    private func trashURL(_ pending: PendingDeletion) -> URL { deletionDirectory.appendingPathComponent(pending.fileName.value) }

    private func write<T: Encodable>(_ value: T, to url: URL) throws { try JSONEncoder().encode(value).write(to: url, options: .atomic) }

    private func records<T: Decodable>(in directory: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(T.self, from: Data(contentsOf: $0)) }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
