import Foundation
import XCTest
@testable import YoinksCore

final class MediaFileStoreTests: XCTestCase {
    private var directory: URL!
    private var files: MediaFileStore!
    private let contents = Data([0, 0, 0, 24, 102, 116, 121, 112, 109, 112, 52, 50])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = MediaFileStore(root: directory.appendingPathComponent("Library"))
        try files.prepareDirectories()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

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

    func testDownloadedTemporaryFileIsMovedAndRecoverableBeforeReturning() throws {
        let staged = try stage(move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.mp4").path))
        let restored = try XCTUnwrap(files.stagedMedia().first)
        XCTAssertEqual(restored.id, staged.id)
        XCTAssertEqual(try Data(contentsOf: files.stagedURL(restored)), contents)
    }

    func testImportKeepsTheOriginalAndRollbackPreservesAllBytesForRetry() throws {
        let staged = try stage()
        let pending = try commit(staged)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("input.mp4")), contents)
        try files.rollbackCommit(pending)
        XCTAssertEqual(try Data(contentsOf: files.stagedURL(staged)), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.mediaURL(pending.storedFile).path))
        XCTAssertNil(try files.details(id: staged.id))
    }

    func testAnInterruptedCommitCanFinishAfterReopeningStorage() throws {
        let pending = try commit(stage())
        let reopened = MediaFileStore(root: files.root)
        let recovered = try XCTUnwrap(reopened.pendingMedia().first)
        try reopened.commitFile(recovered)
        try reopened.finishCommit(recovered)
        XCTAssertEqual(try Data(contentsOf: reopened.mediaURL(pending.storedFile)), contents)
        XCTAssertEqual(try reopened.details(id: pending.staged.id)?.duration, 12)
        XCTAssertTrue(try reopened.pendingMedia().isEmpty)
    }

    func testInterruptedDeletionCanRestoreTheFileWhenMetadataStillExists() throws {
        let pending = try commit(stage())
        try files.finishCommit(pending)
        _ = try files.stageDeletion(id: pending.staged.id, file: pending.storedFile)
        let reopened = MediaFileStore(root: files.root)
        let deletion = try XCTUnwrap(reopened.pendingDeletions().first)
        try reopened.restoreDeletion(deletion)
        XCTAssertEqual(try Data(contentsOf: reopened.mediaURL(pending.storedFile)), contents)
        XCTAssertNotNil(try reopened.details(id: pending.staged.id))
    }

    func testConfirmedDeletionRemovesMediaAndDetailsWithoutTouchingTheImportSource() throws {
        let pending = try commit(stage())
        let deletion = try files.stageDeletion(id: pending.staged.id, file: pending.storedFile)
        try files.finishDeletion(deletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.mediaURL(pending.storedFile).path))
        XCTAssertNil(try files.details(id: pending.staged.id))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("input.mp4")), contents)
    }

    func testCleanupAndRetryPreserveAFileAwaitingMetadataRecovery() throws {
        let pending = try commit(stage())
        try files.discard(pending.staged)
        let source = directory.appendingPathComponent("new.mp4")
        try Data([1, 2, 3]).write(to: source)
        let retry = try files.stage(from: source, id: pending.staged.id, operationID: UUID(), originalName: "new.mp4", move: false)
        XCTAssertThrowsError(try files.prepareCommit(retry, title: "Retry", details: pending.details))
        let recovered = try XCTUnwrap(files.pendingMedia().first)
        XCTAssertEqual(recovered.staged.operationID, pending.staged.operationID)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(recovered.storedFile)), contents)
    }

    func testTruncatedImportIsRejectedBeforeMediaInspection() throws {
        let staged = try stage()
        XCTAssertEqual(try files.validateStagedFile(staged), Int64(contents.count))
        try Data(contents.prefix(4)).write(to: files.stagedURL(staged))
        XCTAssertThrowsError(try files.validateStagedFile(staged))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("input.mp4")), contents)
    }

    func testVisibleMediaDirectoryKeepsJournalAndMetadataPrivate() throws {
        let visible = directory.appendingPathComponent("Documents", isDirectory: true)
        files = MediaFileStore(root: files.root, mediaDirectory: visible)
        let pending = try commit(stage())
        XCTAssertEqual(files.mediaURL(pending.storedFile).deletingLastPathComponent(), visible)
        XCTAssertTrue(files.queueURL.path.hasPrefix(files.root.path))
        XCTAssertTrue(files.thumbnailURL(id: pending.staged.id).path.hasPrefix(files.root.path))
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
        let deletion = try files.stageDeletion(id: pending.staged.id, file: pending.storedFile)
        try files.restoreDeletion(deletion)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
    }

    func testRelocationVerifiesCopiesAndNeverMovesUnmanagedFiles() throws {
        let pending = try commit(stage())
        let unrelated = files.mediaDirectory.appendingPathComponent("notes.txt")
        try Data("Keep me".utf8).write(to: unrelated)
        let destination = directory.appendingPathComponent("Chosen folder")
        let relocation = try files.prepareRelocation(to: destination)
        XCTAssertEqual(relocation.files, [pending.storedFile])
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
        let moved = MediaFileStore(root: files.root, mediaDirectory: destination)
        XCTAssertEqual(try Data(contentsOf: moved.mediaURL(pending.storedFile)), contents)
        try files.finishRelocation(relocation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.mediaURL(pending.storedFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try moved.details(id: pending.staged.id)?.duration, 12)
    }

    func testFailedDestinationActivationCanRollbackWithoutDeletingExistingFiles() throws {
        let pending = try commit(stage())
        let destination = directory.appendingPathComponent("Chosen folder")
        let relocation = try files.prepareRelocation(to: destination)
        try files.rollbackRelocation(relocation)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(pending.storedFile.value).path))
        let preexisting = try files.prepareRelocation(to: destination)
        let repeated = try files.prepareRelocation(to: destination)
        XCTAssertTrue(repeated.createdFiles.isEmpty)
        try files.rollbackRelocation(repeated)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(pending.storedFile.value)), contents)
        try files.rollbackRelocation(preexisting)
    }

    func testDestinationCollisionLeavesBothExistingFilesIntact() throws {
        let pending = try commit(stage())
        let destination = directory.appendingPathComponent("Chosen folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(pending.storedFile.value)
        let other = Data("Different contents".utf8)
        try other.write(to: target)
        XCTAssertThrowsError(try files.prepareRelocation(to: destination))
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
        XCTAssertEqual(try Data(contentsOf: target), other)
    }

    func testLegacyDetailsDecodeWithoutArtist() throws {
        let data = Data(#"{"kind":"audio","duration":30,"byteCount":200,"originalName":"old.flac"}"#.utf8)
        let details = try JSONDecoder().decode(MediaDetails.self, from: data)
        XCTAssertNil(details.artist)
        XCTAssertEqual(details.kind, .audio)
    }

    func testAliasedDestinationDoesNotDeleteItsOwnMedia() throws {
        let pending = try commit(stage())
        let alias = directory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: files.mediaDirectory)
        let relocation = try files.prepareRelocation(to: alias)
        XCTAssertTrue(relocation.files.isEmpty)
        try files.finishRelocation(relocation)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
    }

    func testDestinationSymlinkCannotBecomeABrokenSavedFile() throws {
        let pending = try commit(stage())
        let destination = directory.appendingPathComponent("Chosen folder", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(pending.storedFile.value)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: files.mediaURL(pending.storedFile))
        XCTAssertThrowsError(try files.prepareRelocation(to: destination))
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
        XCTAssertEqual(try Data(contentsOf: target), contents)
    }

    #if os(Linux)
    func testSaveRollbackAndDeletionAcrossVolumesKeepAllBytes() throws {
        let sharedMemory = URL(fileURLWithPath: "/dev/shm", isDirectory: true)
        guard FileManager.default.isWritableFile(atPath: sharedMemory.path) else { throw XCTSkip("No second writable filesystem") }
        let destination = sharedMemory.appendingPathComponent("yoinkd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        files = MediaFileStore(root: files.root, mediaDirectory: destination)
        let staged = try stage()
        let pending = try commit(staged)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(pending.storedFile)), contents)
        try files.rollbackCommit(pending)
        XCTAssertEqual(try Data(contentsOf: files.stagedURL(staged)), contents)
        let retried = try commit(staged)
        let deletion = try files.stageDeletion(id: retried.staged.id, file: retried.storedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.mediaURL(retried.storedFile).path))
        try files.restoreDeletion(deletion)
        XCTAssertEqual(try Data(contentsOf: files.mediaURL(retried.storedFile)), contents)
    }
    #endif
}
