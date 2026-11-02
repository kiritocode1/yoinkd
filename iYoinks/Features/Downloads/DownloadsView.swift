import SwiftUI
import YoinksCore

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var library: MediaLibrary
    let onAddLink: () -> Void
    @State private var showsClearHistory = false

    private var active: [DownloadJob] { queue.jobs.filter { !$0.phase.isTerminal } }
    private var history: [DownloadJob] { queue.jobs.filter { $0.phase.isTerminal }.reversed() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeading(title: "Downloads", summary: active.isEmpty ? nil : "\(active.count) \(active.count == 1 ? "transfer" : "transfers")")
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
                if let error = queue.restoreError {
                    ContentUnavailableView {
                        Label("Downloads unavailable", systemImage: "exclamationmark.circle")
                    } description: { Text(error) } actions: {
                        Button("Try again") { Task { await queue.restore() } }
                    }
                } else if queue.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No downloads", systemImage: "arrow.down.circle")
                    } description: { Text("Add a video or audio link to save it on this iPhone.") } actions: {
                        Button("Add link", systemImage: "link") { onAddLink() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if !active.isEmpty {
                            Section("In progress") {
                                ForEach(active) { DownloadRow(job: $0) }
                            }
                        }
                        if !history.isEmpty {
                            Section("History") {
                                ForEach(history) { job in
                                    if job.phase == .completed, let item = try? library.item(id: job.id) {
                                        NavigationLink { MediaDetailView(item: item) } label: { DownloadRow(job: job) }
                                    } else {
                                        DownloadRow(job: job, fileDeleted: job.phase == .completed)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandHeader() }
                ToolbarItem(placement: .topBarLeading) {
                    if !history.isEmpty {
                        Menu {
                            Button("Clear history", systemImage: "trash") { showsClearHistory = true }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("Download history actions")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add link", systemImage: "plus") { onAddLink() }
                }
            }
            .confirmationDialog("Clear download history?", isPresented: $showsClearHistory, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { Task { await queue.clearHistory() } }
            } message: { Text("Saved files stay in your library.") }
            .alert("Download state issue", isPresented: Binding(get: { queue.storageError != nil }, set: { if !$0 { queue.storageError = nil } })) {
                Button("OK", role: .cancel) { queue.storageError = nil }
            } message: { Text(queue.storageError ?? "") }
        }
    }
}
