import SwiftUI
import YoinksCore

@MainActor
struct DownloadRow: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let job: DownloadJob
    var fileDeleted = false
    var showsActions = true
    var isCard = false
    @ScaledMetric(relativeTo: .caption) private var thumbnailWidth = 88

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    titleAndThumbnail
                    if showsActions { actions }
                }
            } else {
                HStack(alignment: .center, spacing: 2) {
                    titleAndThumbnail
                    if showsActions { actions }
                }
            }
        }
        .padding(.vertical, isCard ? 16 : 12)
        .padding(.horizontal, isCard ? 14 : 0)
        .background {
            if isCard { RoundedRectangle(cornerRadius: 18).fill(theme.surface) }
        }
        .overlay {
            if isCard { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.75).allowsHitTesting(false) }
        }
        .appFiniteReflection(trigger: String(describing: job.phase), enabled: isCard)
        .accessibilityElement(children: .contain)
    }

    private var titleAndThumbnail: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail
                .frame(width: isCard ? thumbnailWidth * 1.2 : thumbnailWidth, height: (isCard ? thumbnailWidth * 1.2 : thumbnailWidth) / AppStyle.thumbnailRatio)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(AppTypography.font(.subheadline, weight: .medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).foregroundStyle(theme.primaryText)
                if job.phase != .downloading {
                    Text(metadata).font(AppTypography.font(.caption)).foregroundStyle(theme.secondaryText)
                }
                progressIndicator
                if !job.phase.isTerminal, job.receivedBytes > 0 {
                    Text(byteSummary).font(AppTypography.font(.caption)).monospacedDigit().foregroundStyle(theme.secondaryText)
                }
                if job.phase != .completed && job.phase != .downloading || fileDeleted {
                    Text(fileDeleted ? "File deleted" : status).font(AppTypography.font(.caption)).foregroundStyle(statusColor)
                }
                if let message = job.message {
                    Text(message).font(AppTypography.font(.caption)).foregroundStyle(job.phase == .failed ? Color.red : theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityValue(job.sourceSelection.map { "\($0.kind.rawValue.capitalized), \($0.quality)" } ?? "")
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if job.phase == .downloading {
            if let fraction = job.progress?.fractionCompleted {
                ProgressView(value: fraction).accessibilityLabel(status)
            } else { ProgressView().accessibilityLabel(status) }
        } else if job.phase == .processing, let fraction = job.processingFraction {
            ProgressView(value: fraction).accessibilityLabel(status)
        } else if [.extracting, .processing, .saving, .pausing, .cancelling].contains(job.phase) {
            ProgressView().accessibilityLabel(status)
        }
    }

    private var metadata: String {
        if let details = library.details[job.id], !fileDeleted {
            return "\(details.kind == .audio ? "Audio" : "Video") · \(MediaPresentation.bytes(details.byteCount))"
        }
        guard let selection = job.sourceSelection else {
            let host = job.sourceURL.host ?? "Media link"
            return job.receivedBytes > 0 && job.phase.isTerminal ? "\(host) · \(MediaPresentation.bytes(job.receivedBytes))" : host
        }
        let detail = job.phase.isTerminal && job.receivedBytes > 0 ? MediaPresentation.bytes(job.receivedBytes) : selection.quality
        return "\(selection.kind.rawValue.capitalized) · \(detail)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if job.phase == .completed, !fileDeleted, let details = library.details[job.id] {
            MediaThumbnail(id: job.id, kind: details.kind)
                .overlay(alignment: .bottomLeading) {
                    Text(MediaPresentation.duration(details.duration))
                        .font(AppTypography.font(.caption2)).monospacedDigit().foregroundStyle(.white)
                        .padding(3).background(.black.opacity(0.65), in: Capsule()).padding(3)
                }
        } else {
            ZStack {
                theme.controlBackground
                if reduceMotion {
                    Image(systemName: job.sourceSelection?.kind == .audio && !fileDeleted ? "waveform" : symbol)
                        .font(.system(.title2)).foregroundStyle(statusColor)
                } else {
                    Image(systemName: job.sourceSelection?.kind == .audio && !fileDeleted ? "waveform" : symbol)
                        .font(.system(.title2)).foregroundStyle(statusColor)
                        .symbolEffect(.bounce, value: job.phase)
                }
            }
        }
    }

    private var actions: some View {
        Group {
            switch job.phase {
            case .extracting, .downloading, .waiting:
                primaryActionMenu("Pause", symbol: "pause.fill") { Task { await queue.pause(job.id) } }
            case .paused:
                primaryActionMenu("Resume", symbol: "play.fill") {
                    Task {
                        do { try await queue.resume(job.id) }
                        catch { queue.storageError = error.localizedDescription }
                    }
                }
            case .processing where job.sourceSelection != nil:
                primaryActionMenu("Pause", symbol: "pause.fill") { Task { await queue.pause(job.id) } }
            case .queued, .failed, .cancelled:
                Menu { actionButtons } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Actions for \(job.title)")
            default:
                EmptyView()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(AppCompactButtonStyle())
    }

    private func primaryActionMenu(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Menu { actionButtons } label: {
            Image(systemName: symbol)
        } primaryAction: { action() }
        .accessibilityLabel("\(title) \(job.title)")
        .accessibilityHint("Touch and hold for download actions")
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.phase {
        case .extracting, .downloading, .waiting:
            Button("Pause", systemImage: "pause") { Task { await queue.pause(job.id) } }
            cancelAction
        case .paused:
            Button("Resume", systemImage: "play") {
                Task {
                    do { try await queue.resume(job.id) }
                    catch { queue.storageError = error.localizedDescription }
                }
            }
            cancelAction
        case .queued:
            cancelAction
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise") {
                Task {
                    do { try await queue.retry(job.id) }
                    catch { queue.storageError = error.localizedDescription }
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { Task { await queue.remove(job.id) } }
        case .completed:
            EmptyView()
        case .processing:
            if job.sourceSelection != nil {
                Button("Pause", systemImage: "pause") { Task { await queue.pause(job.id) } }
                cancelAction
            }
        case .saving, .pausing, .cancelling:
            EmptyView()
        }
    }

    private var cancelAction: some View {
        Button("Cancel download", systemImage: "xmark", role: .destructive) {
            Task { await queue.cancel(job.id) }
        }
    }

    private var byteSummary: String {
        let received = MediaPresentation.bytes(job.receivedBytes)
        guard let expected = job.expectedBytes, job.phase != .completed else { return received }
        return "\(received) / \(MediaPresentation.bytes(expected))"
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
        case .completed: fileDeleted ? theme.secondaryText : theme.accent
        default: theme.accent
        }
    }
}
