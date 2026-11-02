import SwiftUI
import YoinksCore

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var showsClearHistory = false

    private var history: [DownloadJob] { queue.jobs.filter { $0.phase.isTerminal }.reversed() }

    private var visibleHistory: [DownloadJob] {
        history.filter { job in
            search.isEmpty || job.title.localizedCaseInsensitiveContains(search) ||
                job.sourceURL.absoluteString.localizedCaseInsensitiveContains(search) ||
                job.message?.localizedCaseInsensitiveContains(search) == true
        }
    }

    private var groups: [(date: Date, jobs: [DownloadJob])] {
        Dictionary(grouping: visibleHistory) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { (date: $0.key, jobs: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var savedBytes: Int64 {
        history.filter { $0.phase == .completed }.reduce(0) { $0 + $1.receivedBytes }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = queue.restoreError {
                    ContentUnavailableView {
                        Label("History unavailable", systemImage: "exclamationmark.circle")
                    } description: { Text(error) } actions: {
                        Button("Try again") { Task { await queue.restore() } }.buttonStyle(AppPrimaryButtonStyle())
                    }
                } else if !queue.isReady {
                    ProgressView("Opening history...").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if history.isEmpty {
                    ContentUnavailableView {
                        Label("No download history", systemImage: "clock.arrow.circlepath")
                    } description: { Text("Completed, failed, and cancelled downloads appear here.") }
                } else {
                    Text("\(history.count) \(history.count == 1 ? "download" : "downloads"), \(MediaPresentation.bytes(savedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 8)
                    if visibleHistory.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        List {
                            ForEach(groups, id: \.date) { group in
                                Section(dateLabel(group.date)) {
                                    ForEach(group.jobs) { job in
                                        historyRow(job).listRowBackground(AppStyle.surface)
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .background(AppStyle.background)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search downloads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !history.isEmpty {
                        Menu {
                            Button("Clear history", systemImage: "trash", role: .destructive) { showsClearHistory = true }
                        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("History actions")
                    }
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

    private func historyRow(_ job: DownloadJob) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    historyContent(job)
                    historyMenu(job)
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    historyContent(job)
                    historyMenu(job)
                }
            }
        }
        .contextMenu { historyActions(job) }
    }

    @ViewBuilder
    private func historyContent(_ job: DownloadJob) -> some View {
        if job.phase == .completed, let item = try? library.item(id: job.id) {
            NavigationLink { MediaDetailView(item: item) } label: {
                DownloadRow(job: job, showsActions: false)
            }
        } else {
            DownloadRow(job: job, fileDeleted: job.phase == .completed, showsActions: false)
        }
    }

    private func historyMenu(_ job: DownloadJob) -> some View {
        Menu { historyActions(job) } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Actions for \(job.title)")
    }

    @ViewBuilder
    private func historyActions(_ job: DownloadJob) -> some View {
        if job.phase == .failed || job.phase == .cancelled {
            Button("Retry", systemImage: "arrow.clockwise") { Task { await queue.retry(job.id) } }
        }
        Button("Remove from history", systemImage: "trash", role: .destructive) { Task { await queue.remove(job.id) } }
    }

    private func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
