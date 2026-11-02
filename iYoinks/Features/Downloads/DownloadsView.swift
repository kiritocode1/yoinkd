import SwiftUI
import YoinksCore

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var queue: DownloadQueue
    let onAddLink: () -> Void

    private var active: [DownloadJob] { queue.jobs.filter { !$0.phase.isTerminal && $0.phase != .queued } }
    private var queued: [DownloadJob] { queue.jobs.filter { $0.phase == .queued } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = queue.restoreError {
                    ContentUnavailableView {
                        Label("Downloads unavailable", systemImage: "exclamationmark.circle")
                    } description: { Text(error) } actions: {
                        Button("Try again") { Task { await queue.restore() } }.buttonStyle(AppPrimaryButtonStyle())
                    }
                } else if !queue.isReady {
                    ProgressView("Opening downloads...").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if active.isEmpty && queued.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, height: 80)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08))
                            }
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                            .accessibilityHidden(true)
                        Text("No active downloads")
                    } description: { Text("Add a video or audio link to save it on this iPhone.") } actions: {
                        Button("Add link", systemImage: "plus") { onAddLink() }.buttonStyle(AppPrimaryButtonStyle())
                        Text("YouTube · Instagram · X")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(AppStyle.controlBackground, in: Capsule())
                            .padding(.top, 8)
                    }
                } else {
                    List {
                        if !active.isEmpty {
                            Section("Active (\(active.count))") {
                                ForEach(active) { DownloadRow(job: $0).listRowBackground(AppStyle.surface) }
                            }
                        }
                        if !queued.isEmpty {
                            Section("Queued (\(queued.count))") {
                                ForEach(queued) { DownloadRow(job: $0).listRowBackground(AppStyle.surface) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppStyle.background)
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add link", systemImage: "plus") { onAddLink() }.frame(minWidth: 44, minHeight: 44)
                }
            }
            .alert("Download state issue", isPresented: Binding(get: { queue.storageError != nil }, set: { if !$0 { queue.storageError = nil } })) {
                Button("OK", role: .cancel) { queue.storageError = nil }
            } message: { Text(queue.storageError ?? "") }
        }
    }
}
