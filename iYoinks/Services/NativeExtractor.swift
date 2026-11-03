import ExtractorBridge
import Foundation
import SwiftFFmpeg
import VideoToolbox
import YoinksCore

struct ExtractorProgress: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case extracting, downloading, processing }
    let phase: Phase
    let receivedBytes: Int64?
    let expectedBytes: Int64?
    let processedSeconds: Double?
    let expectedSeconds: Double?
}

struct ExtractedFile: Decodable, Sendable {
    let fileName: MediaFileName
    let title: String
    let artist: String?
    let uploader: String?
    let thumbnailFileName: MediaFileName?
    let artworkEmbedded: Bool?
}

enum ExtractorError: Error, LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The bundled extractor couldn't start. Reinstall the latest yoink'd build."
        case .failed(let message): message
        }
    }
}

/// Python resolves sources in-process. Swift owns the UI, jobs, file commits, and native media processing.
enum NativeExtractor {
    private struct Request: Encodable, Sendable {
        let action: String
        let url: String
        let cacheDirectory: String?
        var directory: String?
        var selection: SourceSelection?
        var supportsAV1: Bool = false
    }
    private struct Response<Value: Decodable>: Decodable {
        let ok: Bool
        let value: Value?
        let error: String?
        let cancelled: Bool?
    }

    static func inspect(_ link: MediaLink) async throws -> SourceMedia {
        _ = try await ExtractorDependencies.shared.ensureReady()
        try Task.checkCancellation()
        return try await call(Request(action: "inspect", url: link.url.absoluteString, cacheDirectory: nil), events: { _ in })
    }

    static func download(_ link: MediaLink, selection: SourceSelection, directory: URL, cache: URL,
                         events: @escaping @Sendable (ExtractorProgress) -> Void) async throws -> ExtractedFile {
        _ = try await ExtractorDependencies.shared.ensureReady()
        try Task.checkCancellation()
        let request = Request(action: "download", url: link.url.absoluteString, cacheDirectory: cache.path,
                              directory: directory.path, selection: selection,
                              supportsAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        return try await call(request, events: events)
    }

    static func availableOutputFormats(for kind: MediaKind) async throws -> [SourceOutputFormat] {
        try await NativeOutputSupport.shared.formats(for: kind)
    }

    static func readSavedResult(directory: URL) async -> ExtractedFile? {
        await Task.detached(priority: .utility) { () -> ExtractedFile? in
            guard let data = boundedData(at: directory.appendingPathComponent("source-result.json"), limit: 32_768) else { return nil }
            return try? JSONDecoder().decode(ExtractedFile.self, from: data)
        }.value
    }

    static func readArtwork(_ file: ExtractedFile, directory: URL) async -> Data? {
        guard let thumbnail = file.thumbnailFileName else { return nil }
        return await Task.detached(priority: .utility) {
            boundedData(at: directory.appendingPathComponent(thumbnail.value), limit: 1_048_576)
        }.value
    }

    private nonisolated static func boundedData(at url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    private static func call<Value: Decodable & Sendable>(_ request: Request,
                                                         events: @escaping @Sendable (ExtractorProgress) -> Void) async throws -> Value {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let resources = bundle.url(forResource: "AppResources", withExtension: nil),
              let executable = Bundle.main.executablePath else { throw ExtractorError.unavailable }
        let home = resources.appendingPathComponent("Python").path
        let packages = resources.appendingPathComponent("Extractor").path
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let operation = try NativeCall(events: events)
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let result = iy_runtime_call(home, packages, executable, operation.handle, encoded) else {
                        continuation.resume(throwing: ExtractorError.unavailable)
                        return
                    }
                    defer { iy_free(result) }
                    let string = String(cString: result)
                    guard string.hasPrefix("{") else {
                        continuation.resume(throwing: ExtractorError.failed("Couldn't start the extractor. \(string)"))
                        return
                    }
                    continuation.resume(returning: Data(string.utf8))
                }
            }
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        let response = try JSONDecoder().decode(Response<Value>.self, from: data)
        if response.cancelled == true { throw CancellationError() }
        guard response.ok, let value = response.value else { throw ExtractorError.failed(response.error ?? "Couldn't read this media link. Try again.") }
        return value
    }
}

private actor NativeOutputSupport {
    static let shared = NativeOutputSupport()
    private var task: Task<SourceOutputSupport, any Error>?

    func formats(for kind: MediaKind) async throws -> [SourceOutputFormat] {
        if task == nil { task = Task { try await NativeMediaProcessor.outputSupport() } }
        guard let task else { throw ExtractorError.unavailable }
        return try await task.value.availableFormats(for: kind)
    }
}

private final class EventSink: Sendable {
    let events: @Sendable (ExtractorProgress) -> Void
    init(events: @escaping @Sendable (ExtractorProgress) -> Void) { self.events = events }

    func receive(_ string: String) {
        if let progress = try? JSONDecoder().decode(ExtractorProgress.self, from: Data(string.utf8)) { events(progress) }
    }
}

/// A call retains its callback context until the synchronous C invocation has returned.
private final class NativeCall: @unchecked Sendable {
    let sink: EventSink
    let handle: OpaquePointer

    init(events: @escaping @Sendable (ExtractorProgress) -> Void) throws {
        sink = EventSink(events: events)
        guard let operation = iy_operation_create({ json, context in
            guard let json, let context else { return }
            Unmanaged<EventSink>.fromOpaque(context).takeUnretainedValue().receive(String(cString: json))
        }, Unmanaged.passUnretained(sink).toOpaque(), { operation, json in
            guard let operation, let json else { return nil }
            return NativeMediaProcessor.execute(operation: operation, json: String(cString: json))
        }) else { throw ExtractorError.unavailable }
        handle = operation
    }

    func cancel() { iy_operation_cancel(handle) }
    deinit { iy_operation_free(handle) }
}

private enum NativeMediaProcessor {
    private static let executionLock = NSLock()
    private struct Request: Codable { let tool: String; let args: [String]; let duration: Double? }
    private struct Response: Codable { let exitCode: Int; let stdout: String; let stderr: String }
    private struct CancellationHandle: @unchecked Sendable { let value: OpaquePointer }

    static func outputSupport() async throws -> SourceOutputSupport {
        let encoders = try await listing("-encoders")
        let muxers = try await listing("-muxers")
        return SourceOutputSupport(encodersListing: encoders, muxersListing: muxers)
    }

    private static func listing(_ argument: String) async throws -> String {
        let operation = try NativeCall(events: { _ in })
        let request = Request(tool: "ffmpeg", args: ["-hide_banner", argument], duration: nil)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let pointer = execute(operation: operation.handle, json: encoded) else {
                        continuation.resume(throwing: ExtractorError.unavailable)
                        return
                    }
                    defer { iy_free(pointer) }
                    do {
                        let response = try JSONDecoder().decode(Response.self, from: Data(String(cString: pointer).utf8))
                        guard response.exitCode == 0 else { throw ExtractorError.failed("Couldn't check available file formats. Try again.") }
                        continuation.resume(returning: response.stdout + "\n" + response.stderr)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { operation.cancel() }
    }

    static func execute(operation: OpaquePointer, json: String) -> UnsafeMutablePointer<CChar>? {
        executionLock.lock()
        defer { executionLock.unlock() }
        let pointer = CancellationHandle(value: operation)
        let monitorQueue = DispatchQueue(label: "com.maynkudu.iyoinks.media-cancellation")
        let monitor = DispatchSource.makeTimerSource(queue: monitorQueue)
        monitor.schedule(deadline: .now(), repeating: .milliseconds(20))
        monitor.setEventHandler { if iy_operation_cancelled(pointer.value) { SwiftFFmpeg.requestCancel() } }
        monitor.resume()
        defer { monitor.cancel(); monitorQueue.sync {} }
        let response: Response
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
            guard request.tool == "ffmpeg" || request.tool == "ffprobe", !iy_operation_cancelled(operation) else { throw CancellationError() }
            let progress = ProcessingProgress(operation: operation, duration: request.duration)
            if request.tool == "ffmpeg" { SwiftFFmpeg.setLogHandler { _, text in progress.receive(text) } }
            defer {
                SwiftFFmpeg.setLogHandler(nil)
                SwiftFFmpeg.synchronizeLogHandler()
            }
            // FFmpeg opens -progress while parsing options by duplicating fd 2, and closes it only after a
            // transcode. A run that never transcodes (-encoders, -muxers) leaves that duplicate open. In
            // process, fd 2 is the wrapper's capture pipe at that moment, so the wrapper waits forever for
            // the pipe to close and holds the media lock. Only media runs pass a duration, and only they
            // can report progress against it.
            let reportsProgress = request.tool == "ffmpeg" && request.duration != nil
            let arguments = reportsProgress ? ["-progress", "pipe:2", "-nostats"] + request.args : request.args
            let result = try SwiftFFmpeg.executeDetailed(arguments, tool: request.tool == "ffprobe" ? .ffprobe : .ffmpeg)
            response = Response(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        } catch let SwiftFFmpegError.executionFailed(code, stdout, stderr) {
            response = Response(exitCode: code, stdout: stdout, stderr: stderr)
        } catch {
            response = Response(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return strdup(String(decoding: data, as: UTF8.self))
    }
}

/// FFmpeg reports actual processed timestamps on the serialized log queue.
private final class ProcessingProgress: @unchecked Sendable {
    private let operation: OpaquePointer
    private let duration: Double?
    private var pending = ""

    init(operation: OpaquePointer, duration: Double?) {
        self.operation = operation
        self.duration = duration
    }

    func receive(_ chunk: String) {
        pending += chunk
        while let end = pending.firstIndex(of: "\n") {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            guard line.hasPrefix("out_time_us="), let time = Double(line.dropFirst(12)), time.isFinite, time >= 0 else { continue }
            let progress = ExtractorProgress(phase: .processing, receivedBytes: nil, expectedBytes: nil,
                                             processedSeconds: time / 1_000_000, expectedSeconds: duration)
            if let data = try? JSONEncoder().encode(progress) {
                iy_operation_emit(operation, String(decoding: data, as: UTF8.self))
            }
        }
        if pending.utf8.count > 16_384 { pending = "" }
    }
}
