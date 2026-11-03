import Combine
import CryptoKit
import ExtractorBridge
import Foundation

enum ExtractorPackageID: String, CaseIterable, Codable, Sendable, Identifiable {
    case ytDLP = "yt-dlp"
    case ejs = "yt-dlp-ejs"
    case certifi

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ytDLP: "yt-dlp"
        case .ejs: "YouTube EJS"
        case .certifi: "Certificates"
        }
    }
}

struct ExtractorPackageStatus: Identifiable, Sendable {
    let id: ExtractorPackageID
    var installedVersion: String?
    var latestVersion: String?
    var error: String?
    var progress: Double?
    var isWorking = false
    var pendingRestart = false

    var canUpdate: Bool { installedVersion == nil || latestVersion.map { $0 != installedVersion } == true }
}

private struct ExtractorDependencyError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct DependencyWheel: Codable, Sendable {
    let name: String
    let version: String
    let url: String
    let sha256: String
    let size: Int
}

private struct DependencyManifest: Codable, Sendable {
    let generation: String?
    let packages: [DependencyWheel]
}

private struct DependencyState: Decodable, Sendable {
    let current: String?
    let pending: String?
    let notice: String?
}

private struct DependencySnapshot: Decodable, Sendable {
    let state: DependencyState
    let manifest: DependencyManifest?
    let configured: String?
    let path: String?
}

private struct DependencyReply<Value: Decodable>: Decodable {
    let ok: Bool
    let result: Value?
    let error: String?
}

private struct DependencyReport: Sendable {
    let snapshot: DependencySnapshot
    let available: [ExtractorPackageID: DependencyWheel]
    let errors: [ExtractorPackageID: String]
    let lastChecked: Date?
}

@MainActor
final class ExtractorDependencies: ObservableObject {
    static let shared = ExtractorDependencies()

    @Published private(set) var packages = ExtractorPackageID.allCases.map { ExtractorPackageStatus(id: $0) }
    @Published private(set) var isUpdating = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: String?
    @Published private(set) var nativeVersions: [String: String] = [:]

    private let installer = DependencyInstaller()
    private var launchRefreshed = false
    private var operationCount = 0

    func refreshOnLaunch() async {
        guard !launchRefreshed else { return }
        launchRefreshed = true
        do {
            nativeVersions = try await installer.nativeVersions()
            apply(try await installer.installedReport())
            if packages.allSatisfy({ $0.installedVersion == nil }) {
                _ = try await ensureReady()
            } else {
                await checkForUpdates()
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func checkForUpdates() async {
        await perform(.check)
    }

    func update(_ id: ExtractorPackageID) async {
        await perform(.update(id))
    }

    func updateAll() async {
        await perform(.all)
    }

    func ensureReady() async throws -> URL {
        beginOperation(working: packages.allSatisfy({ $0.installedVersion == nil }) ? ExtractorPackageID.allCases : [])
        defer { endOperation() }
        do {
            let report = try await installer.perform(.ready)
            apply(report)
            guard let path = report.snapshot.path else {
                throw ExtractorDependencyError(message: "Source downloads need extraction packages. Connect to the internet and retry.")
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    private func perform(_ action: DependencyInstaller.Action) async {
        let working: [ExtractorPackageID]
        switch action {
        case .check:
            working = []
        case .all, .ready:
            working = ExtractorPackageID.allCases
        case .update(let id):
            working = packages.allSatisfy({ $0.installedVersion == nil }) ? ExtractorPackageID.allCases : [id]
        }
        beginOperation(working: working)
        defer { endOperation() }
        do {
            apply(try await installer.perform(action))
        } catch {
            status = error.localizedDescription
            for index in packages.indices where packages[index].isWorking {
                packages[index].error = error.localizedDescription
            }
        }
    }

    private func beginOperation(working: [ExtractorPackageID]) {
        operationCount += 1
        isUpdating = true
        status = nil
        for index in packages.indices where working.contains(packages[index].id) {
            packages[index].isWorking = true
            packages[index].progress = nil
            packages[index].error = nil
        }
    }

    private func endOperation() {
        operationCount -= 1
        isUpdating = operationCount > 0
        if !isUpdating {
            for index in packages.indices {
                packages[index].isWorking = false
                packages[index].progress = nil
            }
        }
    }

    fileprivate func downloadProgress(_ id: ExtractorPackageID, fraction: Double?) {
        guard isUpdating, let index = packages.firstIndex(where: { $0.id == id }) else { return }
        packages[index].isWorking = true
        packages[index].progress = fraction
        packages[index].error = nil
    }

    private func apply(_ report: DependencyReport) {
        lastChecked = report.lastChecked
        status = report.snapshot.state.notice
        for index in packages.indices {
            let id = packages[index].id
            packages[index].installedVersion = report.snapshot.manifest?.packages.first(where: { $0.name == id.rawValue })?.version
            packages[index].latestVersion = report.available[id]?.version
            packages[index].error = report.errors[id]
            packages[index].pendingRestart = report.snapshot.state.pending != nil && report.snapshot.configured != nil && report.snapshot.configured != report.snapshot.state.pending
        }
    }
}

private actor DependencyInstaller {
    enum Action: Equatable, Sendable {
        case ready, check, all, update(ExtractorPackageID)
    }

    private struct MetadataCache: Codable {
        let entry: DependencyWheel
        let etag: String?
        let checked: Date
    }

    private struct Baseline: Decodable {
        let native: [String: String]
        let packages: [DependencyWheel]
    }

    private var inFlight: Task<DependencyReport, Error>?
    private var inFlightAction: Action?
    private var available: [ExtractorPackageID: DependencyWheel] = [:]
    private var errors: [ExtractorPackageID: String] = [:]
    private var lastChecked: Date?
    private var configuredPath: String?
    private var root: URL?
    private var restoredMetadata = false

    func installedReport() async throws -> DependencyReport {
        try await report()
    }

    func nativeVersions() async throws -> [String: String] {
        try await bundledBaseline().native
    }

    func perform(_ action: Action) async throws -> DependencyReport {
        if action == .ready, try await report().snapshot.manifest != nil {
            return try await configure()
        }
        if let inFlight {
            if action == .ready {
                _ = try await inFlight.value
                return try await configure()
            }
            if action == .check || action == inFlightAction {
                return try await inFlight.value
            }
            throw ExtractorDependencyError(message: "Another dependency update is running. Try again when it finishes.")
        }
        inFlightAction = action
        let task = Task { try await self.run(action) }
        inFlight = task
        defer {
            inFlight = nil
            inFlightAction = nil
        }
        return try await task.value
    }

    private func directory() throws -> URL {
        if let root { return root }
        var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ExtractorDependencies", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        for name in ["downloads", "generations"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        root = directory
        return directory
    }

    private func control<Value: Decodable>(_ action: String, values: [String: Any] = [:], as type: Value.Type) async throws -> Value {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let base = bundle.url(forResource: "Resources", withExtension: nil) else {
            throw ExtractorDependencyError(message: "The bundled extraction runtime is missing. Reinstall the app.")
        }
        let home = base.appendingPathComponent("Python").path
        let packages = base.appendingPathComponent("Extractor").path
        let executable = Bundle.main.executableURL?.path ?? ""
        var request = values
        request["action"] = action
        request["root"] = try directory().path
        let bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let output = try await Task.detached(priority: .utility) {
            guard let json = String(data: bytes, encoding: .utf8) else {
                throw ExtractorDependencyError(message: "Invalid dependency request.")
            }
            guard let pointer = iy_dependency_call(home, packages, executable, json) else {
                throw ExtractorDependencyError(message: "The dependency installer could not start.")
            }
            defer { iy_free(pointer) }
            return Data(String(cString: pointer).utf8)
        }.value
        guard let reply = try? JSONDecoder().decode(DependencyReply<Value>.self, from: output) else {
            throw ExtractorDependencyError(message: "The bundled Python runtime could not start. Reinstall the app or retry.")
        }
        guard reply.ok, let result = reply.result else {
            throw ExtractorDependencyError(message: reply.error ?? "The dependency operation failed.")
        }
        return result
    }

    private func report() async throws -> DependencyReport {
        if !restoredMetadata {
            restoredMetadata = true
            let directory = try directory()
            for id in ExtractorPackageID.allCases {
                let url = directory.appendingPathComponent("metadata-\(id.rawValue).json")
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                   values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 8192,
                   let bytes = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(MetadataCache.self, from: bytes) {
                    available[id] = cached.entry
                    lastChecked = max(lastChecked ?? .distantPast, cached.checked)
                }
            }
        }
        let snapshot = try await control("snapshot", as: DependencySnapshot.self)
        return DependencyReport(snapshot: snapshot, available: available, errors: errors, lastChecked: lastChecked)
    }

    private func configure() async throws -> DependencyReport {
        let snapshot = try await control("configure", as: DependencySnapshot.self)
        configuredPath = snapshot.path
        return DependencyReport(snapshot: snapshot, available: available, errors: errors, lastChecked: lastChecked)
    }

    private func run(_ action: Action) async throws -> DependencyReport {
        let before = try await report()
        if action == .ready, configuredPath != nil || before.snapshot.manifest != nil {
            return try await configure()
        }
        if action == .check {
            await checkMetadata()
            return try await report()
        }
        let firstInstall = before.snapshot.manifest == nil
        if available.isEmpty { await checkMetadata() }
        do {
            var selected = before.snapshot.manifest?.packages ?? []
            if firstInstall || action == .all {
                selected = try ExtractorPackageID.allCases.map { id in
                    guard let entry = available[id] else {
                        throw ExtractorDependencyError(message: errors[id] ?? "Release information is unavailable. Connect to the internet and retry.")
                    }
                    return entry
                }
            } else if case .update(let id) = action {
                guard let entry = available[id] else {
                    throw ExtractorDependencyError(message: errors[id] ?? "Check for updates before downloading a release.")
                }
                selected.removeAll { $0.name == id.rawValue }
                selected.append(entry)
            }
            try await install(selected, allowEJSChange: action != .update(.ejs))
        } catch {
            guard firstInstall else { throw error }
            let baseline = try await bundledBaseline()
            do {
                try await install(baseline.packages)
            } catch {
                throw ExtractorDependencyError(message: "Source downloads need extraction packages. \(error.localizedDescription) Connect to the internet and retry in Settings.")
            }
        }
        return action == .ready ? try await configure() : try await report()
    }

    private func bundledBaseline() async throws -> Baseline {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let resources = bundle.url(forResource: "Resources", withExtension: nil) else {
            throw ExtractorDependencyError(message: "The baseline dependency manifest is missing.")
        }
        let path = resources.appendingPathComponent("Extractor/dependencies.json")
        let bytes = try await Task.detached(priority: .utility) { try Data(contentsOf: path) }.value
        return try JSONDecoder().decode(Baseline.self, from: bytes)
    }

    private func checkMetadata() async {
        errors = [:]
        for id in ExtractorPackageID.allCases {
            do { available[id] = try await release(id) }
            catch { errors[id] = error.localizedDescription }
        }
        lastChecked = Date()
    }

    private func release(_ id: ExtractorPackageID, version: String? = nil) async throws -> DependencyWheel {
        let cacheURL = try directory().appendingPathComponent("metadata-\(id.rawValue).json")
        let cached = try? JSONDecoder().decode(MetadataCache.self, from: Data(contentsOf: cacheURL))
        var url = "https://pypi.org/pypi/\(id.rawValue)/"
        if let version { url += version + "/" }
        url += "json"
        guard let endpoint = URL(string: url) else {
            throw ExtractorDependencyError(message: "Invalid release endpoint.")
        }
        var request = URLRequest(url: endpoint)
        if version == nil, let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let response = try await DependencyDownload.fetch(request, host: "pypi.org", maximum: 8 * 1024 * 1024)
        if response.status == 304, let cached, version == nil { return cached.entry }
        guard response.status == 200 else {
            throw ExtractorDependencyError(message: "Release information is unavailable. Server returned \(response.status).")
        }
        let object = try JSONSerialization.jsonObject(with: response.data)
        let entry = try await control("metadata", values: ["name": id.rawValue, "metadata": object], as: DependencyWheel.self)
        if let version, entry.version != version {
            throw ExtractorDependencyError(message: "The server returned a different package version.")
        }
        if version == nil {
            let data = try JSONEncoder().encode(MetadataCache(entry: entry, etag: response.etag, checked: Date()))
            try data.write(to: cacheURL, options: .atomic)
        }
        return entry
    }

    private func install(_ entries: [DependencyWheel], allowEJSChange: Bool = true) async throws {
        guard let ytDLP = entries.first(where: { $0.name == ExtractorPackageID.ytDLP.rawValue }) else {
            throw ExtractorDependencyError(message: "The update is missing yt-dlp.")
        }
        var selected = entries
        try await download(ytDLP)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ytDLP))
        let ejsVersion = try await control("ejsRequirement", values: ["entry": object], as: String.self)
        if selected.first(where: { $0.name == ExtractorPackageID.ejs.rawValue })?.version != ejsVersion {
            guard allowEJSChange else {
                throw ExtractorDependencyError(message: "This EJS release does not match installed yt-dlp. Update yt-dlp or use Update all.")
            }
            selected.removeAll { $0.name == ExtractorPackageID.ejs.rawValue }
            selected.append(try await release(.ejs, version: ejsVersion))
        }
        for entry in selected { try await download(entry) }
        let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected))
        _ = try await control("install", values: ["entries": objects], as: DependencySnapshot.self)
    }

    private func download(_ entry: DependencyWheel) async throws {
        guard let id = ExtractorPackageID(rawValue: entry.name), let url = URL(string: entry.url), entry.size > 0, entry.size <= 20 * 1024 * 1024 else {
            throw ExtractorDependencyError(message: "Invalid package download.")
        }
        let destination = try directory().appendingPathComponent("downloads/\(entry.sha256).whl")
        let validCache = await Task.detached(priority: .utility) {
            guard let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), values.isSymbolicLink != true,
                  values.fileSize == entry.size, let data = try? Data(contentsOf: destination) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256
        }.value
        if validCache { return }
        await ExtractorDependencies.shared.downloadProgress(id, fraction: nil)
        let response = try await DependencyDownload.fetch(URLRequest(url: url), host: "files.pythonhosted.org", maximum: entry.size) { fraction in
            Task { @MainActor in ExtractorDependencies.shared.downloadProgress(id, fraction: fraction) }
        }
        guard response.status == 200, response.data.count == entry.size,
              SHA256.hash(data: response.data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw ExtractorDependencyError(message: "\(id.title) failed its download integrity check. Retry the update.")
        }
        try await Task.detached(priority: .utility) { try response.data.write(to: destination, options: .atomic) }.value
        await ExtractorDependencies.shared.downloadProgress(id, fraction: 1)
    }
}

private final class DependencyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response: Sendable {
        let data: Data
        let status: Int
        let etag: String?
    }

    private let host: String
    private let maximum: Int
    private let progress: (@Sendable (Double) -> Void)?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Response, Error>?
    private var session: URLSession?

    private init(host: String, maximum: Int, progress: (@Sendable (Double) -> Void)?) {
        self.host = host
        self.maximum = maximum
        self.progress = progress
    }

    static func fetch(_ request: URLRequest, host: String, maximum: Int, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Response {
        let download = DependencyDownload(host: host, maximum: maximum, progress: progress)
        guard download.allowed(request.url) else {
            throw ExtractorDependencyError(message: "The dependency URL is not allowlisted.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: download, delegateQueue: queue)
            download.session = session
            session.dataTask(with: request).resume()
        }
    }

    private func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == host, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        if host == "pypi.org" {
            let parts = url.path.split(separator: "/")
            return (parts.count == 3 || parts.count == 4) && parts.first == "pypi" && parts.last == "json"
                && ExtractorPackageID(rawValue: String(parts[1])) != nil
        }
        return url.path.hasSuffix("-py3-none-any.whl")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, allowed(request.url) else {
            failure = ExtractorDependencyError(message: "A dependency redirect was rejected.")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, allowed(response.url), response.expectedContentLength <= maximum else {
            failure = ExtractorDependencyError(message: "The dependency response exceeds its download limit.")
            completionHandler(.cancel)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count <= maximum - bytes.count else {
            failure = ExtractorDependencyError(message: "The dependency download exceeded its size limit.")
            dataTask.cancel()
            return
        }
        data.append(bytes)
        progress?(Double(data.count) / Double(maximum))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = continuation
        self.continuation = nil
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: Response(data: data, status: response.statusCode, etag: response.value(forHTTPHeaderField: "ETag")))
        } else {
            continuation?.resume(throwing: ExtractorDependencyError(message: "The server did not return release information."))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
