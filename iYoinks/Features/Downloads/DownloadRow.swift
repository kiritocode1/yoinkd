import SwiftUI
import YoinksCore

@MainActor
struct DownloadRow: View {
    @EnvironmentObject private var queue: DownloadQueue
    let job: DownloadJob
    var fileDeleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(statusColor)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.headline).lineLimit(2)
                    Text(job.sourceURL.host ?? "Media link").font(.caption).foregroundStyle(.secondary)
                    if let selection = job.sourceSelection {
                        Text("\(selection.kind.rawValue.capitalized) · \(selection.quality)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(fileDeleted ? "File deleted" : status).font(.subheadline)
                Spacer()
                if job.receivedBytes > 0 { Text(byteSummary).font(.caption).foregroundStyle(.secondary) }
            }
            if job.phase == .downloading {
                if let fraction = job.progress?.fractionCompleted { ProgressView(value: fraction) }
                else { ProgressView() }
            } else if job.phase == .processing, let fraction = job.processingFraction {
                ProgressView(value: fraction)
            } else if [.extracting, .processing, .saving, .pausing, .cancelling].contains(job.phase) {
                ProgressView()
            }
            if let message = job.message { Text(message).font(.caption).foregroundStyle(job.phase == .failed ? .red : .secondary) }
            actions
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { actionButtons }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading) { actionButtons }
        }
        .buttonStyle(.bordered).controlSize(.large)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.phase {
        case .extracting, .downloading, .waiting:
            Button("Pause", systemImage: "pause") { Task { await queue.pause(job.id) } }
            Button("Cancel", role: .destructive) { Task { await queue.cancel(job.id) } }
        case .paused:
            Button("Resume", systemImage: "play") { Task { await queue.resume(job.id) } }
            Button("Cancel", role: .destructive) { Task { await queue.cancel(job.id) } }
        case .queued:
            Button("Cancel", role: .destructive) { Task { await queue.cancel(job.id) } }
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise") { Task { await queue.retry(job.id) } }
            Button("Remove", role: .destructive) { Task { await queue.remove(job.id) } }
        case .completed:
            EmptyView()
        case .processing:
            if job.sourceSelection != nil {
                Button("Pause", systemImage: "pause") { Task { await queue.pause(job.id) } }
                Button("Cancel", role: .destructive) { Task { await queue.cancel(job.id) } }
            }
        case .saving, .pausing, .cancelling:
            EmptyView()
        }
    }

    private var byteSummary: String {
        let received = MediaPresentation.bytes(job.receivedBytes)
        guard let expected = job.expectedBytes, job.phase != .completed else { return received }
        return "\(received) of \(MediaPresentation.bytes(expected))"
    }

    private var status: String {
        switch job.phase {
        case .queued: "Queued"
        case .extracting: "Checking source"
        case .downloading: "Downloading"
        case .waiting: "Waiting for connection"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .processing: "Preparing media"
        case .saving: "Saving to library"
        case .completed: "Saved to library"
        case .failed: "Download failed"
        case .cancelled: "Cancelled"
        case .cancelling: "Cancelling"
        }
    }

    private var symbol: String {
        switch job.phase {
        case .completed: fileDeleted ? "doc" : "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .paused, .pausing: "pause.circle"
        case .cancelled: "xmark.circle"
        default: "arrow.down.circle"
        }
    }

    private var statusColor: Color {
        switch job.phase {
        case .failed: .red
        case .completed: fileDeleted ? .secondary : .green
        default: .purple
        }
    }
}
