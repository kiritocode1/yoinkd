import Foundation
import Testing
@testable import YoinksCore

struct AccentThemeTests {
    @Test func allSixThemesPersistAcrossNewPreferencesInstances() throws {
        let suite = "iYoinks.ThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ThemePreferences(defaults: defaults)
        #expect(AccentTheme.allCases.count == 6)
        #expect(AccentTheme.allCases.map(\.rawValue) == ["neutral", "sage", "lavender", "amber", "ocean", "dynamic"])
        #expect(ThemePreferences.key == "accentTheme")
        #expect(preferences.theme == .sage)
        for theme in AccentTheme.allCases {
            preferences.theme = theme
            #expect(defaults.string(forKey: ThemePreferences.key) == theme.rawValue)
            let reopened = ThemePreferences(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(reopened.theme == theme)
            #expect(reopened.theme.palette.lightColors == theme.palette.lightColors)
            #expect(reopened.theme.palette.darkColors == theme.palette.darkColors)
        }
        defaults.set("unknown", forKey: ThemePreferences.key)
        #expect(preferences.theme == .sage)
    }

    @Test func curatedThemesHaveDistinctPalettesAndReadableAccents() {
        #expect(AccentTheme.dynamic.palette == .neutral)
        for theme in AccentTheme.allCases {
            #expect(theme.palette.light.contrast(with: .lightSurface) >= 4.5)
            #expect(theme.palette.dark.contrast(with: .darkSurface) >= 4.5)
            #expect(theme.palette.light.contrast(with: .white) >= 4.5)
            #expect(theme.palette.dark.contrast(with: .black) >= 4.5)
            expectReadable(theme.palette.lightColors, context: "\(theme.rawValue), light")
            expectReadable(theme.palette.darkColors, context: "\(theme.rawValue), dark")
        }
        let curated = AccentTheme.allCases.filter { $0 != .dynamic }
        for first in curated {
            for second in curated where first != second {
                #expect(first.palette != second.palette)
                for (firstColors, secondColors) in [
                    (first.palette.lightColors, second.palette.lightColors),
                    (first.palette.darkColors, second.palette.darkColors)
                ] {
                    for (firstColor, secondColor) in [
                        (firstColors.background, secondColors.background),
                        (firstColors.surface, secondColors.surface),
                        (firstColors.controlBackground, secondColors.controlBackground),
                        (firstColors.primaryText, secondColors.primaryText),
                        (firstColors.secondaryText, secondColors.secondaryText),
                        (firstColors.separator, secondColors.separator),
                        (firstColors.accent, secondColors.accent)
                    ] {
                        #expect(firstColor != secondColor)
                        #expect(eightBit(firstColor) != eightBit(secondColor))
                    }
                }
            }
        }
    }

    @Test func usefulSecondaryColourWinsOverDominantBlackAndWhite() {
        let pixels = repeated([0, 0, 0, 255], count: 800)
            + repeated([255, 255, 255, 255], count: 100)
            + repeated([45, 180, 155, 255], count: 100)
        let palette = MediaPaletteExtractor.extract(rgba: pixels)
        #expect(palette != .neutral)
        #expect(palette.dark.green > palette.dark.red)
        #expect(palette.dark.blue > palette.dark.red)
        #expect(palette.dark.contrast(with: .darkSurface) >= 4.5)
    }

    @Test(arguments: [
        [], [10, 20, 30],
        repeated([0, 0, 0, 255], count: 100),
        repeated([255, 255, 255, 255], count: 100),
        repeated([128, 128, 128, 255], count: 100),
        repeated([160, 164, 168, 255], count: 100),
        repeated([4, 12, 8, 255], count: 100),
        repeated([240, 250, 245, 255], count: 100),
        repeated([255, 0, 0, 0], count: 100),
        repeated([128, 0, 0, 128], count: 100),
        repeated([0, 0, 0, 255], count: 990) + repeated([255, 80, 40, 255], count: 10)
    ] as [[UInt8]])
    func unsuitableAndMalformedArtworkFallsBackToNeutral(_ fixture: [UInt8]) {
        #expect(MediaPaletteExtractor.extract(rgba: fixture) == .neutral)
    }

    @Test func brightArtworkIsMutedWithoutLosingItsHue() {
        let palette = MediaPaletteExtractor.extract(rgba: repeated([255, 25, 80, 255], count: 100))
        #expect(palette != .neutral)
        #expect(palette.dark.red > palette.dark.green)
        #expect(palette.dark.red > palette.dark.blue)
        let maximum = max(palette.dark.red, palette.dark.green, palette.dark.blue)
        let minimum = min(palette.dark.red, palette.dark.green, palette.dark.blue)
        let lightness = (maximum + minimum) / 2
        let saturation = (maximum - minimum) / (1 - abs(2 * lightness - 1))
        #expect(saturation <= 0.55 + 0.00001)
    }

    @Test func everyHueMeetsLightAndDarkContrastRequirements() {
        for degree in 0..<360 {
            for saturation in [0.0, 0.01, 0.14, 0.30, 0.55] {
                let palette = AccentPalette(hue: Double(degree) / 360, saturation: saturation)
                #expect(palette.light == palette.lightColors.accent)
                #expect(palette.dark == palette.darkColors.accent)
                #expect(palette.light.contrast(with: .lightSurface) >= 4.5)
                #expect(palette.dark.contrast(with: .darkSurface) >= 4.5)
                expectReadable(palette.lightColors, context: "hue \(degree), saturation \(saturation), light")
                expectReadable(palette.darkColors, context: "hue \(degree), saturation \(saturation), dark")
            }
        }
    }

    @Test func neutralFullPaletteUsesOnlyGreysAndDistinctSurfaceLevels() {
        let palette = AccentPalette.neutral
        for colors in [palette.lightColors, palette.darkColors] {
            for color in [
                colors.background, colors.surface, colors.controlBackground, colors.primaryText,
                colors.secondaryText, colors.separator, colors.accent, colors.onAccent
            ] {
                #expect(color.red == color.green)
                #expect(color.green == color.blue)
            }
            #expect(colors.background != colors.surface)
            #expect(colors.surface != colors.controlBackground)
            #expect(colors.background != colors.controlBackground)
            #expect(colors.primaryText != colors.secondaryText)
            expectReadable(colors, context: "neutral")
        }
        #expect(palette.lightColors.background.luminance > palette.darkColors.background.luminance)
        #expect(palette.lightColors.surface.luminance > palette.lightColors.background.luminance)
        #expect(palette.lightColors.background.luminance > palette.lightColors.controlBackground.luminance)
        #expect(palette.darkColors.surface.luminance > palette.darkColors.background.luminance)
        #expect(palette.darkColors.controlBackground.luminance > palette.darkColors.surface.luminance)
    }

    @Test(arguments: AccentTheme.allCases)
    func darkThemesKeepContentSurfacesNearBlack(_ theme: AccentTheme) {
        let colors = theme.palette.darkColors
        #expect(colors.background.luminance < 0.005)
        #expect(colors.surface.luminance < 0.012)
        #expect(colors.controlBackground.luminance < 0.022)
        expectReadable(colors, context: "near-black \(theme.name)")
    }

    // `select` and `accept` are mutating, so their results are bound before `#expect` captures them.
    @Test func dynamicFullPaletteFallsBackAndRecoversWithoutAcceptingStaleArtwork() {
        var selection = AccentSelection()
        #expect(selection.palette == AccentTheme.dynamic.palette)
        var accepted = selection.accept(AccentTheme.sage.palette, requestID: selection.requestID)
        #expect(!accepted)
        selection.select("artwork")
        let artworkRequest = selection.requestID
        let artwork = MediaPaletteExtractor.extract(rgba: repeated([55, 155, 185, 255], count: 100))
        accepted = selection.accept(artwork, requestID: artworkRequest)
        #expect(accepted)
        #expect(selection.palette.lightColors.background != AccentPalette.neutral.lightColors.background)
        #expect(selection.palette.darkColors.surface != AccentPalette.neutral.darkColors.surface)
        selection.select(nil)
        #expect(selection.palette == .neutral)
        accepted = selection.accept(artwork, requestID: artworkRequest)
        #expect(!accepted)
        selection.select("unsuitable")
        let unsuitable = MediaPaletteExtractor.extract(rgba: repeated([128, 128, 128, 255], count: 100))
        accepted = selection.accept(unsuitable, requestID: selection.requestID)
        #expect(accepted)
        #expect(selection.palette.lightColors == AccentPalette.neutral.lightColors)
        #expect(selection.palette.darkColors == AccentPalette.neutral.darkColors)
        selection.select("artwork")
        accepted = selection.accept(artwork, requestID: artworkRequest)
        #expect(!accepted)
        accepted = selection.accept(artwork, requestID: selection.requestID)
        #expect(accepted)
        #expect(selection.palette == artwork)
    }

    @Test func paletteExtractionDoesNotDependOnPixelOrder() {
        let first = repeated([55, 155, 185, 255], count: 60)
        let second = repeated([195, 70, 100, 255], count: 60)
        #expect(MediaPaletteExtractor.extract(rgba: first + second) == MediaPaletteExtractor.extract(rgba: second + first))
    }

    @Test func sameSelectionDoesNotRestartExtractionAndStaleResultsCannotReplaceNewMedia() {
        var selection = AccentSelection()
        #expect(selection.palette == .neutral)
        var changed = selection.select("first")
        #expect(changed)
        let firstRequest = selection.requestID
        changed = selection.select("first")
        #expect(!changed)
        #expect(selection.requestID == firstRequest)
        var accepted = selection.accept(AccentTheme.sage.palette, requestID: firstRequest)
        #expect(accepted)
        changed = selection.select("second")
        #expect(changed)
        #expect(selection.palette == .neutral)
        accepted = selection.accept(AccentTheme.amber.palette, requestID: firstRequest)
        #expect(!accepted)
        accepted = selection.accept(AccentTheme.ocean.palette, requestID: selection.requestID)
        #expect(accepted)
        #expect(selection.palette == AccentTheme.ocean.palette)
        let secondRequest = selection.requestID
        changed = selection.select(nil)
        #expect(changed)
        #expect(selection.palette == .neutral)
        accepted = selection.accept(AccentTheme.sage.palette, requestID: secondRequest)
        #expect(!accepted)
    }

    @Test func invalidChannelsAndPaletteInputsStayFinite() {
        let invalid = AccentRGB(red: .nan, green: .infinity, blue: -1)
        #expect(invalid == .black)
        #expect(AccentPalette(hue: .nan, saturation: .infinity) == .neutral)
    }

    @Test func reselectingMediaRejectsTheEarlierRequestForTheSameKey() {
        var selection = AccentSelection()
        selection.select("first")
        let earlierRequest = selection.requestID
        selection.select("second")
        selection.select("first")
        #expect(selection.requestID != earlierRequest)
        var accepted = selection.accept(AccentTheme.amber.palette, requestID: earlierRequest)
        #expect(!accepted)
        #expect(selection.palette == .neutral)
        accepted = selection.accept(AccentTheme.ocean.palette, requestID: selection.requestID)
        #expect(accepted)
        #expect(selection.palette == AccentTheme.ocean.palette)
    }

    @Test func premultipliedArtworkPreservesItsAccentHue() {
        let opaque = MediaPaletteExtractor.extract(rgba: repeated([40, 180, 140, 255], count: 100))
        let translucent = MediaPaletteExtractor.extract(rgba: repeated([32, 144, 112, 204], count: 100))
        #expect(opaque != .neutral)
        for (first, second) in [(opaque.dark, translucent.dark), (opaque.light, translucent.light)] {
            #expect(abs(first.red - second.red) <= 0.000001)
            #expect(abs(first.green - second.green) <= 0.000001)
            #expect(abs(first.blue - second.blue) <= 0.000001)
        }
    }

    private func expectReadable(_ colors: AccentColors, context: String,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        for (backgroundName, background) in [
            ("background", colors.background), ("surface", colors.surface), ("control", colors.controlBackground)
        ] {
            for (textName, text) in [
                ("primary", colors.primaryText), ("secondary", colors.secondaryText), ("accent", colors.accent)
            ] {
                #expect(text.contrast(with: background) >= 4.5, "\(context), \(textName) on \(backgroundName)",
                        sourceLocation: sourceLocation)
            }
        }
        #expect(colors.onAccent.contrast(with: colors.accent) >= 4.5, "\(context)", sourceLocation: sourceLocation)
    }
}

private func repeated(_ pixel: [UInt8], count: Int) -> [UInt8] {
    Array(repeating: pixel, count: count).flatMap { $0 }
}

/// The colour as it would be stored in an 8-bit sRGB asset.
private func eightBit(_ color: AccentRGB) -> [Int] {
    [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
}
