import Foundation
import Testing
@testable import YoinksCore

/// A class so `deinit` can remove each test's temporary directory.
final class MediaFileStoreTests {
    private let directory: URL
    private var files: MediaFileStore
    private let contents = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = MediaFileStore(root: directory.appendingPathComponent("Library"))
        try files.prepareDirectories()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func stage(move: Bool = false) throws -> StagedMedia {
        let input = directory.appendingPathComponent("input.mp4")
        try contents.write(to: input)
        return try files.stage(from: input, id: UUID(), operationID: UUID(), originalName: "input.mp4", move: move)
    }

    private func commit(_ staged: StagedMedia) throws -> PendingMedia {
        let details = MediaDetails(kind: .video, duration: 12, byteCount: Int64(contents.count), originalName: "input.mp4")
        let pending = try files.prepareCommit(staged, title: "Input", details: details)
        try files.commitFile(pending)
        return pending
    }

    @Test func downloadedTemporaryFileIsMovedAndRecoverableBeforeReturning() throws {
        let staged = try stage(move: true)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.mp4").path))
        let restored = try #require(files.stagedMedia().first)
        #expect(restored.id == staged.id)
        #expect(try Data(contentsOf: files.stagedURL(restored)) == contents)
    }

    @Test func importKeepsTheOriginalAndRollbackPreservesAllBytesForRetry() throws {
        let staged = try stage()
        let pending = try commit(staged)
        #expect(try Data(contentsOf: directory.appendingPathComponent("input.mp4")) == contents)
        try files.rollbackCommit(pending)
        #expect(try Data(contentsOf: files.stagedURL(staged)) == contents)
        #expect(!FileManager.default.fileExists(atPath: files.mediaURL(pending.storedFile).path))
        #expect(try files.details(id: staged.id) == nil)
    }

    @Test func anInterruptedCommitCanFinishAfterReopeningStorage() throws {
        let pending = try commit(stage())
        let reopened = MediaFileStore(root: files.root)
        let recovered = try #require(reopened.pendingMedia().first)
        try reopened.commitFile(recovered)
        try reopened.finishCommit(recovered)
        #expect(try Data(contentsOf: reopened.mediaURL(pending.storedFile)) == contents)
        #expect(try reopened.details(id: pending.staged.id)?.duration == 12)
        #expect(try reopened.pendingMedia().isEmpty)
    }

    @Test func interruptedDeletionCanRestoreTheFileWhenMetadataStillExists() throws {
        let pending = try commit(stage())
        try files.finishCommit(pending)
        _ = try files.stageDeletion(id: pending.staged.id, file: pending.storedFile)
        let reopened = MediaFileStore(root: files.root)
        let deletion = try #require(reopened.pendingDeletions().first)
        try reopened.restoreDeletion(deletion)
        #expect(try Data(contentsOf: reopened.mediaURL(pending.storedFile)) == contents)
        #expect(try reopened.details(id: pending.staged.id) != nil)
    }

    @Test func confirmedDeletionRemovesMediaAndDetailsWithoutTouchingTheImportSource() throws {
        let pending = try commit(stage())
        let deletion = try files.stageDeletion(id: pending.staged.id, file: pending.storedFile)
        try files.finishDeletion(deletion)
        #expect(!FileManager.default.fileExists(atPath: files.mediaURL(pending.storedFile).path))
        #expect(try files.details(id: pending.staged.id) == nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("input.mp4")) == contents)
    }

    @Test func cleanupAndRetryPreserveAFileAwaitingMetadataRecovery() throws {
        let pending = try commit(stage())
        try files.discard(pending.staged)
        let source = directory.appendingPathComponent("new.mp4")
        try Data([1, 2, 3]).write(to: source)
        let retry = try files.stage(from: source, id: pending.staged.id, operationID: UUID(), originalName: "new.mp4", move: false)
        #expect(throws: (any Error).self) { try self.files.prepareCommit(retry, title: "Retry", details: pending.details) }
        let recovered = try #require(files.pendingMedia().first)
        #expect(recovered.staged.operationID == pending.staged.operationID)
        #expect(try Data(contentsOf: files.mediaURL(recovered.storedFile)) == contents)
    }

    @Test func truncatedImportIsRejectedBeforeMediaInspection() throws {
        let staged = try stage()
        #expect(try files.validateStagedFile(staged) == Int64(contents.count))
        try Data(contents.prefix(4)).write(to: files.stagedURL(staged))
        #expect(throws: (any Error).self) { try self.files.validateStagedFile(staged) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("input.mp4")) == contents)
    }

    @Test func visibleMediaDirectoryKeepsJournalAndMetadataPrivate() throws {
        let visible = directory.appendingPathComponent("Documents", isDirectory: true)
        files = MediaFileStore(root: files.root, mediaDirectory: visible)
        let pending = try commit(stage())
        #expect(files.mediaURL(pending.storedFile).deletingLastPathComponent() == visible)
        #expect(files.queueURL.path.hasPrefix(files.root.path))
        #expect(files.thumbnailURL(id: pending.staged.id).path.hasPrefix(files.root.path))
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
        let deletion = try files.stageDeletion(id: pending.staged.id, file: pending.storedFile)
        try files.restoreDeletion(deletion)
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
    }

    @Test func relocationVerifiesCopiesAndNeverMovesUnmanagedFiles() throws {
        let pending = try commit(stage())
        let unrelated = files.mediaDirectory.appendingPathComponent("notes.txt")
        try Data("Keep me".utf8).write(to: unrelated)
        let destination = directory.appendingPathComponent("Chosen folder")
        let relocation = try files.prepareRelocation(to: destination)
        #expect(relocation.files == [pending.storedFile])
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
        let moved = MediaFileStore(root: files.root, mediaDirectory: destination)
        #expect(try Data(contentsOf: moved.mediaURL(pending.storedFile)) == contents)
        try files.finishRelocation(relocation)
        #expect(!FileManager.default.fileExists(atPath: files.mediaURL(pending.storedFile).path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try moved.details(id: pending.staged.id)?.duration == 12)
    }

    @Test func failedDestinationActivationCanRollbackWithoutDeletingExistingFiles() throws {
        let pending = try commit(stage())
        let destination = directory.appendingPathComponent("Chosen folder")
        let relocation = try files.prepareRelocation(to: destination)
        try files.rollbackRelocation(relocation)
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(pending.storedFile.value).path))
        let preexisting = try files.prepareRelocation(to: destination)
        let repeated = try files.prepareRelocation(to: destination)
        #expect(repeated.createdFiles.isEmpty)
        try files.rollbackRelocation(repeated)
        #expect(try Data(contentsOf: destination.appendingPathComponent(pending.storedFile.value)) == contents)
        try files.rollbackRelocation(preexisting)
    }

    @Test func destinationCollisionLeavesBothExistingFilesIntact() throws {
        let pending = try commit(stage())
        let destination = directory.appendingPathComponent("Chosen folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(pending.storedFile.value)
        let other = Data("Different contents".utf8)
        try other.write(to: target)
        #expect(throws: (any Error).self) { try self.files.prepareRelocation(to: destination) }
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
        #expect(try Data(contentsOf: target) == other)
    }

    @Test func legacyDetailsDecodeWithoutArtist() throws {
        let data = Data(#"{"kind":"audio","duration":30,"byteCount":200,"originalName":"old.flac"}"#.utf8)
        let details = try JSONDecoder().decode(MediaDetails.self, from: data)
        #expect(details.artist == nil)
        #expect(details.kind == .audio)
    }

    @Test func aliasedDestinationDoesNotDeleteItsOwnMedia() throws {
        let pending = try commit(stage())
        let alias = directory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: files.mediaDirectory)
        let relocation = try files.prepareRelocation(to: alias)
        #expect(relocation.files.isEmpty)
        try files.finishRelocation(relocation)
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
    }

    @Test func destinationSymlinkCannotBecomeABrokenSavedFile() throws {
        let pending = try commit(stage())
        let destination = directory.appendingPathComponent("Chosen folder", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(pending.storedFile.value)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: files.mediaURL(pending.storedFile))
        #expect(throws: (any Error).self) { try self.files.prepareRelocation(to: destination) }
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
        #expect(try Data(contentsOf: target) == contents)
    }

    #if os(Linux)
    @Test(.enabled(if: FileManager.default.isWritableFile(atPath: "/dev/shm"), "Needs a second writable filesystem"))
    func saveRollbackAndDeletionAcrossVolumesKeepAllBytes() throws {
        let destination = URL(fileURLWithPath: "/dev/shm", isDirectory: true)
            .appendingPathComponent("yoinkd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        files = MediaFileStore(root: files.root, mediaDirectory: destination)
        let staged = try stage()
        let pending = try commit(staged)
        #expect(try Data(contentsOf: files.mediaURL(pending.storedFile)) == contents)
        try files.rollbackCommit(pending)
        #expect(try Data(contentsOf: files.stagedURL(staged)) == contents)
        let retried = try commit(staged)
        let deletion = try files.stageDeletion(id: retried.staged.id, file: retried.storedFile)
        #expect(!FileManager.default.fileExists(atPath: files.mediaURL(retried.storedFile).path))
        try files.restoreDeletion(deletion)
        #expect(try Data(contentsOf: files.mediaURL(retried.storedFile)) == contents)
    }
    #endif
}
