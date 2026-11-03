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
    public let audioSampleRate: Double?
    public let videoBitrate: Double?
    public let dynamicRange: String?
    public let formatNote: String?
    public let protocolName: String?

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

    public func downloadSize(duration: Double?) -> SourceDownloadSize? {
        if let byteCount, byteCount > 0 {
            return SourceDownloadSize(byteCount: byteCount, isEstimate: sizeIsEstimate)
        }
        guard let duration, duration.isFinite, duration > 0,
              let rate = bitrate, rate.isFinite, rate > 0 else { return nil }
        let bytes = duration * rate * 125
        guard bytes.isFinite, bytes >= 1, bytes < Double(Int64.max) else { return nil }
        return SourceDownloadSize(byteCount: Int64(bytes.rounded()), isEstimate: true)
    }
}

public struct SourceDownloadSize: Equatable, Sendable {
    public let byteCount: Int64
    public let isEstimate: Bool

    public init(byteCount: Int64, isEstimate: Bool) {
        self.byteCount = byteCount
        self.isEstimate = isEstimate
    }
}

public enum SourceOutputFormat: String, Codable, CaseIterable, Sendable {
    case automatic, mp4, mov, m4a, aac, mp3, flac, alac, wav, aiff, caf

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .m4a: "M4A · AAC"
        case .alac: "M4A · Apple Lossless"
        default: rawValue.uppercased()
        }
    }

    public func supports(_ kind: MediaKind) -> Bool {
        if self == .automatic { return true }
        return kind == .video ? self == .mp4 || self == .mov : self != .mp4 && self != .mov
    }

    public var requiredEncoder: String? {
        switch self {
        case .automatic, .mp4, .mov: nil
        case .m4a, .aac: "aac"
        case .mp3: "libmp3lame"
        case .flac: "flac"
        case .alac: "alac"
        case .wav, .caf: "pcm_s16le"
        case .aiff: "pcm_s16be"
        }
    }

    public var requiredMuxer: String? {
        switch self {
        case .automatic: nil
        case .mp4: "mp4"
        case .mov: "mov"
        case .m4a, .alac: "ipod"
        case .aac: "adts"
        default: rawValue
        }
    }
}

public struct SourceOutputSupport: Sendable {
    public let encoders: Set<String>
    public let muxers: Set<String>

    public init(encodersListing: String, muxersListing: String) {
        encoders = Set(encodersListing.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0].count == 6,
                  ["A", "V", "S"].contains(String(parts[0].prefix(1))), parts[1] != "=" else { return nil }
            return String(parts[1])
        })
        muxers = Set(muxersListing.split(separator: "\n").flatMap { line -> [String] in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0].count <= 3,
                  parts[0].contains("E"), parts[1] != "=" else { return [] }
            return parts[1].split(separator: ",").map(String.init)
        })
    }

    public func availableFormats(for kind: MediaKind) -> [SourceOutputFormat] {
        SourceOutputFormat.allCases.filter { format in
            format.supports(kind) && format.requiredEncoder.map(encoders.contains) != false &&
                format.requiredMuxer.map(muxers.contains) != false
        }
    }
}

public struct SourceMedia: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourceURL: URL
    public let title: String
    public let platform: String
    public let uploader: String?
    public let artist: String?
    public let duration: Double?
    public let thumbnailURL: URL?
    public let formats: [SourceFormat]

    public var videoFormats: [SourceFormat] { formats.filter(\.containsVideo).sorted { $0.rank < $1.rank } }
    public var audioFormats: [SourceFormat] { formats.filter(\.containsAudio).sorted { $0.rank < $1.rank } }

    public var videoChoices: [SourceFormat] { Array(videoFormats.reversed()) }

    public var audioChoices: [SourceFormat] {
        audioFormats.sorted {
            if $0.containsVideo != $1.containsVideo { return !$0.containsVideo }
            return $0.rank > $1.rank
        }
    }

    public func bestFormat(for kind: MediaKind) -> SourceFormat? {
        if kind == .video { return videoFormats.last }
        return audioFormats.last(where: { !$0.containsVideo }) ?? audioFormats.last
    }

    public func selectedFormats(kind: MediaKind, formatID: String?) throws -> [SourceFormat] {
        let available = kind == .video ? videoFormats : audioFormats
        let selected = formatID.flatMap { identifier in available.first { $0.id == identifier } } ??
            (formatID == nil ? bestFormat(for: kind) : nil)
        guard let selected else { throw SourceMediaError.unavailableFormat }
        if kind == .video, !selected.containsAudio,
           let audio = audioFormats.last(where: { !$0.containsVideo }) { return [selected, audio] }
        return [selected]
    }

    public func downloadSize(kind: MediaKind, formatID: String?) -> SourceDownloadSize? {
        guard let selected = try? selectedFormats(kind: kind, formatID: formatID) else { return nil }
        var total: Int64 = 0
        var isEstimate = false
        for format in selected {
            guard let size = format.downloadSize(duration: duration) else { return nil }
            let sum = total.addingReportingOverflow(size.byteCount)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
            isEstimate = isEstimate || size.isEstimate
        }
        return SourceDownloadSize(byteCount: total, isEstimate: isEstimate)
    }

    public var platformLabel: String {
        switch platform.lowercased() {
        case "youtube", "youtube:tab": "YouTube"
        case "twitter", "twittercard", "x": "X"
        case "instagram", "instagram:story": "Instagram"
        default: platform
        }
    }

    public func selection(kind: MediaKind, formatID: String?, outputFormat: SourceOutputFormat? = nil) throws -> SourceSelection {
        guard outputFormat?.supports(kind) != false else { throw SourceMediaError.unavailableOutput }
        guard let format = try selectedFormats(kind: kind, formatID: formatID).first else { throw SourceMediaError.unavailableFormat }
        let quality = kind == .audio ? format.audioQualityLabel : format.qualityLabel
        return SourceSelection(kind: kind, formatID: formatID, quality: formatID == nil ? "Best available" : quality, outputFormat: outputFormat)
    }
}

public struct SourceSelection: Codable, Equatable, Sendable {
    public let kind: MediaKind
    public let formatID: String?
    public let quality: String
    public let outputFormat: SourceOutputFormat?

    public init(kind: MediaKind, formatID: String?, quality: String, outputFormat: SourceOutputFormat? = nil) {
        self.kind = kind
        self.formatID = formatID
        self.quality = quality
        self.outputFormat = outputFormat
    }
}

public enum SourceMediaError: Error, LocalizedError {
    case unavailableFormat
    case unavailableOutput

    public var errorDescription: String? {
        switch self {
        case .unavailableFormat: "That quality is no longer available. Check the link again."
        case .unavailableOutput: "That file format isn't available for this media. Choose another format."
        }
    }
}
