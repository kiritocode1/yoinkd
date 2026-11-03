import Foundation
import Testing
@testable import YoinksCore

struct MediaResponseTests {
    @Test func rejectsWebpagesPlaylistsAndFailedHTTPResponses() throws {
        let url = try MediaLink("https://example.com/video.mp4").url
        #expect(throws: (any Error).self) { try MediaResponse.validate(statusCode: 404, finalURL: url, mimeType: "video/mp4") }
        #expect(throws: (any Error).self) { try MediaResponse.validate(statusCode: 200, finalURL: url, mimeType: "text/html") }
        #expect(throws: (any Error).self) {
            try MediaResponse.validate(statusCode: 200, finalURL: url, mimeType: "application/vnd.apple.mpegurl")
        }
        #expect(throws: (any Error).self) {
            try MediaResponse.validate(statusCode: 200, finalURL: URL(string: "http://example.com/video.mp4"), mimeType: "video/mp4")
        }
        #expect(throws: Never.self) { try MediaResponse.validate(statusCode: 200, finalURL: url, mimeType: "application/octet-stream") }
    }

    @Test func rejectsAPlaylistOrWebpageEvenWhenNamedAsVideo() {
        #expect(throws: (any Error).self) { try MediaResponse.validateHeader(Data("#EXTM3U\nvideo.ts".utf8)) }
        #expect(throws: (any Error).self) { try MediaResponse.validateHeader(Data("<!doctype html><html>Not media</html>".utf8)) }
        #expect(throws: (any Error).self) { try MediaResponse.validateHeader(Data()) }
    }
}
