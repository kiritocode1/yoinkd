import Foundation

/// Opens the yoink! sheet, optionally with a link and media kind filled in.
///
/// Built from `yoinkd://add?url=<percent-encoded link>&kind=audio&id=<uuid>`, by the share extension,
/// or by the in-app add buttons. It never starts a download: the sheet still checks the link, and the
/// user confirms it. The link is kept as typed and validated by `MediaLink` when the user acts, so a
/// bad link shows the sheet's usual error instead of being dropped. `id` matches the request's
/// `CaptureInbox` file when the share extension saved one.
public struct CaptureRequest: Codable, Hashable, Identifiable, Sendable {
    public static let scheme = "yoinkd"

    /// Each request is distinct, so the same link opened twice presents the sheet again.
    public let id: UUID
    public let link: String
    public let kind: MediaKind?

    public init(id: UUID = UUID(), link: String = "", kind: MediaKind? = nil) {
        self.id = id
        self.link = link
        self.kind = kind
    }

    /// Returns nil for URLs that are not `yoinkd://add`. An unknown `kind` or malformed `id` is ignored.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "add",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        self.init(id: value("id").flatMap(UUID.init(uuidString:)) ?? UUID(),
                  link: (value("url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                  kind: value("kind").flatMap { MediaKind(rawValue: $0.lowercased()) })
    }

    /// The `yoinkd://add` URL that recreates this request, with every query value fully encoded.
    public var url: URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var query = ["url=" + encode(link), "id=" + id.uuidString]
        if let kind { query.append("kind=" + kind.rawValue) }
        return URL(string: "\(Self.scheme)://add?" + query.joined(separator: "&"))!
    }
}
