import SwiftUI
import YoinksCore

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var theme: AppTheme
    let onAddLink: () -> Void

    private var active: [DownloadJob] { queue.jobs.filter { !$0.phase.isTerminal && $0.phase != .queued } }
    private var queued: [DownloadJob] { queue.jobs.filter { $0.phase == .queued } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = queue.restoreError {
                    ContentUnavailableView {
                        Label("Downloads unavailable", systemImage: "exclamationmark.circle")
                    } description: { Text(error).foregroundStyle(theme.secondaryText) } actions: {
                        Button("Try again") { Task { await queue.restore() } }.buttonStyle(AppPrimaryButtonStyle())
                    }
                } else if !queue.isReady {
                    ProgressView("Opening downloads...").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if active.isEmpty && queued.isEmpty {
                    emptyDownloads
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            if !active.isEmpty { downloadSection("Active (\(active.count))", jobs: active) }
                            if !queued.isEmpty { downloadSection("Queued (\(queued.count))", jobs: queued) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
            .foregroundStyle(theme.primaryText)
            .background(theme.background)
            .appTabContent(for: .downloads)
            .appNativeChrome()
            .navigationTitle("Downloads")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("yoink!", systemImage: "plus") { onAddLink() }
                    } label: { Label("Download actions", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly)
                }
            }
            .alert("Download state issue", isPresented: Binding(get: { queue.storageError != nil }, set: { if !$0 { queue.storageError = nil } })) {
                Button("OK", role: .cancel) { queue.storageError = nil }
            } message: { Text(queue.storageError ?? "") }
        }
    }

    private var emptyDownloads: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(theme.controlBackground)
                        .frame(width: 112, height: 112)
                        .rotationEffect(.degrees(-8))
                        .offset(x: -15, y: 5)
                    RoundedRectangle(cornerRadius: 24)
                        .fill(LinearGradient(colors: [theme.controlBackground, theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 112, height: 124)
                        .overlay {
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                        }
                        .appFiniteReflection(trigger: "empty-downloads", cornerRadius: 24)
                    Image(systemName: "arrow.down").font(.system(size: 42, weight: .light)).foregroundStyle(theme.primaryText)
                }
                .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("No active downloads").font(AppTypography.font(.title2, weight: .semibold))
                    Text("Add a link to start downloading videos or audio.")
                        .font(AppTypography.font(.callout)).foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                Button("yoink!", systemImage: "plus") { onAddLink() }
                    .buttonStyle(AppPrimaryButtonStyle()).controlSize(.large)
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        ForEach(SupportedPlatform.allCases, id: \.self) { platform in
                            PlatformIcon(platform: platform)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("YouTube, Instagram, X, TikTok, and other supported sites")
                    Text("Supports YouTube, Instagram, X, TikTok, and other supported sites.")
                        .font(AppTypography.font(.caption)).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
    }

    private func downloadSection(_ title: String, jobs: [DownloadJob]) -> some View {
        VStack(spacing: 12) {
            AppSectionBar(title: title)
            ForEach(jobs) { job in
                DownloadRow(job: job, isCard: true)
            }
        }
    }
}
