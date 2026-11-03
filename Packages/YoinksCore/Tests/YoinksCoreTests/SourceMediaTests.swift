import Foundation
import Testing
@testable import YoinksCore

struct SourceMediaTests {
    @Test func choicesKeepEveryResolutionAndSameResolutionVariant() throws {
        let media = try source("""
        {"id":"low","container":"mp4","videoCodec":"avc1","audioCodec":"none","width":426,"height":240,"rank":0,"sizeIsEstimate":true},
        {"id":"360","container":"mp4","videoCodec":"avc1","audioCodec":"none","width":640,"height":360,"rank":1,"sizeIsEstimate":true},
        {"id":"720-30","container":"mp4","videoCodec":"avc1","audioCodec":"none","width":1280,"height":720,"fps":30,"rank":2,"sizeIsEstimate":true},
        {"id":"720-60","container":"webm","videoCodec":"vp9","audioCodec":"none","width":1280,"height":720,"fps":60,"rank":3,"sizeIsEstimate":true},
        {"id":"4k","container":"webm","videoCodec":"vp9","audioCodec":"none","width":3840,"height":2160,"fps":60,"rank":4,"sizeIsEstimate":true}
        """)
        #expect(media.videoChoices.map(\.resolution) == [2160, 720, 720, 360, 240])
        #expect(media.videoChoices.map(\.id) == ["4k", "720-60", "720-30", "360", "low"])
        #expect(try media.selection(kind: .video, formatID: nil).formatID == nil)
        #expect(try media.selection(kind: .video, formatID: "720-60").quality == "720p · 60 fps")
        #expect(throws: (any Error).self) { try media.selection(kind: .video, formatID: "1080") }
    }

    @Test func portraitResolutionDoesNotTurnA1080pReelInto1920p() throws {
        let media = try source("""
        {"id":"reel","container":"mp4","videoCodec":"avc1","audioCodec":"aac","width":1080,"height":1920,"rank":0,"sizeIsEstimate":false}
        """)
        #expect(media.videoChoices.first?.qualityLabel == "1080p")
        #expect(media.audioFormats.first?.id == "reel")
    }

    @Test func lowResolutionAndUnknownResolutionRemainDownloadable() throws {
        let low = try source("""
        {"id":"240","container":"mp4","videoCodec":"avc1","audioCodec":"aac","width":426,"height":240,"rank":0,"sizeIsEstimate":true}
        """)
        #expect(low.videoChoices.first?.qualityLabel == "240p")
        let unknown = try source("""
        {"id":"original","container":"mp4","videoCodec":"unknown","audioCodec":"unknown","rank":0,"sizeIsEstimate":true}
        """)
        #expect(unknown.videoChoices.first?.qualityLabel == "Original")
    }

    @Test func audioChoicesUseSourceBitratesAndPreferAudioOnlyStreams() throws {
        let media = try source("""
        {"id":"combined","container":"mp4","videoCodec":"avc1","audioCodec":"aac","rank":0,"sizeIsEstimate":true},
        {"id":"low","container":"m4a","videoCodec":"none","audioCodec":"aac","audioBitrate":48.8,"rank":1,"sizeIsEstimate":true},
        {"id":"high","container":"webm","videoCodec":"none","audioCodec":"opus","audioBitrate":159.6,"rank":2,"sizeIsEstimate":true}
        """)
        #expect(media.audioChoices.map(\.id) == ["high", "low", "combined"])
        #expect(media.bestFormat(for: .audio)?.id == "high")
        #expect(try media.selection(kind: .audio, formatID: "high").quality == "160 kbps")
        #expect(try media.selection(kind: .audio, formatID: "combined").formatID == "combined")
    }

    @Test func oldDownloadJobsDecodeWithoutASocialSelection() throws {
        let old = """
        {"id":"E3F75383-1645-44A8-8633-14EA70209B6A","sourceURL":"https://example.com/video.mp4","createdAt":0,"title":"Video","phase":"paused","receivedBytes":4096}
        """
        let job = try JSONDecoder().decode(DownloadJob.self, from: Data(old.utf8))
        #expect(job.sourceSelection == nil)
        #expect(job.processedSeconds == nil)
        #expect(job.expectedSeconds == nil)
        #expect(job.phase == .paused)
        #expect(job.receivedBytes == 4096)
    }

    @Test func audioSelectionFromACombinedVideoUsesAudioBitrate() throws {
        let media = try source("""
        {"id":"combined","container":"mp4","videoCodec":"h264","audioCodec":"aac","width":1920,"height":1080,"audioBitrate":96,"bitrate":4500,"rank":0,"sizeIsEstimate":true}
        """)
        #expect(try media.selection(kind: .audio, formatID: "combined").quality == "96 kbps")
        let unknown = try source("""
        {"id":"combined","container":"mp4","videoCodec":"h264","audioCodec":"aac","width":1920,"height":1080,"bitrate":4500,"rank":0,"sizeIsEstimate":true}
        """)
        #expect(try unknown.selection(kind: .audio, formatID: "combined").quality == "Original")
    }

    @Test func socialJobStoresTheWebpageAndSelectionThroughARoundTrip() throws {
        let selection = SourceSelection(kind: .video, formatID: "137", quality: "1080p", outputFormat: .mov)
        let job = DownloadJob(link: try MediaLink("https://www.youtube.com/watch?v=example"), title: "Title", selection: selection)
        let restored = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        #expect(restored == job)
        #expect(restored.sourceSelection == selection)
        #expect(restored.sourceURL.host == "www.youtube.com")
    }

    @Test func knownAndEstimatedMergedDownloadSizesRemainDistinct() throws {
        let media = try source("""
        {"id":"video","container":"mp4","videoCodec":"h264","audioCodec":"none","byteCount":1000,"rank":0,"sizeIsEstimate":false},
        {"id":"audio","container":"m4a","videoCodec":"none","audioCodec":"aac","byteCount":200,"rank":1,"sizeIsEstimate":false},
        {"id":"approx","container":"mp4","videoCodec":"h264","audioCodec":"aac","byteCount":1400,"rank":2,"sizeIsEstimate":true}
        """)
        #expect(media.downloadSize(kind: .video, formatID: "video") == SourceDownloadSize(byteCount: 1200, isEstimate: false))
        #expect(media.downloadSize(kind: .video, formatID: "approx") == SourceDownloadSize(byteCount: 1400, isEstimate: true))
        #expect(media.downloadSize(kind: .audio, formatID: "approx")?.byteCount == 1400)
    }

    @Test func bitrateDurationEstimatesUseTheTransferredCombinedStream() throws {
        let json = """
        {"id":"source","sourceURL":"https://example.com/post","title":"Source","platform":"Youtube","duration":10,"formats":[
        {"id":"combined","container":"mp4","videoCodec":"h264","audioCodec":"aac","audioBitrate":100,"bitrate":800,"rank":0,"sizeIsEstimate":true}]}
        """
        let media = try JSONDecoder().decode(SourceMedia.self, from: Data(json.utf8))
        #expect(media.downloadSize(kind: .audio, formatID: "combined") == SourceDownloadSize(byteCount: 1_000_000, isEstimate: true))
    }

    @Test func unknownAndOverflowingSizesDoNotInventAnEstimate() throws {
        let unknown = try source("""
        {"id":"video","container":"mp4","videoCodec":"h264","audioCodec":"none","byteCount":1000,"rank":0,"sizeIsEstimate":false},
        {"id":"audio","container":"m4a","videoCodec":"none","audioCodec":"aac","rank":1,"sizeIsEstimate":true}
        """)
        #expect(unknown.downloadSize(kind: .video, formatID: "video") == nil)
        let overflow = try source("""
        {"id":"video","container":"mp4","videoCodec":"h264","audioCodec":"none","byteCount":9223372036854775807,"rank":0,"sizeIsEstimate":false},
        {"id":"audio","container":"m4a","videoCodec":"none","audioCodec":"aac","byteCount":1,"rank":1,"sizeIsEstimate":false}
        """)
        #expect(overflow.downloadSize(kind: .video, formatID: "video") == nil)
        #expect(overflow.downloadSize(kind: .video, formatID: "removed") == nil)
    }

    @Test func silentVideoSizeAndBestAudioMatchStreamPairing() throws {
        let silent = try source("""
        {"id":"silent","container":"mp4","videoCodec":"h264","audioCodec":"none","byteCount":1000,"rank":0,"sizeIsEstimate":false}
        """)
        #expect(silent.downloadSize(kind: .video, formatID: nil)?.byteCount == 1000)
        let media = try source("""
        {"id":"audio","container":"m4a","videoCodec":"none","audioCodec":"aac","byteCount":200,"rank":0,"sizeIsEstimate":false},
        {"id":"combined","container":"mp4","videoCodec":"h264","audioCodec":"aac","byteCount":1000,"rank":1,"sizeIsEstimate":false}
        """)
        #expect(try media.selectedFormats(kind: .audio, formatID: nil).map(\.id) == ["audio"])
        #expect(media.downloadSize(kind: .audio, formatID: nil)?.byteCount == 200)
    }

    private func source(_ formats: String) throws -> SourceMedia {
        let json = """
        {"id":"source","sourceURL":"https://example.com/post","title":"Source","platform":"Youtube","formats":[\(formats)]}
        """
        return try JSONDecoder().decode(SourceMedia.self, from: Data(json.utf8))
    }
}
