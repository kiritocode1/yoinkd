import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct YoinkActivityBundle: WidgetBundle {
    var body: some Widget { DownloadActivityWidget() }
}

/// A running download on the Lock Screen and in the Dynamic Island: title, status, progress, and
/// a pause or resume button.
struct DownloadActivityWidget: Widget {
    /// Sage, the app's default accent, readable on the dark Lock Screen and Dynamic Island.
    private static let accent = Color(red: 0.55, green: 0.78, blue: 0.62)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 14) {
                symbol(context.attributes, context.state).font(.title2).foregroundStyle(Self.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                    progress(context.state)
                    Text(subtitle(context.state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !context.state.isFinished { toggle(context.attributes, context.state) }
            }
            .padding(16)
            .activityBackgroundTint(.black.opacity(0.75))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    symbol(context.attributes, context.state).font(.title2).foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isFinished { toggle(context.attributes, context.state) }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        progress(context.state)
                        Text(subtitle(context.state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                symbol(context.attributes, context.state).foregroundStyle(Self.accent)
            } compactTrailing: {
                if let fraction = context.state.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(Self.accent)
                } else {
                    Image(systemName: context.state.isPaused ? "pause.fill" : "ellipsis").foregroundStyle(Self.accent)
                }
            } minimal: {
                symbol(context.attributes, context.state).foregroundStyle(Self.accent)
            }
        }
    }

    private func symbol(_ attributes: DownloadActivityAttributes, _ state: DownloadActivityAttributes.ContentState) -> Image {
        if state.isFinished { return Image(systemName: "checkmark.circle.fill") }
        if state.isPaused { return Image(systemName: "pause.circle.fill") }
        return Image(systemName: attributes.isAudio ? "waveform.circle.fill" : "arrow.down.circle.fill")
    }

    @ViewBuilder
    private func progress(_ state: DownloadActivityAttributes.ContentState) -> some View {
        if let fraction = state.fraction {
            ProgressView(value: fraction).tint(Self.accent)
        } else if !state.isFinished {
            ProgressView(value: 0).tint(Self.accent).opacity(0.4)
        }
    }

    private func subtitle(_ state: DownloadActivityAttributes.ContentState) -> String {
        state.detail.isEmpty ? state.status : "\(state.status) · \(state.detail)"
    }

    private func toggle(_ attributes: DownloadActivityAttributes, _ state: DownloadActivityAttributes.ContentState) -> some View {
        Button(intent: ToggleDownloadIntent(jobID: attributes.jobID)) {
            Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPaused ? "Resume" : "Pause")
        .tint(Self.accent)
    }
}
