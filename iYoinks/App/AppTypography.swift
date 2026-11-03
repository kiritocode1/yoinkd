import CoreText
import SwiftUI
import UIKit

@MainActor
enum AppTypography {
    private static var registered = false

    static func registerFonts() {
        guard !registered else { return }
        registered = true
        for family in ["StackSansText", "StackSansNotch"] {
            for weight in ["Regular", "Medium", "SemiBold", "Bold"] {
                let name = "\(family)-\(weight)"
                if let url = resourceBundle.url(forResource: name, withExtension: "ttf", subdirectory: "AppResources/Fonts") {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
    }

    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        registerFonts()
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline, .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }
        let name = face(heading: [.largeTitle, .title, .title2, .title3].contains(style), weight: weight)
        guard UIFont(name: name, size: size) != nil else { return .system(style, weight: weight) }
        return .custom(name, size: size, relativeTo: style)
    }

    static func nativeFont(for style: UIFont.TextStyle, weight: Font.Weight = .regular,
                           heading: Bool = false, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        registerFonts()
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let name = face(heading: heading, weight: weight)
        let fallbackWeight: UIFont.Weight
        switch weight {
        case .bold, .heavy, .black: fallbackWeight = .bold
        case .semibold: fallbackWeight = .semibold
        case .medium: fallbackWeight = .medium
        default: fallbackWeight = .regular
        }
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: fallbackWeight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }

    private static func face(heading: Bool, weight: Font.Weight) -> String {
        let suffix: String
        switch weight {
        case .bold, .heavy, .black: suffix = "Bold"
        case .semibold: suffix = "SemiBold"
        case .medium: suffix = "Medium"
        default: suffix = "Regular"
        }
        return "\(heading ? "StackSansNotch" : "StackSansText")-\(suffix)"
    }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
}
