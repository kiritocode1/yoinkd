import Foundation
import Testing
@testable import YoinksCore

struct CaptureRequestTests {
    @Test func readsAnEncodedLinkAndKind() throws {
        let url = try #require(URL(string: "yoinkd://add?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc%26t%3D10&kind=audio"))
        let request = try #require(CaptureRequest(url: url))
        #expect(request.link == "https://www.youtube.com/watch?v=abc&t=10")
        #expect(request.kind == .audio)
    }

    @Test(arguments: [
        ("yoinkd://add", "", nil),
        ("YOINKD://ADD?url=https://example.com/a.mp4", "https://example.com/a.mp4", nil),
        ("yoinkd://add?url=%20https://example.com/a.mp4%20&kind=Video", "https://example.com/a.mp4", MediaKind.video),
        ("yoinkd://add?url=http://example.com/a.mp4&kind=podcast", "http://example.com/a.mp4", nil),
    ] as [(String, String, MediaKind?)])
    func keepsTheLinkForTheSheetToValidate(_ address: String, _ link: String, _ kind: MediaKind?) throws {
        let url = try #require(URL(string: address))
        let request = try #require(CaptureRequest(url: url))
        #expect(request.link == link)
        #expect(request.kind == kind)
    }

    @Test(arguments: ["https://example.com/add?url=x", "yoinkd://open?url=x", "yoinkd:add", "other://add"])
    func ignoresOtherURLs(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(CaptureRequest(url: url) == nil)
    }

    @Test func eachRequestPresentsTheSheetAgain() {
        #expect(CaptureRequest(link: "https://example.com") != CaptureRequest(link: "https://example.com"))
    }

    @Test(arguments: [MediaKind.audio, nil])
    func urlRoundTripsLinkKindAndID(_ kind: MediaKind?) throws {
        let request = CaptureRequest(link: "https://www.instagram.com/reel/Chunk8-jurw/?igsh=a%2Bb&x=1", kind: kind)
        let parsed = try #require(CaptureRequest(url: request.url))
        #expect(parsed == request)
    }

    @Test func malformedIDGetsAFreshOne() throws {
        let url = try #require(URL(string: "yoinkd://add?url=https://example.com&id=not-a-uuid"))
        let request = try #require(CaptureRequest(url: url))
        #expect(request.link == "https://example.com")
    }
}

final class CaptureInboxTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaptureInboxTests-\(UUID().uuidString)", isDirectory: true)
    private var inbox: CaptureInbox { CaptureInbox(directory: directory) }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func emptyOrMissingInboxHasNothing() {
        #expect(inbox.next() == nil)
    }

    @Test func returnsTheOldestUntilItIsRemoved() throws {
        let newer = CaptureRequest(link: "https://example.com/new", kind: .video)
        let older = CaptureRequest(link: "https://example.com/old", kind: .audio)
        try inbox.add(newer, at: Date(timeIntervalSince1970: 200))
        try inbox.add(older, at: Date(timeIntervalSince1970: 100))
        #expect(inbox.next() == older)
        inbox.remove(older.id)
        #expect(inbox.next() == newer)
        inbox.remove(newer.id)
        #expect(inbox.next() == nil)
    }

    @Test func unreadableFilesAreDeletedAndSkipped() throws {
        let good = CaptureRequest(link: "https://example.com/good")
        try inbox.add(good)
        let bad = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: bad)
        #expect(inbox.next() == good)
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }
}
