import Combine
import Foundation
import os
import YoinksCore

/// Reasons the queue refuses to accept or restart a job right now.
enum DownloadQueueError: LocalizedError {
    case notReady
    case folderChanging

    var errorDescription: String? {
        switch self {
        case .notReady: "Downloads are still opening. Try again in a moment."
        case .folderChanging: "Wait for the save folder to finish changing."
        }
    }
}

@MainActor
final class DownloadQueue: ObservableObject {
    private static let logger = Logger(subsystem: "com.maynkudu.iyoinks", category: "queue")
    static let sessionIdentifier = "com.maynkudu.iyoinks.media-downloads"
    private let library: MediaLibrary
    private let journal: DownloadJournal
    private let session: URLSession
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    private let appDelegate: IYoinksAppDelegate
    private var eventTask: Task<Void, Never>?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var sourceTasks: [UUID: Task<Void, Never>] = [:]
    private var processing: Set<TransferIdentity> = []
    private var bufferedEvents: [DownloadEvent] = []
    private var revision: UInt64 = 0
    private var isRestoring = false
    private var isScheduling = false
    private var backgroundEventsFinished = false
    private var lastProgressSave = Date.distantPast

    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var isReady = false
    @Published private(set) var restoreError: String?
    @Published var storageError: String?

    init(library: MediaLibrary, appDelegate: IYoinksAppDelegate) {
        self.library = library
        self.appDelegate = appDelegate
        journal = DownloadJournal(url: library.storage.files.queueURL)
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream()
        self.continuation = continuation
        let delegate = BackgroundDownloadDelegate(files: library.storage.files, events: continuation)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 86_400
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        appDelegate.onForeground = { [weak self] in Task { await self?.schedule() } }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await receive(event)
            }
        }
    }

    var activeCount: Int { jobs.filter { !$0.phase.isTerminal && $0.phase != .paused }.count }

    func restore() async {
        guard !isReady, !isRestoring else { return }
        isRestoring = true
        restoreError = nil
        do {
            let snapshot = try await journal.load()
            if snapshot.discardedJobCount > 0 {
                Self.logger.error("Dropped \(snapshot.discardedJobCount, privacy: .public) unreadable jobs from the queue journal")
            }
            jobs = snapshot.jobs
            revision = snapshot.revision
            let allTasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            for task in allTasks {
                guard let download = task as? URLSessionDownloadTask,
                      let identity = TransferIdentity(taskDescription: task.taskDescription),
                      let job = matching(identity), job.sourceSelection == nil, job.phase.occupiesTransferSlot else {
                    task.cancel()
                    continue
                }
                tasks[identity.jobID] = download
                update(identity.jobID) { $0.taskIdentifier = task.taskIdentifier }
                if job.phase == .pausing {
                    let data = await download.cancelByProducingResumeData()
                    let resume: MediaFileName? = if let data { try? await library.storage.saveResumeData(data, id: identity.attemptID) } else { nil }
                    tasks[identity.jobID] = nil
                    update(identity.jobID) { $0.phase = .paused; $0.taskIdentifier = nil; $0.resumeFile = resume }
                } else if task.state == .suspended { task.resume() }
            }
            let stagedFiles = try await library.storage.stagedMedia()
            for job in jobs {
                // An item whose stored name no longer parses is treated as unsaved, so the job never
                // becomes completed without a file (which the journal would then refuse to load).
                let saved = try library.item(id: job.id).flatMap { item in
                    (try? MediaFileName(item.relativeFileName)).map { RelaunchEvidence.SavedItem(file: $0, title: item.title) }
                }
                let evidence = RelaunchEvidence(
                    savedItem: saved,
                    hasStagedFile: stagedFiles.contains { $0.id == job.id && $0.operationID == job.attemptID },
                    hasLiveTask: tasks[job.id] != nil
                )
                var cleanup = RelaunchCleanup.none
                update(job.id) { cleanup = $0.reconcileAfterRelaunch(evidence) }
                if cleanup == .removeSourceWork { try? await library.storage.removeSourceWork(id: job.id) }
            }
            isReady = true
            isRestoring = false
            try await persist()
            for staged in stagedFiles where staged.sourceURL != nil { await receive(.downloaded(staged)) }
            let pending = bufferedEvents
            bufferedEvents.removeAll()
            for event in pending { await receive(event) }
            await schedule()
            finishBackgroundIfReady()
        } catch {
            isRestoring = false
            isReady = false
            restoreError = "Couldn't restore downloads. \(error.localizedDescription)"
        }
    }

    func enqueue(_ link: MediaLink) async throws {
        try await enqueueJob(DownloadJob(link: link))
    }

    func enqueue(_ media: SourceMedia, selection: SourceSelection) async throws {
        _ = try media.selection(kind: selection.kind, formatID: selection.formatID, outputFormat: selection.outputFormat)
        let link = try MediaLink(media.sourceURL.absoluteString)
        try await enqueueJob(DownloadJob(link: link, title: media.title, selection: selection))
    }

    private func enqueueJob(_ job: DownloadJob) async throws {
        guard isReady else { throw DownloadQueueError.notReady }
        guard !library.isChangingFolder else { throw DownloadQueueError.folderChanging }
        jobs.append(job)
        do { try await persist() } catch {
            jobs.removeAll { $0.id == job.id }
            throw error
        }
        await schedule()
    }

    func pause(_ id: UUID) async {
        if let current = job(id), current.isSource, let identity = current.identity,
           !processing.contains(identity), let task = sourceTasks[id], current.phase.isSourceWorkRunning {
            update(id) { $0.phase = .pausing }
            task.cancel()
            await saveOrReport()
            return
        }
        guard let job = job(id), let identity = job.identity,
              job.phase == .downloading || job.phase == .waiting,
              let task = tasks[id] else { return }
        update(id) { $0.phase = .pausing }
        await saveOrReport()
        guard matching(identity)?.phase == .pausing else { return }
        let data = await task.cancelByProducingResumeData()
        continuation.yield(.paused(identity, resumeData: data))
    }

    func resume(_ id: UUID) async throws {
        guard job(id)?.phase == .paused else { return }
        guard !library.isChangingFolder else { throw DownloadQueueError.folderChanging }
        update(id) { $0.requeue() }
        await saveOrReport()
        await schedule()
    }

    func cancel(_ id: UUID) async {
        if let current = job(id), current.sourceSelection != nil, let task = sourceTasks[id],
           let identity = current.identity, !processing.contains(identity), !current.phase.isTerminal {
            update(id) { $0.phase = .cancelling }
            task.cancel()
            await saveOrReport()
            return
        }
        guard let current = job(id), !current.phase.isTerminal, current.phase != .processing, current.phase != .saving else { return }
        update(id) { $0.phase = .cancelled; $0.taskIdentifier = nil; $0.message = nil; $0.attemptID = nil; $0.resumeFile = nil }
        tasks.removeValue(forKey: id)?.cancel()
        if let resume = current.resumeFile {
            try? await library.storage.removeResumeData(resume)
        }
        if current.sourceSelection != nil { try? await library.storage.removeSourceWork(id: id) }
        await saveOrReport()
        await schedule()
    }

    func retry(_ id: UUID) async throws {
        guard let current = job(id), current.phase == .failed || current.phase == .cancelled else { return }
        guard !library.isChangingFolder else { throw DownloadQueueError.folderChanging }
        update(id) { $0.resetForRetry() }
        await saveOrReport()
        await schedule()
    }

    func remove(_ id: UUID) async {
        guard let current = job(id), current.phase.isTerminal else { return }
        jobs.removeAll { $0.id == id }
        if let resume = current.resumeFile { try? await library.storage.removeResumeData(resume) }
        if current.sourceSelection != nil { try? await library.storage.removeSourceWork(id: id) }
        await saveOrReport()
    }

    func clearHistory() async {
        let completed = jobs.filter { $0.phase.isTerminal }.map(\.id)
        for id in completed { await remove(id) }
    }

    private func schedule() async {
        guard isReady, !isScheduling, !library.isChangingFolder else { return }
        isScheduling = true
        defer { isScheduling = false }
        while let next = jobs.nextToStart(sourceRunning: !sourceTasks.isEmpty,
                                          canStartSource: appDelegate.sourceBackgroundWork.canStart) {
            let identity = TransferIdentity(jobID: next.id, attemptID: UUID())
            if next.sourceSelection != nil {
                update(next.id) {
                    $0.attemptID = identity.attemptID
                    $0.phase = .extracting
                    $0.receivedBytes = 0
                    $0.expectedBytes = nil
                    $0.processedSeconds = nil
                    $0.expectedSeconds = nil
                }
                do {
                    try await persist()
                    guard matching(identity)?.phase == .extracting else { continue }
                    if let selection = next.sourceSelection {
                        appDelegate.sourceBackgroundWork.begin(identity, title: next.title, selection: selection) { [weak self] in
                            self?.expireSource(identity)
                        }
                    }
                    sourceTasks[next.id] = Task { await runSource(next, identity: identity) }
                } catch {
                    update(next.id) { $0.phase = .failed; $0.message = "Couldn't save the download queue. Try again." }
                    storageError = error.localizedDescription
                    break
                }
                continue
            }
            let task: URLSessionDownloadTask
            if let resumeFile = next.resumeFile, let data = try? await library.storage.resumeData(resumeFile) {
                task = session.downloadTask(withResumeData: data)
            } else {
                var request = URLRequest(url: next.sourceURL)
                request.httpMethod = "GET"
                task = session.downloadTask(with: request)
                update(next.id) { $0.receivedBytes = 0; $0.expectedBytes = nil }
            }
            guard job(next.id)?.phase == .queued else { task.cancel(); continue }
            task.taskDescription = identity.taskDescription
            update(next.id) {
                $0.attemptID = identity.attemptID
                $0.taskIdentifier = task.taskIdentifier
                $0.phase = .downloading
            }
            tasks[next.id] = task
            do {
                try await persist()
                guard matching(identity)?.phase == .downloading else { task.cancel(); continue }
                task.resume()
            } catch {
                task.cancel()
                tasks[next.id] = nil
                update(next.id) { $0.phase = .failed; $0.message = "Couldn't save the download queue. Try again."; $0.taskIdentifier = nil }
                storageError = error.localizedDescription
                break
            }
        }
    }

    private func receive(_ event: DownloadEvent) async {
        guard isReady else { bufferedEvents.append(event); return }
        switch event {
        case .sourceProgress(let identity, let progress):
            guard let current = matching(identity), current.isSource, current.phase.isSourceWorkRunning else { return }
            update(identity.jobID) {
                switch progress.phase {
                case .extracting: $0.phase = .extracting
                case .downloading: $0.phase = .downloading
                case .processing: $0.phase = .processing
                }
                if let received = progress.receivedBytes { $0.receivedBytes = max(0, received) }
                $0.expectedBytes = progress.expectedBytes.flatMap { $0 > 0 ? $0 : nil } ?? $0.expectedBytes
                if let processed = progress.processedSeconds { $0.processedSeconds = processed }
                if let expected = progress.expectedSeconds { $0.expectedSeconds = expected }
            }
            appDelegate.sourceBackgroundWork.report(progress, for: identity)
            if Date.now.timeIntervalSince(lastProgressSave) >= 2 {
                lastProgressSave = .now
                await saveOrReport()
            }
        case .progress(let identity, let received, let expected):
            guard let current = matching(identity), current.phase == .downloading || current.phase == .waiting else { return }
            update(identity.jobID) { $0.phase = .downloading; $0.receivedBytes = received; $0.expectedBytes = expected }
            if Date.now.timeIntervalSince(lastProgressSave) >= 2 {
                lastProgressSave = .now
                await saveOrReport()
            }
        case .waiting(let identity):
            guard matching(identity)?.phase == .downloading else { return }
            update(identity.jobID) { $0.phase = .waiting }
            await saveOrReport()
        case .downloaded(let staged):
            let identity = TransferIdentity(jobID: staged.id, attemptID: staged.operationID)
            guard let current = matching(identity), !current.phase.isTerminal || current.phase == .failed,
                  current.phase != .paused, current.phase != .pausing, current.phase != .cancelling else {
                try? await library.storage.discard(staged)
                return
            }
            guard !processing.contains(identity) else { return }
            tasks[staged.id] = nil
            processing.insert(identity)
            update(staged.id) { $0.phase = .saving; $0.taskIdentifier = nil; $0.message = nil }
            await saveOrReport()
            Task { await process(staged, identity: identity) }
            await schedule()
        case .failed(let identity, let message, let data):
            guard let current = matching(identity), current.phase == .downloading || current.phase == .waiting else { return }
            tasks[identity.jobID] = nil
            var resume: MediaFileName?
            if let data { resume = try? await library.storage.saveResumeData(data, id: identity.attemptID) }
            guard matching(identity) != nil else {
                if let resume { try? await library.storage.removeResumeData(resume) }
                return
            }
            update(identity.jobID) { $0.phase = .failed; $0.message = message; $0.taskIdentifier = nil; $0.resumeFile = resume }
            await saveOrReport()
            await schedule()
        case .paused(let identity, let data):
            guard matching(identity)?.phase == .pausing else { return }
            tasks[identity.jobID] = nil
            var resume: MediaFileName?
            if let data { resume = try? await library.storage.saveResumeData(data, id: identity.attemptID) }
            guard matching(identity)?.phase == .pausing else {
                if let resume { try? await library.storage.removeResumeData(resume) }
                return
            }
            update(identity.jobID) {
                $0.phase = .paused
                $0.taskIdentifier = nil
                $0.resumeFile = resume
                $0.message = resume == nil ? "This server requires restarting the download when you resume." : nil
            }
            await saveOrReport()
            await schedule()
        case .finishedBackgroundEvents:
            backgroundEventsFinished = true
            finishBackgroundIfReady()
        }
    }

    private func process(_ staged: StagedMedia, identity: TransferIdentity) async {
        let result: Result<MediaFileName, any Error>
        do {
            var sourceTitle: String?
            var thumbnail: Data?
            var artist: String?
            if job(staged.id)?.sourceSelection != nil {
                sourceTitle = job(staged.id)?.title
                let directory = try await library.storage.sourceWorkDirectory(id: staged.id)
                if let metadata = await NativeExtractor.readSavedResult(directory: directory), metadata.fileName.value == staged.originalName {
                    sourceTitle = metadata.title
                    artist = metadata.artist ?? metadata.uploader
                    thumbnail = await NativeExtractor.readArtwork(metadata, directory: directory)
                }
            }
            result = .success(try await library.commit(staged, preferredTitle: sourceTitle, preferredThumbnail: thumbnail, artist: artist))
        } catch {
            try? await library.storage.discard(staged)
            result = .failure(error)
        }
        if let resume = job(staged.id)?.resumeFile {
            try? await library.storage.removeResumeData(resume)
            update(staged.id) { $0.resumeFile = nil }
        }
        switch result {
        case .success(let file):
            if job(staged.id)?.sourceSelection != nil { try? await library.storage.removeSourceWork(id: staged.id) }
            update(staged.id) {
                $0.phase = .completed
                $0.storedFile = file
                $0.message = nil
                if let details = library.details[staged.id] {
                    $0.receivedBytes = details.byteCount
                    $0.expectedBytes = details.byteCount
                }
                if let item = try? library.item(id: staged.id) { $0.title = item.title }
            }
        case .failure(let error):
            update(staged.id) { $0.phase = .failed; $0.message = error.localizedDescription }
        }
        await saveOrReport()
        processing.remove(identity)
        appDelegate.sourceBackgroundWork.end(identity, success: job(staged.id)?.phase == .completed)
        await schedule()
        finishBackgroundIfReady()
    }

    private func runSource(_ source: DownloadJob, identity: TransferIdentity) async {
        var failure: (any Error)?
        do {
            guard let selection = source.sourceSelection else { throw ExtractorError.unavailable }
            let directory = try await library.storage.sourceWorkDirectory(id: source.id)
            let cache = try await library.storage.sourceCacheDirectory()
            let events = continuation
            let file = try await NativeExtractor.download(try MediaLink(source.sourceURL.absoluteString), selection: selection,
                                                          directory: directory, cache: cache) { progress in
                events.yield(.sourceProgress(identity, progress))
            }
            try Task.checkCancellation()
            update(source.id) { $0.title = file.title }
            let staged = try await library.storage.stageSourceFile(file, id: source.id, attemptID: identity.attemptID, sourceURL: source.sourceURL)
            await receive(.downloaded(staged))
        } catch { failure = error }
        sourceTasks[source.id] = nil
        if let current = matching(identity) {
            if current.phase == .pausing {
                update(source.id) { $0.phase = .paused; $0.attemptID = nil; $0.message = current.message ?? "Resume continues partial downloads where the source allows it." }
            } else if current.phase == .cancelling {
                update(source.id) { $0.phase = .cancelled; $0.attemptID = nil; $0.message = nil }
                try? await library.storage.removeSourceWork(id: source.id)
            } else if let failure, !current.phase.isTerminal {
                update(source.id) { $0.phase = .failed; $0.message = failure.localizedDescription }
            }
        }
        if !processing.contains(identity) {
            appDelegate.sourceBackgroundWork.end(identity, success: matching(identity)?.phase == .completed)
        }
        await saveOrReport()
        await schedule()
    }

    private func expireSource(_ identity: TransferIdentity) {
        guard let current = matching(identity), let task = sourceTasks[identity.jobID],
              current.phase.isSourceWorkRunning else { return }
        update(identity.jobID) { $0.phase = .pausing; $0.message = "Paused because iOS ended background time. Resume to continue." }
        task.cancel()
        Task { await saveOrReport() }
    }

    private func finishBackgroundIfReady() {
        guard backgroundEventsFinished, isReady, processing.isEmpty else { return }
        backgroundEventsFinished = false
        appDelegate.finishedBackgroundWork()
    }

    private func job(_ id: UUID) -> DownloadJob? { jobs.first { $0.id == id } }
    private func matching(_ identity: TransferIdentity) -> DownloadJob? { jobs.first { $0.id == identity.jobID && $0.attemptID == identity.attemptID } }
    private func update(_ id: UUID, _ mutation: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
    }
    private func persist() async throws {
        revision += 1
        try await journal.save(DownloadSnapshot(revision: revision, jobs: jobs))
    }
    private func saveOrReport() async {
        do { try await persist() } catch { storageError = "Couldn't save download state. \(error.localizedDescription)" }
    }
}
