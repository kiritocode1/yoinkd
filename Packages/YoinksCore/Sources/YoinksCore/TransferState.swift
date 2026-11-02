public struct TransferProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64? = nil) throws(TransferProgressError) {
        guard receivedBytes >= 0 else { throw .invalidReceivedBytes }
        if let expectedBytes, expectedBytes <= 0 { throw .invalidExpectedBytes }
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    public var fractionCompleted: Double? {
        guard let expectedBytes else { return nil }
        return min(Double(receivedBytes) / Double(expectedBytes), 1)
    }
}

public enum TransferProgressError: Error, Equatable, Sendable {
    case invalidReceivedBytes
    case invalidExpectedBytes
}

/// Completing a transfer still requires processing, file storage, and metadata saving.
public enum TransferState: Equatable, Sendable {
    case queued
    case resolving
    case transferring(TransferProgress)
    case processing
    case saving
    case completed(MediaFileName)
    case failed(message: String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .resolving, .transferring, .processing, .saving: false
        }
    }
}
