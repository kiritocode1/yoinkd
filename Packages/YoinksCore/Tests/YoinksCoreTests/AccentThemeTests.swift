import XCTest
@testable import YoinksCore

final class AccentThemeTests: XCTestCase {
    func testAllSixThemesPersistAcrossNewPreferencesInstances() throws {
        let suite = "iYoinks.ThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ThemePreferences(defaults: defaults)
        XCTAssertEqual(AccentTheme.allCases.count, 6)
        XCTAssertEqual(AccentTheme.allCases.map(\.rawValue), ["neutral", "sage", "lavender", "amber", "ocean", "dynamic"])
        XCTAssertEqual(ThemePreferences.key, "accentTheme")
        XCTAssertEqual(preferences.theme, .sage)
        for theme in AccentTheme.allCases {
            preferences.theme = theme
            XCTAssertEqual(defaults.string(forKey: ThemePreferences.key), theme.rawValue)
            let reopened = ThemePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.theme, theme)
            XCTAssertEqual(reopened.theme.palette.lightColors, theme.palette.lightColors)
            XCTAssertEqual(reopened.theme.palette.darkColors, theme.palette.darkColors)
        }
        defaults.set("unknown", forKey: ThemePreferences.key)
        XCTAssertEqual(preferences.theme, .sage)
    }

    func testCuratedThemesHaveDistinctPalettesAndReadableAccents() {
        XCTAssertEqual(AccentTheme.dynamic.palette, .neutral)
        for theme in AccentTheme.allCases {
            XCTAssertGreaterThanOrEqual(theme.palette.light.contrast(with: .lightSurface), 4.5)
            XCTAssertGreaterThanOrEqual(theme.palette.dark.contrast(with: .darkSurface), 4.5)
            XCTAssertGreaterThanOrEqual(theme.palette.light.contrast(with: .white), 4.5)
            XCTAssertGreaterThanOrEqual(theme.palette.dark.contrast(with: .black), 4.5)
            assertReadable(theme.palette.lightColors, context: "\(theme.rawValue), light")
            assertReadable(theme.palette.darkColors, context: "\(theme.rawValue), dark")
        }
        let curated = AccentTheme.allCases.filter { $0 != .dynamic }
        for first in curated {
            for second in curated where first != second {
                XCTAssertNotEqual(first.palette, second.palette)
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
                        XCTAssertNotEqual(firstColor, secondColor)
                        XCTAssertNotEqual(
                            [firstColor.red, firstColor.green, firstColor.blue].map { Int(($0 * 255).rounded()) },
                            [secondColor.red, secondColor.green, secondColor.blue].map { Int(($0 * 255).rounded()) }
                        )
                    }
                }
            }
        }
    }

    func testUsefulSecondaryColourWinsOverDominantBlackAndWhite() {
        let pixels = repeated([0, 0, 0, 255], count: 800)
            + repeated([255, 255, 255, 255], count: 100)
            + repeated([45, 180, 155, 255], count: 100)
        let palette = MediaPaletteExtractor.extract(rgba: pixels)
        XCTAssertNotEqual(palette, .neutral)
        XCTAssertGreaterThan(palette.dark.green, palette.dark.red)
        XCTAssertGreaterThan(palette.dark.blue, palette.dark.red)
        XCTAssertGreaterThanOrEqual(palette.dark.contrast(with: .darkSurface), 4.5)
    }

    func testUnsuitableAndMalformedArtworkFallsBackToNeutral() {
        let fixtures: [[UInt8]] = [
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
        ]
        for fixture in fixtures { XCTAssertEqual(MediaPaletteExtractor.extract(rgba: fixture), .neutral) }
    }

    func testBrightArtworkIsMutedWithoutLosingItsHue() {
        let palette = MediaPaletteExtractor.extract(rgba: repeated([255, 25, 80, 255], count: 100))
        XCTAssertNotEqual(palette, .neutral)
        XCTAssertGreaterThan(palette.dark.red, palette.dark.green)
        XCTAssertGreaterThan(palette.dark.red, palette.dark.blue)
        let maximum = max(palette.dark.red, palette.dark.green, palette.dark.blue)
        let minimum = min(palette.dark.red, palette.dark.green, palette.dark.blue)
        let lightness = (maximum + minimum) / 2
        let saturation = (maximum - minimum) / (1 - abs(2 * lightness - 1))
        XCTAssertLessThanOrEqual(saturation, 0.55 + 0.00001)
    }

    func testEveryHueMeetsLightAndDarkContrastRequirements() {
        for degree in 0..<360 {
            for saturation in [0.0, 0.01, 0.14, 0.30, 0.55] {
                let palette = AccentPalette(hue: Double(degree) / 360, saturation: saturation)
                XCTAssertEqual(palette.light, palette.lightColors.accent)
                XCTAssertEqual(palette.dark, palette.darkColors.accent)
                XCTAssertGreaterThanOrEqual(palette.light.contrast(with: .lightSurface), 4.5)
                XCTAssertGreaterThanOrEqual(palette.dark.contrast(with: .darkSurface), 4.5)
                assertReadable(palette.lightColors, context: "hue \(degree), saturation \(saturation), light")
                assertReadable(palette.darkColors, context: "hue \(degree), saturation \(saturation), dark")
            }
        }
    }

    func testNeutralFullPaletteUsesOnlyGreysAndDistinctSurfaceLevels() {
        let palette = AccentPalette.neutral
        for colors in [palette.lightColors, palette.darkColors] {
            for color in [
                colors.background, colors.surface, colors.controlBackground, colors.primaryText,
                colors.secondaryText, colors.separator, colors.accent, colors.onAccent
            ] {
                XCTAssertEqual(color.red, color.green)
                XCTAssertEqual(color.green, color.blue)
            }
            XCTAssertNotEqual(colors.background, colors.surface)
            XCTAssertNotEqual(colors.surface, colors.controlBackground)
            XCTAssertNotEqual(colors.background, colors.controlBackground)
            XCTAssertNotEqual(colors.primaryText, colors.secondaryText)
            assertReadable(colors, context: "neutral")
        }
        XCTAssertGreaterThan(palette.lightColors.background.luminance, palette.darkColors.background.luminance)
        XCTAssertGreaterThan(palette.lightColors.surface.luminance, palette.lightColors.background.luminance)
        XCTAssertGreaterThan(palette.lightColors.background.luminance, palette.lightColors.controlBackground.luminance)
        XCTAssertGreaterThan(palette.darkColors.surface.luminance, palette.darkColors.background.luminance)
        XCTAssertGreaterThan(palette.darkColors.controlBackground.luminance, palette.darkColors.surface.luminance)
    }

    func testDarkThemesKeepContentSurfacesNearBlack() {
        for theme in AccentTheme.allCases {
            let colors = theme.palette.darkColors
            XCTAssertLessThan(colors.background.luminance, 0.005, theme.name)
            XCTAssertLessThan(colors.surface.luminance, 0.012, theme.name)
            XCTAssertLessThan(colors.controlBackground.luminance, 0.022, theme.name)
            assertReadable(colors, context: "near-black \(theme.name)")
        }
    }

    func testDynamicFullPaletteFallsBackAndRecoversWithoutAcceptingStaleArtwork() {
        var selection = AccentSelection()
        XCTAssertEqual(selection.palette, AccentTheme.dynamic.palette)
        XCTAssertFalse(selection.accept(AccentTheme.sage.palette, requestID: selection.requestID))
        selection.select("artwork")
        let artworkRequest = selection.requestID
        let artwork = MediaPaletteExtractor.extract(rgba: repeated([55, 155, 185, 255], count: 100))
        XCTAssertTrue(selection.accept(artwork, requestID: artworkRequest))
        XCTAssertNotEqual(selection.palette.lightColors.background, AccentPalette.neutral.lightColors.background)
        XCTAssertNotEqual(selection.palette.darkColors.surface, AccentPalette.neutral.darkColors.surface)
        selection.select(nil)
        XCTAssertEqual(selection.palette, .neutral)
        XCTAssertFalse(selection.accept(artwork, requestID: artworkRequest))
        selection.select("unsuitable")
        let unsuitable = MediaPaletteExtractor.extract(rgba: repeated([128, 128, 128, 255], count: 100))
        XCTAssertTrue(selection.accept(unsuitable, requestID: selection.requestID))
        XCTAssertEqual(selection.palette.lightColors, AccentPalette.neutral.lightColors)
        XCTAssertEqual(selection.palette.darkColors, AccentPalette.neutral.darkColors)
        selection.select("artwork")
        XCTAssertFalse(selection.accept(artwork, requestID: artworkRequest))
        XCTAssertTrue(selection.accept(artwork, requestID: selection.requestID))
        XCTAssertEqual(selection.palette, artwork)
    }

    func testPaletteExtractionDoesNotDependOnPixelOrder() {
        let first = repeated([55, 155, 185, 255], count: 60)
        let second = repeated([195, 70, 100, 255], count: 60)
        XCTAssertEqual(
            MediaPaletteExtractor.extract(rgba: first + second),
            MediaPaletteExtractor.extract(rgba: second + first)
        )
    }

    func testSameSelectionDoesNotRestartExtractionAndStaleResultsCannotReplaceNewMedia() {
        var selection = AccentSelection()
        XCTAssertEqual(selection.palette, .neutral)
        XCTAssertTrue(selection.select("first"))
        let firstRequest = selection.requestID
        XCTAssertFalse(selection.select("first"))
        XCTAssertEqual(selection.requestID, firstRequest)
        XCTAssertTrue(selection.accept(AccentTheme.sage.palette, requestID: firstRequest))
        XCTAssertTrue(selection.select("second"))
        XCTAssertEqual(selection.palette, .neutral)
        XCTAssertFalse(selection.accept(AccentTheme.amber.palette, requestID: firstRequest))
        XCTAssertTrue(selection.accept(AccentTheme.ocean.palette, requestID: selection.requestID))
        XCTAssertEqual(selection.palette, AccentTheme.ocean.palette)
        let secondRequest = selection.requestID
        XCTAssertTrue(selection.select(nil))
        XCTAssertEqual(selection.palette, .neutral)
        XCTAssertFalse(selection.accept(AccentTheme.sage.palette, requestID: secondRequest))
    }

    func testInvalidChannelsAndPaletteInputsStayFinite() {
        let invalid = AccentRGB(red: .nan, green: .infinity, blue: -1)
        XCTAssertEqual(invalid, .black)
        XCTAssertEqual(AccentPalette(hue: .nan, saturation: .infinity), .neutral)
    }

    func testReselectingMediaRejectsTheEarlierRequestForTheSameKey() {
        var selection = AccentSelection()
        selection.select("first")
        let earlierRequest = selection.requestID
        selection.select("second")
        selection.select("first")
        XCTAssertNotEqual(selection.requestID, earlierRequest)
        XCTAssertFalse(selection.accept(AccentTheme.amber.palette, requestID: earlierRequest))
        XCTAssertEqual(selection.palette, .neutral)
        XCTAssertTrue(selection.accept(AccentTheme.ocean.palette, requestID: selection.requestID))
        XCTAssertEqual(selection.palette, AccentTheme.ocean.palette)
    }

    func testPremultipliedArtworkPreservesItsAccentHue() {
        let opaque = MediaPaletteExtractor.extract(rgba: repeated([40, 180, 140, 255], count: 100))
        let translucent = MediaPaletteExtractor.extract(rgba: repeated([32, 144, 112, 204], count: 100))
        XCTAssertNotEqual(opaque, .neutral)
        XCTAssertEqual(opaque.dark.red, translucent.dark.red, accuracy: 0.000001)
        XCTAssertEqual(opaque.dark.green, translucent.dark.green, accuracy: 0.000001)
        XCTAssertEqual(opaque.dark.blue, translucent.dark.blue, accuracy: 0.000001)
        XCTAssertEqual(opaque.light.red, translucent.light.red, accuracy: 0.000001)
        XCTAssertEqual(opaque.light.green, translucent.light.green, accuracy: 0.000001)
        XCTAssertEqual(opaque.light.blue, translucent.light.blue, accuracy: 0.000001)
    }

    private func repeated(_ pixel: [UInt8], count: Int) -> [UInt8] {
        Array(repeating: pixel, count: count).flatMap { $0 }
    }

    private func assertReadable(_ colors: AccentColors, context: String, file: StaticString = #filePath, line: UInt = #line) {
        for (backgroundName, background) in [
            ("background", colors.background), ("surface", colors.surface), ("control", colors.controlBackground)
        ] {
            for (textName, text) in [
                ("primary", colors.primaryText), ("secondary", colors.secondaryText), ("accent", colors.accent)
            ] {
                XCTAssertGreaterThanOrEqual(
                    text.contrast(with: background), 4.5, "\(context), \(textName) on \(backgroundName)", file: file, line: line
                )
            }
        }
        XCTAssertGreaterThanOrEqual(colors.onAccent.contrast(with: colors.accent), 4.5, context, file: file, line: line)
    }
}
