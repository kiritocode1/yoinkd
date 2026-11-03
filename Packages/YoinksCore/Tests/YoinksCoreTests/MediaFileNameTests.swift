import Testing
@testable import YoinksCore

struct MediaFileNameTests {
    @Test func keepsAStoredFileNameIndependentOfTheSandboxLocation() throws {
        let fileName = try MediaFileName("recording-001.mp4")
        #expect(fileName.value == "recording-001.mp4")
    }

    @Test(arguments: ["", ".", "..", "../video.mp4", "/tmp/video.mp4", "folder/video.mp4", "folder\\video.mp4", "bad\0name"])
    func rejectsPathsAndInvalidComponents(_ value: String) {
        #expect(throws: MediaFileNameError.self) { try MediaFileName(value) }
    }
}
