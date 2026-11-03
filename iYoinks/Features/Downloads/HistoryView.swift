import SwiftUI
import YoinksCore

private enum HistoryFilter: String, CaseIterable {
    case all = "All", video = "Video", audio = "Audio"

    var kind: MediaKind? {
        switch self {
        case .all: nil
        case .video: .video
        case .audio: .audio
        }
    }
}

private enum HistorySort: String, CaseIterable {
    case newest = "Newest first", oldest = "Oldest first", title = "Title", reverseTitle = "Title, Z to A"

    var isChronological: Bool { self == .newest || self == .oldest }
}

private enum HistoryDisplay: String, CaseIterable { case grid = "Grid", list = "List" }

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var showsSearch = false
    @AppStorage("historyFilter") private var filter = HistoryFilter.all
    @AppStorage("historySort") private var sort = HistorySort.newest
    @AppStorage("historyDisplay") private var display = HistoryDisplay.list
    @State private var showsClearHistory = false
    @State private var audioItem: LibraryItem?
    @State private var videoItem: LibraryItem?

    private var history: [DownloadJob] { queue.jobs.filter { $0.phase.isTerminal }.reversed() }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 160), spacing: 12)]
    }

    private var visibleHistory: [DownloadJob] {
        let filtered = history.filter { job in
            (filter.kind == nil || mediaKind(job) == filter.kind) &&
            (search.isEmpty || job.title.localizedCaseInsensitiveContains(search) ||
                job.sourceURL.absoluteString.localizedCaseInsensitiveContains(search) ||
                job.message?.localizedCaseInsensitiveContains(search) == true)
        }
        switch sort {
        case .newest: return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return filtered.sorted { $0.createdAt < $1.createdAt }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .reverseTitle: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }

    private var groups: [(date: Date, jobs: [DownloadJob])] {
        Dictionary(grouping: visibleHistory) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { (date: $0.key, jobs: $0.value) }
            .sorted { sort == .oldest ? $0.date < $1.date : $0.date > $1.date }
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
                    Picker("Media type", selection: $filter) {
                        ForEach(HistoryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .appSegmentedControl()
                    .padding(.horizontal, AppStyle.pageInset)
                    .padding(.vertical, 16)
                    if visibleHistory.isEmpty {
                        ContentUnavailableView {
                            Label("No matching downloads", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try another name or media type.").foregroundStyle(theme.secondaryText)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 20) {
                                if sort.isChronological {
                                    ForEach(groups, id: \.date) { group in
                                        VStack(spacing: display == .grid ? 12 : 0) {
                                            AppSectionBar(title: dateLabel(group.date))
                                            historyEntries(group.jobs)
                                        }
                                    }
                                } else {
                                    historyEntries(visibleHistory)
                                }
                            }
                            .padding(.horizontal, AppStyle.pageInset)
                            .padding(.bottom, AppStyle.pageInset)
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
                if !showsSearch, !history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort by", selection: $sort) {
                                ForEach(HistorySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Picker("Display", selection: $display) {
                                ForEach(HistoryDisplay.allCases, id: \.self) { option in
                                    Label(option.rawValue, systemImage: option == .grid ? "square.grid.2x2" : "list.bullet").tag(option)
                                }
                            }
                        } label: {
                            SortIcon().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Sort and display")
                    }
                    if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                }
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

    @ViewBuilder
    private func historyEntries(_ jobs: [DownloadJob]) -> some View {
        if display == .grid {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(jobs) { job in historyRow(job) }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(jobs) { job in
                    historyRow(job)
                    if job.id != jobs.last?.id { Divider().overlay(theme.separator) }
                }
            }
        }
    }

    private func historyRow(_ job: DownloadJob) -> some View {
        Group {
            if display == .grid {
                VStack(alignment: .leading, spacing: 4) {
                    historyContent(job)
                    HStack(alignment: .top, spacing: 8) {
                        gridMetadata(job)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        historyMenu(job)
                    }
                }
            } else if dynamicTypeSize.isAccessibilitySize {
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
                historyPreview(job, fileDeleted: false)
            }
            .buttonStyle(.plain)
        } else {
            historyPreview(job, fileDeleted: job.phase == .completed)
        }
    }

    @ViewBuilder
    private func historyPreview(_ job: DownloadJob, fileDeleted: Bool) -> some View {
        if display == .grid {
            VStack(alignment: .leading, spacing: 7) {
                gridThumbnail(job, fileDeleted: fileDeleted)
                    .aspectRatio(AppStyle.thumbnailRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
                    .accessibilityHidden(true)
                Text(job.title).font(AppTypography.font(.subheadline, weight: .medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(job.sourceSelection.map { "\($0.kind.rawValue.capitalized), \($0.quality)" } ?? "")
        } else {
            DownloadRow(job: job, fileDeleted: fileDeleted, showsActions: false)
        }
    }

    @ViewBuilder
    private func gridThumbnail(_ job: DownloadJob, fileDeleted: Bool) -> some View {
        if job.phase == .completed, !fileDeleted, let details = library.details[job.id] {
            MediaThumbnail(id: job.id, kind: details.kind)
                .overlay(alignment: .bottomLeading) {
                    Text(MediaPresentation.duration(details.duration))
                        .font(AppTypography.font(.caption2, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule()).padding(6)
                }
        } else {
            ZStack {
                theme.controlBackground
                Image(systemName: gridSymbol(job, fileDeleted: fileDeleted))
                    .font(.system(.title2))
                    .foregroundStyle(job.phase == .failed ? Color.red : fileDeleted ? theme.secondaryText : theme.accent)
            }
        }
    }

    private func gridSymbol(_ job: DownloadJob, fileDeleted: Bool) -> String {
        if fileDeleted { return "doc" }
        switch job.phase {
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        default: return mediaKind(job) == .audio ? "waveform" : "arrow.down.circle"
        }
    }

    private func gridMetadata(_ job: DownloadJob) -> some View {
        let fileDeleted = job.phase == .completed && (try? library.item(id: job.id)) == nil
        return VStack(alignment: .leading, spacing: 5) {
            Text(metadata(job, fileDeleted: fileDeleted)).foregroundStyle(theme.secondaryText)
            if fileDeleted {
                Text("File deleted").foregroundStyle(theme.secondaryText)
            } else if job.phase == .failed || job.phase == .cancelled {
                Text(job.phase == .failed ? "Download failed" : "Cancelled")
                    .foregroundStyle(job.phase == .failed ? Color.red : theme.accent)
            }
            if let message = job.message {
                Text(message).foregroundStyle(job.phase == .failed ? Color.red : theme.secondaryText)
            }
        }
        .font(AppTypography.font(.caption))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func mediaKind(_ job: DownloadJob) -> MediaKind? {
        library.details[job.id]?.kind ?? job.sourceSelection?.kind
    }

    private func metadata(_ job: DownloadJob, fileDeleted: Bool) -> String {
        if let details = library.details[job.id], !fileDeleted {
            return "\(details.kind == .audio ? "Audio" : "Video") · \(MediaPresentation.bytes(details.byteCount))"
        }
        guard let selection = job.sourceSelection else {
            let host = job.sourceURL.host ?? "Media link"
            return job.receivedBytes > 0 ? "\(host) · \(MediaPresentation.bytes(job.receivedBytes))" : host
        }
        let detail = job.receivedBytes > 0 ? MediaPresentation.bytes(job.receivedBytes) : selection.quality
        return "\(selection.kind.rawValue.capitalized) · \(detail)"
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
