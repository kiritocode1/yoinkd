import SwiftUI

@MainActor
enum AppBrand {
    static let image: Image = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let url = bundle.url(forResource: "BrandMark", withExtension: "png", subdirectory: "Resources"),
           let image = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: image)
        }
        return Image(systemName: "arrow.down.circle")
    }()
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            AppBrand.image.resizable().scaledToFit().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("iYoinks").font(.system(.headline, design: .rounded))
        }
        .accessibilityElement(children: .combine)
    }
}

struct ScreenHeading: View {
    let title: String
    var summary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if let summary { Text(summary).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
