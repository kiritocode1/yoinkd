import SwiftUI
import YoinksCore

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var showsSearch = false
    @State private var showsClearHistory = false
    @State private var audioItem: LibraryItem?
    @State private var videoItem: LibraryItem?

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
                if !showsSearch, !history.isEmpty {
                    Text("\(history.count) \(history.count == 1 ? "download" : "downloads"), \(MediaPresentation.bytes(savedBytes))")
                        .font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                }
                if let error = queue.restoreError {
                    ContentUnavailableView {
                        Label("History unavailable", systemImage: "exclamationmark.circle")
                    } description: { Text(error).foregroundStyle(theme.secondaryText) } actions: {
                        Button("Try again") { Task { await queue.restore() } }.buttonStyle(AppPrimaryButtonStyle())
                    }
                } else if !queue.isReady {
                    ProgressView("Opening history...").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if history.isEmpty {
                    ContentUnavailableView {
                        Label("No download history", systemImage: "clock.arrow.circlepath")
                    } description: { Text("Completed, failed, and cancelled downloads appear here.").foregroundStyle(theme.secondaryText) }
                } else {
                    if visibleHistory.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 20) {
                                ForEach(groups, id: \.date) { group in
                                    VStack(spacing: 0) {
                                        AppSectionBar(title: dateLabel(group.date))
                                        ForEach(group.jobs) { job in
                                            historyRow(job)
                                            if job.id != group.jobs.last?.id { Divider().overlay(theme.separator) }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .foregroundStyle(theme.primaryText)
            .background(theme.background)
            .appTabContent(for: .history)
            .appNativeChrome()
            .navigationTitle(showsSearch ? "" : "History")
            .toolbarTitleDisplayMode(.inlineLarge)
            .appToolbarSearch(text: $search, isPresented: $showsSearch, prompt: "Search downloads")
            .navigationDestination(item: $videoItem) { MediaDetailView(item: $0) }
            .sheet(item: $audioItem) { item in
                MediaDetailView(item: item)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .toolbar {
                if #available(iOS 26, *) {
                    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                }
                if !history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear history", systemImage: "trash", role: .destructive) { showsClearHistory = true }
                        } label: { Label("History actions", systemImage: "ellipsis") }
                        .labelStyle(.iconOnly)
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
                HStack(alignment: .center, spacing: 0) {
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
            Button {
                showsSearch = false
                if item.mediaKind == .audio { audioItem = item }
                else { videoItem = item }
            } label: {
                DownloadRow(job: job, showsActions: false)
            }
            .buttonStyle(.plain)
        } else {
            DownloadRow(job: job, fileDeleted: job.phase == .completed, showsActions: false)
        }
    }

    private func historyMenu(_ job: DownloadJob) -> some View {
        Menu { historyActions(job) } label: { Label("Actions for \(job.title)", systemImage: "ellipsis") }
        .labelStyle(.iconOnly)
        .buttonStyle(AppCompactButtonStyle())
        .accessibilityLabel("Actions for \(job.title)")
    }

    @ViewBuilder
    private func historyActions(_ job: DownloadJob) -> some View {
        if job.phase == .failed || job.phase == .cancelled {
            Button("Retry", systemImage: "arrow.clockwise") {
                Task {
                    do { try await queue.retry(job.id) }
                    catch { queue.storageError = error.localizedDescription }
                }
            }
        }
        Button("Remove from history", systemImage: "trash", role: .destructive) { Task { await queue.remove(job.id) } }
    }

    private func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
