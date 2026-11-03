import Foundation

public struct AccentRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red.isFinite ? min(1, max(0, red)) : 0
        self.green = green.isFinite ? min(1, max(0, green)) : 0
        self.blue = blue.isFinite ? min(1, max(0, blue)) : 0
    }

    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: AccentRGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    public static let white = AccentRGB(red: 1, green: 1, blue: 1)
    public static let black = AccentRGB(red: 0, green: 0, blue: 0)
    public static let darkSurface = AccentRGB(red: 0.16, green: 0.16, blue: 0.16)
    public static let lightSurface = AccentRGB(red: 0.94, green: 0.94, blue: 0.94)

    fileprivate var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        let sector: Double
        if maximum == red { sector = (green - blue) / delta + (green < blue ? 6 : 0) }
        else if maximum == green { sector = (blue - red) / delta + 2 }
        else { sector = (red - green) / delta + 4 }
        return (sector / 6, saturation, lightness)
    }

    fileprivate init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue * 6
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = lightness - chroma / 2
        let channels: (Double, Double, Double)
        switch sector {
        case ..<1: channels = (chroma, secondary, 0)
        case ..<2: channels = (secondary, chroma, 0)
        case ..<3: channels = (0, chroma, secondary)
        case ..<4: channels = (0, secondary, chroma)
        case ..<5: channels = (secondary, 0, chroma)
        default: channels = (chroma, 0, secondary)
        }
        self.init(red: channels.0 + offset, green: channels.1 + offset, blue: channels.2 + offset)
    }
}

public struct AccentColors: Equatable, Sendable {
    public let background: AccentRGB
    public let surface: AccentRGB
    public let controlBackground: AccentRGB
    public let primaryText: AccentRGB
    public let secondaryText: AccentRGB
    public let separator: AccentRGB
    public let accent: AccentRGB
    public let onAccent: AccentRGB

    fileprivate init(hue: Double, saturation: Double, isDark: Bool) {
        let background = AccentRGB(hue: hue, saturation: saturation * 0.40, lightness: isDark ? 0.035 : 0.95)
        let surface = AccentRGB(hue: hue, saturation: saturation * (isDark ? 0.22 : 0.35), lightness: isDark ? 0.07 : 0.98)
        let controlBackground = AccentRGB(hue: hue, saturation: saturation * (isDark ? 0.20 : 0.36), lightness: isDark ? 0.11 : 0.92)
        let backgrounds = [background, surface, controlBackground, isDark ? AccentRGB.darkSurface : .lightSurface]

        func readableColor(lightness: Double, saturation: Double) -> AccentRGB {
            var adjustedLightness = lightness
            var color = AccentRGB(hue: hue, saturation: saturation, lightness: adjustedLightness)
            while backgrounds.contains(where: { color.contrast(with: $0) < 4.5 }),
                  isDark ? adjustedLightness < 1 : adjustedLightness > 0 {
                adjustedLightness = isDark ? min(1, adjustedLightness + 0.01) : max(0, adjustedLightness - 0.01)
                color = AccentRGB(hue: hue, saturation: saturation, lightness: adjustedLightness)
            }
            return color
        }

        self.background = background
        self.surface = surface
        self.controlBackground = controlBackground
        primaryText = readableColor(lightness: isDark ? 0.94 : 0.14, saturation: saturation * 0.20)
        secondaryText = readableColor(lightness: isDark ? 0.68 : 0.40, saturation: saturation * 0.16)
        separator = AccentRGB(hue: hue, saturation: saturation * 0.20, lightness: isDark ? 0.22 : 0.80)
        accent = readableColor(lightness: isDark ? 0.68 : 0.38, saturation: saturation)
        onAccent = accent.contrast(with: .white) >= 4.5 ? .white : .black
    }
}

public struct AccentPalette: Equatable, Sendable {
    public let lightColors: AccentColors
    public let darkColors: AccentColors

    public var light: AccentRGB { lightColors.accent }
    public var dark: AccentRGB { darkColors.accent }

    public static let neutral = AccentPalette(hue: 0, saturation: 0)

    public init(hue: Double, saturation: Double) {
        let safeHue = hue.isFinite ? hue - floor(hue) : 0
        let safeSaturation = saturation.isFinite ? min(0.55, max(0, saturation)) : 0
        lightColors = AccentColors(hue: safeHue, saturation: safeSaturation, isDark: false)
        darkColors = AccentColors(hue: safeHue, saturation: safeSaturation, isDark: true)
    }
}

public enum MediaPaletteExtractor {
    public static func extract(rgba: [UInt8]) -> AccentPalette {
        guard !rgba.isEmpty, rgba.count.isMultiple(of: 4) else { return .neutral }
        var clusters: [Int: Cluster] = [:]
        var visiblePixels = 0
        var usefulPixels = 0
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Double(rgba[offset + 3]) / 255
            guard alpha >= 0.75 else { continue }
            visiblePixels += 1
            let color = AccentRGB(
                red: Double(rgba[offset]) / 255 / alpha,
                green: Double(rgba[offset + 1]) / 255 / alpha,
                blue: Double(rgba[offset + 2]) / 255 / alpha
            )
            let hsl = color.hsl
            guard hsl.saturation >= 0.14, hsl.lightness >= 0.12, hsl.lightness <= 0.88,
                  color.luminance >= 0.025, color.luminance <= 0.85 else { continue }
            usefulPixels += 1
            let key = Int(color.red * 15) << 8 | Int(color.green * 15) << 4 | Int(color.blue * 15)
            var cluster = clusters[key, default: Cluster()]
            cluster.red += color.red
            cluster.green += color.green
            cluster.blue += color.blue
            cluster.count += 1
            clusters[key] = cluster
        }
        guard visiblePixels > 0, Double(usefulPixels) / Double(visiblePixels) >= 0.025 else { return .neutral }
        let minimumCount = max(2, Int(Double(visiblePixels) * 0.004))
        let candidates = clusters.sorted { $0.key < $1.key }.compactMap { entry -> (AccentRGB, Double)? in
            let cluster = entry.value
            guard cluster.count >= minimumCount else { return nil }
            let color = AccentRGB(
                red: cluster.red / Double(cluster.count),
                green: cluster.green / Double(cluster.count),
                blue: cluster.blue / Double(cluster.count)
            )
            let hsl = color.hsl
            let saturationFit = 1 - abs(hsl.saturation - 0.55) * 0.6
            let lightnessFit = 1 - abs(hsl.lightness - 0.5)
            let score = sqrt(Double(cluster.count)) * saturationFit * lightnessFit
            return (color, score)
        }
        guard let selected = candidates.max(by: { $0.1 < $1.1 })?.0 else { return .neutral }
        return AccentPalette(hue: selected.hsl.hue, saturation: min(0.55, max(0.26, selected.hsl.saturation)))
    }

    private struct Cluster {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0
    }
}
