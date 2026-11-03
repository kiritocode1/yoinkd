import Testing
@testable import YoinksCore

struct MediaLinkTests {
    @Test func trimsPastedWhitespaceAndPreservesTheAddress() throws {
        let address = "https://example.com/media%20file.mp4?quality=1080#chapter"
        let link = try MediaLink(" \n\(address)\t ")
        #expect(link.url.absoluteString == address)
    }

    @Test func acceptsAPlatformPageWithoutClaimingItIsAMediaFile() throws {
        let link = try MediaLink("https://www.youtube.com/watch?v=example")
        #expect(link.url.host == "www.youtube.com")
        #expect(link.url.path == "/watch")
    }

    @Test(arguments: [
        (" \n", MediaLinkError.empty),
        ("example.com/video.mp4", .httpsRequired),
        ("http://example.com/video.mp4", .httpsRequired),
        ("file:///tmp/video.mp4", .httpsRequired),
        ("https://", .invalidURL),
        ("https://example.com/a b.mp4", .invalidURL),
        ("https://example.com/\nvideo.mp4", .invalidURL),
        ("https://person:password@example.com/video.mp4", .credentialsNotAllowed)
    ])
    func rejectsIncompleteUnsafeAndNonHTTPSInput(_ input: String, _ expected: MediaLinkError) {
        #expect(throws: expected) { try MediaLink(input) }
    }
}
