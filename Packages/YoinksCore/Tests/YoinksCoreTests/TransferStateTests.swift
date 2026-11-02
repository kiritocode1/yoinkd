import XCTest
@testable import YoinksCore

final class TransferStateTests: XCTestCase {
    func testReceivingAllBytesDoesNotCompleteTheJob() throws {
        let progress = try TransferProgress(receivedBytes: 100, expectedBytes: 100)
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertFalse(TransferState.transferring(progress).isTerminal)
        XCTAssertFalse(TransferState.processing.isTerminal)
        XCTAssertFalse(TransferState.saving.isTerminal)

        let file = try MediaFileName("saved-video.mp4")
        XCTAssertTrue(TransferState.completed(file).isTerminal)
    }

    func testUnknownLengthDoesNotInventACompletionPercentage() throws {
        let progress = try TransferProgress(receivedBytes: 500)
        XCTAssertNil(progress.fractionCompleted)
    }

    func testProgressCannotExceedOneWhenAnEstimateIsTooSmall() throws {
        let progress = try TransferProgress(receivedBytes: 120, expectedBytes: 100)
        XCTAssertEqual(progress.fractionCompleted, 1)
    }

    func testRejectsInvalidByteCounts() {
        XCTAssertThrowsError(try TransferProgress(receivedBytes: -1))
        XCTAssertThrowsError(try TransferProgress(receivedBytes: 0, expectedBytes: 0))
        XCTAssertThrowsError(try TransferProgress(receivedBytes: 0, expectedBytes: -1))
    }
}
