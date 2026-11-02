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
}
