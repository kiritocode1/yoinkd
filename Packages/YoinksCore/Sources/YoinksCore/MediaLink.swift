import Foundation

/// Validates an input address. Resolving downloadable media is a separate step.
public struct MediaLink: Hashable, Sendable {
    public let url: URL

    public init(_ input: String) throws(MediaLinkError) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: text, encodingInvalidCharacters: false) else {
            throw .invalidURL
        }
        guard url.scheme?.lowercased() == "https" else { throw .httpsRequired }
        guard let host = url.host, !host.isEmpty else { throw .invalidURL }
        guard url.user == nil, url.password == nil else { throw .credentialsNotAllowed }
        self.url = url
    }
}

public enum MediaLinkError: Error, Equatable, Sendable {
    case empty
    case invalidURL
    case httpsRequired
    case credentialsNotAllowed
}
