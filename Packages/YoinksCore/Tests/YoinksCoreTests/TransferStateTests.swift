import Testing
@testable import YoinksCore

struct TransferStateTests {
    @Test func receivingAllBytesDoesNotCompleteTheJob() throws {
        let progress = try TransferProgress(receivedBytes: 100, expectedBytes: 100)
        #expect(progress.fractionCompleted == 1)
        #expect(!TransferState.transferring(progress).isTerminal)
        #expect(!TransferState.processing.isTerminal)
        #expect(!TransferState.saving.isTerminal)

        let file = try MediaFileName("saved-video.mp4")
        #expect(TransferState.completed(file).isTerminal)
    }

    @Test func unknownLengthDoesNotInventACompletionPercentage() throws {
        let progress = try TransferProgress(receivedBytes: 500)
        #expect(progress.fractionCompleted == nil)
    }

    @Test func progressCannotExceedOneWhenAnEstimateIsTooSmall() throws {
        let progress = try TransferProgress(receivedBytes: 120, expectedBytes: 100)
        #expect(progress.fractionCompleted == 1)
    }

    @Test func rejectsInvalidByteCounts() {
        #expect(throws: TransferProgressError.invalidReceivedBytes) { try TransferProgress(receivedBytes: -1) }
        #expect(throws: TransferProgressError.invalidExpectedBytes) { try TransferProgress(receivedBytes: 0, expectedBytes: 0) }
        #expect(throws: TransferProgressError.invalidExpectedBytes) { try TransferProgress(receivedBytes: 0, expectedBytes: -1) }
    }
}
