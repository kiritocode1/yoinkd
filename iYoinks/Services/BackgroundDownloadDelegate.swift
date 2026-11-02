import Foundation
import YoinksCore

enum DownloadEvent: Sendable {
    case progress(TransferIdentity, received: Int64, expected: Int64?)
    case waiting(TransferIdentity)
    case downloaded(StagedMedia)
    case failed(TransferIdentity, message: String, resumeData: Data?)
    case paused(TransferIdentity, resumeData: Data?)
    case sourceProgress(TransferIdentity, ExtractorProgress)
    case finishedBackgroundEvents
}

/// The delegate queue is serial. Temporary downloads move into durable staging inside the callback.
final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let files: MediaFileStore
    let events: AsyncStream<DownloadEvent>.Continuation

    init(files: MediaFileStore, events: AsyncStream<DownloadEvent>.Continuation) {
        self.files = files
        self.events = events
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let identity = TransferIdentity(taskDescription: downloadTask.taskDescription) else { return }
        events.yield(.progress(identity, received: max(0, totalBytesWritten), expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        if let identity = TransferIdentity(taskDescription: task.taskDescription) { events.yield(.waiting(identity)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = TransferIdentity(taskDescription: downloadTask.taskDescription) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try MediaResponse.validate(statusCode: response.statusCode, finalURL: response.url, mimeType: response.mimeType)
            let name = response.suggestedFilename ?? response.url?.lastPathComponent ?? "Media"
            let originalURL = downloadTask.originalRequest?.url ?? downloadTask.currentRequest?.url ?? response.url
            let staged = try files.stage(from: location, id: identity.jobID, operationID: identity.attemptID,
                                         originalName: name, sourceURL: originalURL, mimeType: response.mimeType, move: true)
            events.yield(.downloaded(staged))
        } catch {
            events.yield(.failed(identity, message: error.localizedDescription, resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let identity = TransferIdentity(taskDescription: task.taskDescription) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        events.yield(.failed(identity, message: error.localizedDescription, resumeData: resumeData))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.yield(.finishedBackgroundEvents)
    }
}
