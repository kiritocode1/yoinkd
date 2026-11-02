import Foundation

/// A single filename relative to the app's media directory, never a sandbox path.
public struct MediaFileName: Hashable, Codable, Sendable {
    public let value: String

    public init(_ value: String) throws(MediaFileNameError) {
        guard !value.isEmpty else { throw .empty }
        guard value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
            throw .invalidComponent
        }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid relative filename")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum MediaFileNameError: Error, Equatable, Sendable {
    case empty
    case invalidComponent
}
