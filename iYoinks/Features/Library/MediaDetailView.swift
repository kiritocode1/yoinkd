import AVKit
import SwiftUI
import YoinksCore

@MainActor
struct MediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject var item: LibraryItem
    @State private var player: AVPlayer?
    @State private var fileURL: URL?
    @State private var playbackError: String?
    @State private var loadRequest = 0
    @State private var showsRename = false
    @State private var renameText = ""
    @State private var showsDelete = false
    @State private var isDeleting = false

    private var isRemoved: Bool { item.isDeleted || item.managedObjectContext == nil }

    var body: some View {
        Group {
            if isRemoved { ProgressView() } else { mediaContent }
        }
        .navigationTitle(isRemoved ? "Media" : item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isRemoved { theme.selectMedia(id: item.id, storage: library.storage) }
        }
        .onChange(of: isRemoved) { _, removed in
            if removed { player?.pause(); dismiss() }
        }
    }

    private var mediaContent: some View {
        List {
            Section {
                if let player {
                    VideoPlayer(player: player) {
                        if item.mediaKind == .audio {
                            MediaThumbnail(id: item.id, kind: .audio).allowsHitTesting(false)
                        }
                    }
                    .aspectRatio(1.5, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
                } else if let playbackError {
                    ContentUnavailableView {
                        Label("Can't play this file", systemImage: "exclamationmark.circle")
                    } description: { Text(playbackError) } actions: {
                        Button("Try again") { loadRequest += 1 }
                    }
                } else {
                    ProgressView("Opening media").frame(maxWidth: .infinity).padding()
                }
            }
            Section {
                Text(item.title).font(.title2.bold()).textSelection(.enabled)
                if let details = library.details[item.id] {
                    LabeledContent("Type", value: details.kind == .video ? "Video" : "Audio")
                    LabeledContent("Duration", value: MediaPresentation.duration(details.duration))
                    LabeledContent("File size", value: MediaPresentation.bytes(details.byteCount))
                }
                LabeledContent("Format", value: URL(fileURLWithPath: item.relativeFileName).pathExtension.uppercased())
                LabeledContent("Added", value: item.addedAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Source", value: item.sourceURL?.host ?? "Imported from Files")
            }
            if let fileURL {
                Section {
                    ShareLink(item: SharedMedia(url: fileURL, title: item.title, kind: item.mediaKind ?? .video),
                              preview: SharePreview(item.title)) {
                        Label("Share file", systemImage: "square.and.arrow.up")
                    }
                    Button("Rename", systemImage: "pencil") { renameText = item.title; showsRename = true }
                    Button("Delete file", systemImage: "trash", role: .destructive) { showsDelete = true }.disabled(isDeleting)
                }
            }
        }
        .task(id: loadRequest) { await openPlayer() }
        .onDisappear {
            player?.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        .alert("Rename media", isPresented: $showsRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                do { try library.rename(item, to: renameText) } catch { library.errorMessage = error.localizedDescription }
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this file?", isPresented: $showsDelete, titleVisibility: .visible) {
            Button("Delete file", role: .destructive) {
                isDeleting = true
                player?.pause()
                Task {
                    do { try await library.delete(item); dismiss() } catch {
                        library.errorMessage = error.localizedDescription
                        isDeleting = false
                    }
                }
            }
        } message: { Text("This removes the saved copy from iYoinks.") }
    }

    private func openPlayer() async {
        guard !isRemoved else { return }
        playbackError = nil
        do {
            let url = try await library.playbackURL(for: item)
            try Task.checkCancellation()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: item.mediaKind == .audio ? .default : .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            fileURL = url
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        } catch {
            if !Task.isCancelled { playbackError = error.localizedDescription }
        }
    }
}
