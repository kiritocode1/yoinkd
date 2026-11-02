import XCTest
@testable import YoinksCore

final class MediaFileNameTests: XCTestCase {
    func testKeepsAStoredFileNameIndependentOfTheSandboxLocation() throws {
        let fileName = try MediaFileName("recording-001.mp4")
        XCTAssertEqual(fileName.value, "recording-001.mp4")
    }

    func testRejectsPathsAndInvalidComponents() {
        for value in ["", ".", "..", "../video.mp4", "/tmp/video.mp4", "folder/video.mp4", "folder\\video.mp4", "bad\0name"] {
            XCTAssertThrowsError(try MediaFileName(value))
        }
    }
}
