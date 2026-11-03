import Combine
import CoreData
import Foundation
import YoinksCore

struct ImportProgress {
    let name: String
    let completed: Int
    let total: Int
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var storage: MediaStorage
    private let context: NSManagedObjectContext
    private var deleting: Set<UUID> = []
    @Published private(set) var details: [UUID: MediaDetails] = [:]
    @Published private(set) var importProgress: ImportProgress?
    @Published var errorMessage: String?
    @Published private(set) var isChangingFolder = false
    var canChangeMediaFolder: () -> Bool = { true }

    init(context: NSManagedObjectContext, storage: MediaStorage) {
        self.context = context
        self.storage = storage
    }

    var storedBytes: Int64 { details.values.reduce(0) { $0 + $1.byteCount } }
    var mediaFolderName: String {
        storage.files.mediaDirectory.standardizedFileURL == MediaFolderPreferences(root: storage.files.root).defaultFolder.standardizedFileURL
            ? "On My iPhone / yoink'd" : storage.files.mediaDirectory.lastPathComponent
    }

    func changeMediaFolder(to folder: URL?) async throws {
        guard !isChangingFolder, deleting.isEmpty, importProgress == nil, canChangeMediaFolder() else { throw CocoaError(.fileLocking) }
        isChangingFolder = true
        defer { isChangingFolder = false }
        storage = try await storage.relocate(to: folder)
    }

    func restore() async throws {
        let recovery = try await storage.prepare()
        if let error = recovery.folderError {
            errorMessage = error
            let request = NSFetchRequest<LibraryItem>(entityName: "LibraryItem")
            details = try await storage.loadDetails(ids: context.fetch(request).map(\.id))
            return
        }
        for deletion in recovery.deletions {
            if try item(id: deletion.id) != nil {
                try await storage.restoreDeletion(deletion)
            } else {
                try await storage.finishDeletion(deletion)
            }
        }
        for pending in recovery.commits {
            if try item(id: pending.staged.id) == nil {
                try await storage.commitFile(pending)
                insert(pending)
                do { try context.save() } catch { context.rollback(); throw error }
            }
            try await storage.finishCommit(pending)
        }
        for staged in try await storage.stagedMedia() where staged.sourceURL == nil {
            do { _ = try await commit(staged) } catch {
                try? await storage.discard(staged)
                errorMessage = "Couldn't recover an interrupted import. \(error.localizedDescription)"
            }
        }
        let request = NSFetchRequest<LibraryItem>(entityName: "LibraryItem")
        details = try await storage.loadDetails(ids: context.fetch(request).map(\.id))
    }

    func importFiles(_ urls: [URL]) async {
        guard importProgress == nil, !isChangingFolder, !urls.isEmpty else { return }
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            importProgress = ImportProgress(name: url.lastPathComponent, completed: index, total: urls.count)
            do {
                let staged = try await storage.stageImport(url)
                do {
                    _ = try await commit(staged)
                } catch {
                    try? await storage.discard(staged)
                    throw error
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        importProgress = nil
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
    }

    /// Metadata is inserted only after real media validation and a durable file move.
    func commit(_ staged: StagedMedia, preferredTitle: String? = nil, preferredThumbnail: Data? = nil, artist: String? = nil) async throws -> MediaFileName {
        if let existing = try item(id: staged.id) {
            try? await storage.discard(staged)
            return try MediaFileName(existing.relativeFileName)
        }
        let inspection = try await storage.inspect(staged)
        try Task.checkCancellation()
        let preferred = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inspected = inspection.details
        let mediaDetails = MediaDetails(kind: inspected.kind, duration: inspected.duration, byteCount: inspected.byteCount,
                                        originalName: inspected.originalName, artist: selectedArtist?.isEmpty == false ? selectedArtist : inspected.artist)
        let thumbnail = await storage.normalizedThumbnail(preferredThumbnail) ?? inspection.thumbnail
        if let thumbnail { try? await storage.saveThumbnail(thumbnail, id: staged.id) }
        let pending = try await storage.prepareCommit(staged, title: preferred.isEmpty ? inspection.title : preferred, details: mediaDetails)
        do {
            try await storage.commitFile(pending)
            insert(pending)
            try context.save()
        } catch {
            context.rollback()
            do { try await storage.rollbackCommit(pending) } catch {
                errorMessage = "The file needs recovery. Reopen yoink'd before importing it again."
            }
            throw error
        }
        details[staged.id] = mediaDetails
        try? await storage.finishCommit(pending)
        return pending.storedFile
    }

    func item(id: UUID) throws -> LibraryItem? {
        let request = NSFetchRequest<LibraryItem>(entityName: "LibraryItem")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    func rename(_ item: LibraryItem, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isChangingFolder, !trimmed.isEmpty, item.managedObjectContext != nil, !item.isDeleted, !deleting.contains(item.id) else { return }
        item.title = trimmed
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func delete(_ item: LibraryItem) async throws {
        guard !isChangingFolder else { throw CocoaError(.fileLocking) }
        guard item.managedObjectContext != nil, !item.isDeleted else { return }
        let id = item.id
        guard !deleting.contains(id) else { return }
        deleting.insert(id)
        defer { deleting.remove(id) }
        let pending = try await storage.stageDeletion(id: id, file: MediaFileName(item.relativeFileName))
        context.delete(item)
        do {
            try context.save()
        } catch {
            context.rollback()
            try await storage.restoreDeletion(pending)
            throw error
        }
        details[id] = nil
        try? await storage.finishDeletion(pending)
    }

    func playbackURL(for item: LibraryItem) async throws -> URL {
        try await storage.availableURL(MediaFileName(item.relativeFileName))
    }

    private func insert(_ pending: PendingMedia) {
        let record = LibraryItem(context: context)
        record.id = pending.staged.id
        record.title = pending.title
        record.mediaKindRawValue = pending.details.kind.rawValue
        record.relativeFileName = pending.storedFile.value
        record.sourceURL = pending.staged.sourceURL
        record.addedAt = pending.addedAt
    }
}
