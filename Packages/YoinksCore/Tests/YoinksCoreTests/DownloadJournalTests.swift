import Foundation
import Testing
@testable import YoinksCore

struct DownloadJournalTests {
    @Test func restoresPausedJobAndRejectsAnOlderSnapshot() async throws {
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
        #expect(restored.jobs == [job])
        #expect(restored.jobs.first?.progress?.fractionCompleted == 0.5)
    }

    @Test func corruptQueueIsReportedWithoutOverwritingItsContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: url)
        await #expect(throws: (any Error).self) { try await DownloadJournal(url: url).load() }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func oneBadJobIsDroppedWithoutLosingTheRestOfTheQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let good = DownloadJob(link: try MediaLink("https://example.com/good.mp4"))
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        func entry(_ id: String, url: String = "https://example.com/v.mp4", phase: String = "queued", extra: String = "") -> String {
            #"{"id":"\#(id)","sourceURL":"\#(url)","createdAt":0,"title":"Bad","phase":"\#(phase)","receivedBytes":0\#(extra)}"#
        }
        let jobs = [
            goodJSON,
            entry(UUID().uuidString, phase: "unknownPhase"),
            entry(UUID().uuidString, url: "http://example.com/insecure.mp4"),
            entry(UUID().uuidString, phase: "completed"),
            entry(UUID().uuidString, extra: #","expectedBytes":0"#),
            entry(good.id.uuidString)
        ]
        try Data(#"{"version":1,"revision":7,"jobs":[\#(jobs.joined(separator: ","))]}"#.utf8).write(to: url)

        let restored = try await DownloadJournal(url: url).load()
        #expect(restored.jobs == [good])
        #expect(restored.discardedJobCount == 5)
        #expect(restored.revision == 7)
    }

    @Test func unknownJournalVersionIsStillRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        try Data(#"{"version":2,"revision":1,"jobs":[]}"#.utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await DownloadJournal(url: url).load() }
    }

    @Test func discardedCountIsNotWrittenBack() throws {
        let encoded = try JSONEncoder().encode(DownloadSnapshot(revision: 1, jobs: []))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["version", "revision", "jobs"])
    }

    @Test func decodingCannotTurnARelativeFilenameIntoAnAbsolutePath() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MediaFileName.self, from: Data("\"../outside.mp4\"".utf8)) }
    }
}
