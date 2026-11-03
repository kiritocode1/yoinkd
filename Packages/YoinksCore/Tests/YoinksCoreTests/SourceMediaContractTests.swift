import Foundation
import Testing
@testable import YoinksCore

/// `Fixtures/source-media.json` is the Python extractor's `metadata()` output.
/// `scripts/verify-extractor.py` checks that Python still produces exactly this file; this suite checks
/// that Swift reads every key in it. A key renamed on either side then fails one of the two.
struct SourceMediaContractTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/source-media.json")

    @Test func swiftReadsEveryKeyTheExtractorWrites() throws {
        let data = try Data(contentsOf: Self.fixture)
        let media = try JSONDecoder().decode(SourceMedia.self, from: data)
        // The encoder omits nil optionals, so a key Swift failed to read disappears from the round trip.
        let written = try keys(data)
        let read = try keys(JSONEncoder().encode(media))
        #expect(read.media == written.media)
        #expect(read.format == written.format)
    }

    @Test func extractorValuesKeepTheirMeaning() throws {
        let media = try JSONDecoder().decode(SourceMedia.self, from: Data(contentsOf: Self.fixture))
        let format = try #require(media.formats.first)
        #expect(media.platform == "Fixture" && media.duration == 61.5)
        #expect(format.qualityLabel == "1080p")
        #expect(format.containsVideo && format.containsAudio)
        #expect(format.byteCount == 34_000_000 && !format.sizeIsEstimate)
    }

    private func keys(_ data: Data) throws -> (media: Set<String>, format: Set<String>) {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let formats = try #require(object["formats"] as? [[String: Any]])
        let format = try #require(formats.first)
        return (Set(object.keys), Set(format.keys))
    }
}
