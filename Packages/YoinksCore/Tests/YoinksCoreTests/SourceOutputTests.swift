import Foundation
import XCTest
@testable import YoinksCore

final class SourceOutputTests: XCTestCase {
    func testNativeListingOnlyOffersAvailableEncodersAndMuxers() {
        let support = SourceOutputSupport(encodersListing: """
         A..... = Audio
         A....D aac Native AAC
         A....D flac FLAC
         A....D alac Apple Lossless
         A....D pcm_s16le PCM
        """, muxersListing: """
         .E. = Muxing supported
          E  mp4 MP4
          E  mov MOV
          E  ipod M4A
          E  flac FLAC
          E  wav WAV
        """)
        XCTAssertEqual(support.availableFormats(for: .audio), [.automatic, .m4a, .flac, .alac, .wav])
        XCTAssertEqual(support.availableFormats(for: .video), [.automatic, .mp4, .mov])
        XCTAssertFalse(support.encoders.contains("="))
        XCTAssertFalse(support.muxers.contains("="))
    }

    func testMissingCapabilitiesStillKeepAutomaticAvailable() {
        let support = SourceOutputSupport(encodersListing: "", muxersListing: "")
        XCTAssertEqual(support.availableFormats(for: .audio), [.automatic])
        XCTAssertEqual(support.availableFormats(for: .video), [.automatic])
    }

    func testOldSelectionsDecodeWithTheOriginalAutomaticPolicy() throws {
        let json = """
        {"kind":"audio","formatID":"251","quality":"160 kbps"}
        """
        let selection = try JSONDecoder().decode(SourceSelection.self, from: Data(json.utf8))
        XCTAssertNil(selection.outputFormat)
        let flac = SourceSelection(kind: .audio, formatID: "251", quality: "160 kbps", outputFormat: .flac)
        XCTAssertEqual(try JSONDecoder().decode(SourceSelection.self, from: JSONEncoder().encode(flac)), flac)
    }

    func testOutputValidationDoesNotConfuseSourceQualityWithContainer() throws {
        let json = """
        {"id":"source","sourceURL":"https://example.com/post","title":"Source","platform":"Youtube","formats":[
        {"id":"opus","container":"webm","videoCodec":"none","audioCodec":"opus","audioBitrate":160,"rank":0,"sizeIsEstimate":true}]}
        """
        let media = try JSONDecoder().decode(SourceMedia.self, from: Data(json.utf8))
        let selection = try media.selection(kind: .audio, formatID: "opus", outputFormat: .flac)
        XCTAssertEqual(selection.quality, "160 kbps")
        XCTAssertEqual(selection.outputFormat, .flac)
        XCTAssertThrowsError(try media.selection(kind: .audio, formatID: "opus", outputFormat: .mp4))
    }
}
