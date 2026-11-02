import Foundation
import XCTest
@testable import YoinksCore

final class MediaResponseTests: XCTestCase {
    func testRejectsWebpagesPlaylistsAndFailedHTTPResponses() throws {
        let url = try MediaLink("https://example.com/video.mp4").url
        XCTAssertThrowsError(try MediaResponse.validate(statusCode: 404, finalURL: url, mimeType: "video/mp4"))
        XCTAssertThrowsError(try MediaResponse.validate(statusCode: 200, finalURL: url, mimeType: "text/html"))
        XCTAssertThrowsError(try MediaResponse.validate(statusCode: 200, finalURL: url, mimeType: "application/vnd.apple.mpegurl"))
        XCTAssertThrowsError(try MediaResponse.validate(statusCode: 200, finalURL: URL(string: "http://example.com/video.mp4"), mimeType: "video/mp4"))
        XCTAssertNoThrow(try MediaResponse.validate(statusCode: 200, finalURL: url, mimeType: "application/octet-stream"))
    }

    func testRejectsAPlaylistOrWebpageEvenWhenNamedAsVideo() {
        XCTAssertThrowsError(try MediaResponse.validateHeader(Data("#EXTM3U\nvideo.ts".utf8)))
        XCTAssertThrowsError(try MediaResponse.validateHeader(Data("<!doctype html><html>Not media</html>".utf8)))
        XCTAssertThrowsError(try MediaResponse.validateHeader(Data()))
    }
}
