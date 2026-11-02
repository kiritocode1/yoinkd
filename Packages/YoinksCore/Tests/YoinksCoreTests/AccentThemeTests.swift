import XCTest
@testable import YoinksCore

final class AccentThemeTests: XCTestCase {
    func testAllSixThemesPersistAcrossNewPreferencesInstances() throws {
        let suite = "iYoinks.ThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ThemePreferences(defaults: defaults)
        XCTAssertEqual(AccentTheme.allCases.count, 6)
        XCTAssertEqual(preferences.theme, .sage)
        for theme in AccentTheme.allCases {
            preferences.theme = theme
            let reopened = ThemePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.theme, theme)
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
        }
        let curated = AccentTheme.allCases.filter { $0 != .dynamic }
        for first in curated {
            for second in curated where first != second {
                XCTAssertNotEqual(first.palette, second.palette)
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
            let palette = AccentPalette(hue: Double(degree) / 360, saturation: 0.55)
            XCTAssertGreaterThanOrEqual(palette.light.contrast(with: .lightSurface), 4.5)
            XCTAssertGreaterThanOrEqual(palette.dark.contrast(with: .darkSurface), 4.5)
        }
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

    private func repeated(_ pixel: [UInt8], count: Int) -> [UInt8] {
        Array(repeating: pixel, count: count).flatMap { $0 }
    }
}
