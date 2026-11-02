import CoreGraphics
import Foundation
import ImageIO
import YoinksCore

actor ArtworkPaletteCache {
    private var palettes: [String: AccentPalette] = [:]
    private var accessOrder: [String] = []
    private let capacity = 64

    func cachedPalette(for key: String) -> AccentPalette? {
        guard let palette = palettes[key] else { return nil }
        touch(key)
        return palette
    }

    func palette(for data: Data?, key: String) -> AccentPalette {
        if let cached = cachedPalette(for: key) { return cached }
        guard let data else { return .neutral }
        let palette = Self.extract(data)
        palettes[key] = palette
        touch(key)
        if accessOrder.count > capacity {
            palettes.removeValue(forKey: accessOrder.removeFirst())
        }
        return palette
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private static func extract(_ data: Data) -> AccentPalette {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 48,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return .neutral }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? MediaPaletteExtractor.extract(rgba: pixels) : .neutral
    }
}
