import SwiftUI
import UIKit

struct SortIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        for (start, end, row) in [(1.0, 23.0, 6.0), (3.5, 20.5, 12.0), (6.5, 17.5, 18.0)] {
            path.move(to: CGPoint(x: origin.x + start * scale, y: origin.y + row * scale))
            path.addLine(to: CGPoint(x: origin.x + end * scale, y: origin.y + row * scale))
        }
        return path
    }
}

@MainActor
enum AppPlatformArtwork {
    private static var images: [String: UIImage] = [:]

    static func image(named name: String) -> UIImage? {
        if let cached = images[name] { return cached }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "pdf", subdirectory: "Resources/PlatformLogos"),
              let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { return nil }
        let bounds = page.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: 0, y: 32)
            context.scaleBy(x: 32 / bounds.width, y: -32 / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawPDFPage(page)
        }.withRenderingMode(.alwaysTemplate)
        images[name] = image
        return image
    }
}
