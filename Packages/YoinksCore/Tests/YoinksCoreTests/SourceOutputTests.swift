import Foundation
import Testing
@testable import YoinksCore

struct SourceOutputTests {
    @Test func nativeListingOnlyOffersAvailableEncodersAndMuxers() {
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
        #expect(support.availableFormats(for: .audio) == [.automatic, .m4a, .flac, .alac, .wav])
        #expect(support.availableFormats(for: .video) == [.automatic, .mp4, .mov])
        #expect(!support.encoders.contains("="))
        #expect(!support.muxers.contains("="))
    }

    @Test func missingCapabilitiesStillKeepAutomaticAvailable() {
        let support = SourceOutputSupport(encodersListing: "", muxersListing: "")
        #expect(support.availableFormats(for: .audio) == [.automatic])
        #expect(support.availableFormats(for: .video) == [.automatic])
    }

    @Test func oldSelectionsDecodeWithTheOriginalAutomaticPolicy() throws {
        let json = """
        {"kind":"audio","formatID":"251","quality":"160 kbps"}
        """
        let selection = try JSONDecoder().decode(SourceSelection.self, from: Data(json.utf8))
        #expect(selection.outputFormat == nil)
        let flac = SourceSelection(kind: .audio, formatID: "251", quality: "160 kbps", outputFormat: .flac)
        #expect(try JSONDecoder().decode(SourceSelection.self, from: JSONEncoder().encode(flac)) == flac)
    }

    @Test func outputValidationDoesNotConfuseSourceQualityWithContainer() throws {
        let json = """
        {"id":"source","sourceURL":"https://example.com/post","title":"Source","platform":"Youtube","formats":[
        {"id":"opus","container":"webm","videoCodec":"none","audioCodec":"opus","audioBitrate":160,"rank":0,"sizeIsEstimate":true}]}
        """
        let media = try JSONDecoder().decode(SourceMedia.self, from: Data(json.utf8))
        let selection = try media.selection(kind: .audio, formatID: "opus", outputFormat: .flac)
        #expect(selection.quality == "160 kbps")
        #expect(selection.outputFormat == .flac)
        #expect(throws: (any Error).self) { try media.selection(kind: .audio, formatID: "opus", outputFormat: .mp4) }
    }
}
