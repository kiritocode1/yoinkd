import SwiftUI
import YoinksCore

@MainActor
struct DownloadRow: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let job: DownloadJob
    var fileDeleted = false
    var showsActions = true
    @ScaledMetric(relativeTo: .subheadline) private var thumbnailWidth = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    titleAndThumbnail
                    if showsActions { actions }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    titleAndThumbnail
                    if showsActions { actions }
                }
            }
            if job.phase == .downloading {
                if let fraction = job.progress?.fractionCompleted { ProgressView(value: fraction) }
                else { ProgressView() }
            } else if job.phase == .processing, let fraction = job.processingFraction {
                ProgressView(value: fraction)
            } else if [.extracting, .processing, .saving, .pausing, .cancelling].contains(job.phase) {
                ProgressView()
            }
            if job.receivedBytes > 0 {
                Text(byteSummary).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            if let message = job.message { Text(message).font(.caption).foregroundStyle(job.phase == .failed ? Color.red : Color.secondary) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var titleAndThumbnail: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: thumbnailWidth, height: thumbnailWidth / 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                if let selection = job.sourceSelection {
                    Text("\(selection.kind.rawValue.capitalized) · \(selection.quality)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(job.sourceURL.host ?? "Media link").font(.caption).foregroundStyle(.secondary)
                }
                if job.phase != .completed || fileDeleted {
                    Text(fileDeleted ? "File deleted" : status).font(.caption).foregroundStyle(statusColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if job.phase == .completed, !fileDeleted, let details = library.details[job.id] {
            MediaThumbnail(id: job.id, kind: details.kind)
                .overlay(alignment: .bottomLeading) {
                    Text(MediaPresentation.duration(details.duration))
                        .font(.caption2).monospacedDigit().foregroundStyle(.white)
                        .padding(3).background(.black.opacity(0.65), in: Capsule()).padding(3)
                }
        } else {
            ZStack {
                AppStyle.controlBackground
                Image(systemName: job.sourceSelection?.kind == .audio && !fileDeleted ? "waveform" : symbol)
                    .font(.title2).foregroundStyle(statusColor)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            actionButtons
        }
        .labelStyle(.iconOnly)
        .buttonStyle(AppSecondaryButtonStyle())
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.phase {
        case .extracting, .downloading, .waiting:
            Button("Pause", systemImage: "pause") { Task { await queue.pause(job.id) } }
            cancelMenu
        case .paused:
            Button("Resume", systemImage: "play") { Task { await queue.resume(job.id) } }
            cancelMenu
        case .queued:
            cancelMenu
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise") { Task { await queue.retry(job.id) } }
            Button("Remove", systemImage: "trash", role: .destructive) { Task { await queue.remove(job.id) } }
        case .completed:
            EmptyView()
        case .processing:
            if job.sourceSelection != nil {
                Button("Pause", systemImage: "pause") { Task { await queue.pause(job.id) } }
                cancelMenu
            }
        case .saving, .pausing, .cancelling:
            EmptyView()
        }
    }

    private var cancelMenu: some View {
        Menu {
            Button("Cancel download", systemImage: "xmark", role: .destructive) { Task { await queue.cancel(job.id) } }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(job.title)")
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
        case .completed: fileDeleted ? .secondary : theme.accent
        default: theme.accent
        }
    }
}
