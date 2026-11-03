import SwiftUI

@MainActor
enum AppBrand {
    static let image = loadImage(named: "BrandMark") ?? Image(systemName: "arrow.down.circle")
    private static let lightImage = loadImage(named: "BrandMarkLight") ?? image

    static func image(for scheme: ColorScheme) -> Image {
        scheme == .light ? lightImage : image
    }

    private static func loadImage(named name: String) -> Image? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
           let image = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: image)
        }
        return nil
    }
}

struct BrandHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            AppBrand.image(for: colorScheme).resizable().scaledToFit().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("yoink'd").font(AppTypography.font(.headline, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
