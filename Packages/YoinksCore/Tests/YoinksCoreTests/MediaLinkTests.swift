import XCTest
@testable import YoinksCore

final class MediaLinkTests: XCTestCase {
    func testTrimsPastedWhitespaceAndPreservesTheAddress() throws {
        let address = "https://example.com/media%20file.mp4?quality=1080#chapter"
        let link = try MediaLink(" \n\(address)\t ")
        XCTAssertEqual(link.url.absoluteString, address)
    }

    func testAcceptsAPlatformPageWithoutClaimingItIsAMediaFile() throws {
        let link = try MediaLink("https://www.youtube.com/watch?v=example")
        XCTAssertEqual(link.url.host, "www.youtube.com")
        XCTAssertEqual(link.url.path, "/watch")
    }

    func testRejectsIncompleteUnsafeAndNonHTTPSInput() {
        let cases: [(String, MediaLinkError)] = [
            (" \n", .empty),
            ("example.com/video.mp4", .httpsRequired),
            ("http://example.com/video.mp4", .httpsRequired),
            ("file:///tmp/video.mp4", .httpsRequired),
            ("https://", .invalidURL),
            ("https://example.com/a b.mp4", .invalidURL),
            ("https://example.com/\nvideo.mp4", .invalidURL),
            ("https://person:password@example.com/video.mp4", .credentialsNotAllowed)
        ]

        for (input, expected) in cases {
            do {
                _ = try MediaLink(input)
                XCTFail("Accepted invalid input: \(input)")
            } catch {
                XCTAssertEqual(error, expected, "Input: \(input)")
            }
        }
    }
}
