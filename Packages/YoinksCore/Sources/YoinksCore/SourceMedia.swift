import Foundation

public struct SourceFormat: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let container: String
    public let videoCodec: String?
    public let audioCodec: String?
    public let width: Double?
    public let height: Double?
    public let fps: Double?
    public let audioBitrate: Double?
    public let bitrate: Double?
    public let byteCount: Int64?
    public let sizeIsEstimate: Bool
    public let rank: Int
    public let audioChannels: Double?
    public let language: String?

    public var containsVideo: Bool { videoCodec != nil && videoCodec != "none" }
    public var containsAudio: Bool { audioCodec != nil && audioCodec != "none" }
    public var resolution: Int? {
        guard let height, height > 0, height.isFinite else { return nil }
        let shortSide = width.map { min($0, height) } ?? height
        guard shortSide > 0, shortSide.isFinite, shortSide < Double(Int.max) else { return nil }
        return Int(shortSide.rounded())
    }

    public var qualityLabel: String {
        if containsVideo {
            guard let resolution else { return "Original" }
            let frameRate = fps.flatMap { $0.isFinite && $0 > 30 && $0 < 1_000 ? Int($0.rounded()) : nil }
            return "\(resolution)p" + (frameRate.map { " · \($0) fps" } ?? "")
        }
        return audioQualityLabel
    }

    public var audioQualityLabel: String {
        guard let rate = audioBitrate ?? (containsVideo ? nil : bitrate), rate.isFinite, rate > 0, rate < Double(Int.max) else { return "Original" }
        return "\(Int(rate.rounded())) kbps"
    }
}

public struct SourceMedia: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourceURL: URL
    public let title: String
    public let platform: String
    public let uploader: String?
    public let duration: Double?
    public let thumbnailURL: URL?
    public let formats: [SourceFormat]

    public var videoFormats: [SourceFormat] { formats.filter(\.containsVideo).sorted { $0.rank < $1.rank } }
    public var audioFormats: [SourceFormat] {
        let audioOnly = formats.filter { $0.containsAudio && !$0.containsVideo }
        return (audioOnly.isEmpty ? formats.filter(\.containsAudio) : audioOnly).sorted { $0.rank < $1.rank }
    }

    /// One source format per available resolution. Portrait labels use the shorter dimension.
    public var videoChoices: [SourceFormat] {
        let eligible = videoFormats.filter { $0.resolution.map { $0 >= 360 } ?? true }
        let candidates = eligible.isEmpty ? videoFormats : eligible
        var best: [Int: SourceFormat] = [:]
        for format in candidates { best[format.resolution ?? 0] = format }
        return best.values.sorted { ($0.resolution ?? 0) > ($1.resolution ?? 0) }
    }

    public var platformLabel: String {
        switch platform.lowercased() {
        case "youtube", "youtube:tab": "YouTube"
        case "twitter", "twittercard", "x": "X"
        case "instagram", "instagram:story": "Instagram"
        default: platform
        }
    }

    public func selection(kind: MediaKind, formatID: String?) throws -> SourceSelection {
        let available = kind == .video ? videoFormats : audioFormats
        let format = formatID.flatMap { id in available.first { $0.id == id } } ?? (formatID == nil ? available.last : nil)
        guard let format else { throw SourceMediaError.unavailableFormat }
        let quality = kind == .audio ? format.audioQualityLabel : format.qualityLabel
        return SourceSelection(kind: kind, formatID: formatID, quality: formatID == nil ? "Best available" : quality)
    }
}

public struct SourceSelection: Codable, Equatable, Sendable {
    public let kind: MediaKind
    public let formatID: String?
    public let quality: String

    public init(kind: MediaKind, formatID: String?, quality: String) {
        self.kind = kind
        self.formatID = formatID
        self.quality = quality
    }
}

public enum SourceMediaError: Error, LocalizedError {
    case unavailableFormat

    public var errorDescription: String? { "That quality is no longer available. Check the link again." }
}
