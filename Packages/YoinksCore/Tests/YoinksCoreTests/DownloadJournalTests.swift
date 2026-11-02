import Foundation
import XCTest
@testable import YoinksCore

@MainActor
final class DownloadJournalTests: XCTestCase {
    func testRestoresPausedJobAndRejectsAnOlderSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let journal = DownloadJournal(url: url)
        var job = DownloadJob(link: try MediaLink("https://example.com/video.mp4"))
        job.phase = .paused
        job.receivedBytes = 4096
        job.expectedBytes = 8192
        job.resumeFile = try MediaFileName("saved.resume")
        try await journal.save(DownloadSnapshot(revision: 2, jobs: [job]))
        try await journal.save(DownloadSnapshot(revision: 1, jobs: []))
        let reopened = DownloadJournal(url: url)
        let restored = try await reopened.load()
        XCTAssertEqual(restored.jobs, [job])
        XCTAssertEqual(restored.jobs.first?.progress?.fractionCompleted, 0.5)
    }

    func testCorruptQueueIsReportedWithoutOverwritingItsContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        do {
            _ = try await DownloadJournal(url: url).load()
            XCTFail("Corrupt queue was accepted")
        } catch {
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testDecodingCannotTurnARelativeFilenameIntoAnAbsolutePath() {
        XCTAssertThrowsError(try JSONDecoder().decode(MediaFileName.self, from: Data("\"../outside.mp4\"".utf8)))
    }
}
