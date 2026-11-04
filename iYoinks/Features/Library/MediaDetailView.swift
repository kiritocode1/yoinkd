import AVKit
import MediaPlayer
import SwiftUI
import YoinksCore

@MainActor
struct MediaDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject var item: LibraryItem
    @StateObject private var playback = MediaPlayback()
    @State private var loadRequest = 0
    @State private var showsInfo = false
    @State private var showsFullscreen = false
    @State private var showsRename = false
    @State private var renameText = ""
    @State private var showsDelete = false
    @State private var isDeleting = false
    @State private var isScrubbing = false
    @State private var seekTime = 0.0
    @State private var photosOutcome: PhotosSaver.Outcome?
    @ScaledMetric(relativeTo: .headline) private var actionLabelHeight: CGFloat = 44

    private var isRemoved: Bool { item.isDeleted || item.managedObjectContext == nil }
    private var isAudio: Bool { item.mediaKind == .audio }
    private var artist: String {
        guard let artist = library.details[item.id]?.artist, !artist.isEmpty else { return "Saved audio" }
        return artist
    }

    var body: some View {
        Group {
            if isRemoved { ProgressView() }
            else if isAudio { audioPlayer }
            else { videoPlayer }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isRemoved {
                mediaActions
                    .frame(maxWidth: 462)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(theme.background)
            }
        }
        .foregroundStyle(theme.primaryText)
        .background(theme.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: theme.palette)
        .appNativeChrome()
        .navigationTitle(isAudio || isRemoved ? "" : item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadRequest) {
            guard !isRemoved else { return }
            theme.selectMedia(id: item.id, storage: library.storage)
            await playback.open(item, library: library)
        }
        .onDisappear { if !showsFullscreen { playback.close() } }
        .onChange(of: isRemoved) { _, removed in
            if removed { playback.close(); dismiss() }
        }
        .onChange(of: playback.currentTime) { _, time in if !isScrubbing { seekTime = time } }
        .sheet(isPresented: $showsInfo) {
            infoSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showsFullscreen) {
            if let player = playback.player {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    VideoPlayer(player: player).ignoresSafeArea()
                    Button("Close full screen", systemImage: "xmark") { showsFullscreen = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(AppCompactButtonStyle())
                        .padding(20)
                }
                .statusBarHidden()
            }
        }
    }

    private var audioPlayer: some View {
        GeometryReader { geometry in
            let availableHeight = max(1, geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom)
            let availableWidth = geometry.size.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing - 40
            let artworkSize = max(1, min(availableWidth, availableHeight * 0.42, 360))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MediaThumbnail(id: item.id, kind: .audio)
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(AppTypography.font(.title2, weight: .semibold))
                            .lineLimit(2).textSelection(.enabled)
                        Text(artist).font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                    }
                    if let error = playback.error { playbackFailure(error) }
                    else if playback.player == nil {
                        ProgressView("Opening audio").frame(maxWidth: .infinity)
                    } else {
                        audioControls
                        SystemVolumeSlider().frame(height: 44)
                    }
                }
                .frame(maxWidth: 462)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .background {
                LinearGradient(colors: [theme.surface, theme.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
        }
    }

    private var audioControls: some View {
        VStack(spacing: 16) {
            VStack(spacing: 3) {
                Slider(value: $seekTime, in: 0...max(playback.duration, 1)) { editing in
                    isScrubbing = editing
                    if !editing { playback.seek(to: seekTime) }
                }
                .tint(theme.secondaryText)
                .accessibilityLabel("Playback position")
                .accessibilityValue(MediaPresentation.duration(seekTime))
                HStack {
                    Text(MediaPresentation.duration(seekTime))
                    Spacer()
                    Text(playback.fileURL?.pathExtension.uppercased() ?? "Audio")
                    Spacer()
                    Text("-" + MediaPresentation.duration(max(0, playback.duration - seekTime)))
                }
                .font(AppTypography.font(.caption)).monospacedDigit().foregroundStyle(theme.secondaryText)
            }
            HStack {
                playbackButton("Back 15 seconds", symbol: "gobackward.15", size: 30) { playback.skip(-15) }
                Spacer()
                playbackButton(playback.isPlaying ? "Pause" : "Play", symbol: playback.isPlaying ? "pause.fill" : "play.fill", size: 44) {
                    playback.togglePlayback()
                }
                Spacer()
                playbackButton("Forward 15 seconds", symbol: "goforward.15", size: 30) { playback.skip(15) }
            }
            .padding(.horizontal, 20)
        }
    }

    private func playbackButton(_ title: String, symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 64, height: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var videoPlayer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = playback.error { playbackFailure(error) }
                else if let player = playback.player {
                    VideoPlayer(player: player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") { showsFullscreen = true }
                        .buttonStyle(AppSecondaryButtonStyle())
                } else { ProgressView("Opening video").frame(maxWidth: .infinity).padding(.vertical, 60) }
                Text(item.title).font(AppTypography.font(.title2, weight: .semibold)).textSelection(.enabled)
                if let details = library.details[item.id] {
                    Text("\(MediaPresentation.duration(details.duration)) · \(MediaPresentation.bytes(details.byteCount))")
                        .font(AppTypography.font(.subheadline)).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(20)
        }
    }

    private var mediaActions: some View {
        HStack(spacing: 18) {
            Button { showsInfo = true } label: {
                mediaActionLabel("Info", symbol: "info.circle")
            }
            .buttonStyle(AppSecondaryButtonStyle())
            if let fileURL = playback.fileURL {
                ShareLink(item: SharedMedia(url: fileURL, title: item.title, kind: item.mediaKind ?? .video), preview: SharePreview(item.title)) {
                    mediaActionLabel("Share", symbol: "square.and.arrow.up")
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
        }
        .controlSize(.regular)
    }

    private func mediaActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(AppTypography.font(.headline))
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: actionLabelHeight)
    }

    private func playbackFailure(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Can't play this file", systemImage: "exclamationmark.circle")
        } description: { Text(error).foregroundStyle(theme.secondaryText) } actions: {
            Button("Try again") { playback.close(); loadRequest += 1 }
                .buttonStyle(AppPrimaryButtonStyle())
        }
    }

    private var infoSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.title).font(AppTypography.font(.headline)).textSelection(.enabled)
                    if let artist = library.details[item.id]?.artist, !artist.isEmpty { LabeledContent("Artist", value: artist) }
                    if let details = library.details[item.id] {
                        LabeledContent("Type", value: details.kind == .audio ? "Audio" : "Video")
                        LabeledContent("Duration", value: MediaPresentation.duration(details.duration))
                        LabeledContent("File size", value: MediaPresentation.bytes(details.byteCount))
                    }
                    LabeledContent("Format", value: URL(fileURLWithPath: item.relativeFileName).pathExtension.uppercased())
                    LabeledContent("Added", value: item.addedAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Source", value: item.sourceURL?.host ?? "Imported from Files")
                }
                .listRowBackground(theme.surface)
                .listRowSeparatorTint(theme.separator)
                Section {
                    if let fileURL = playback.fileURL {
                        ShareLink(item: SharedMedia(url: fileURL, title: item.title, kind: item.mediaKind ?? .video), preview: SharePreview(item.title)) {
                            Label("Share file", systemImage: "square.and.arrow.up")
                        }
                        if !isAudio {
                            Button("Save to Photos", systemImage: "photo.badge.plus") {
                                Task { photosOutcome = await PhotosSaver.save(videoAt: fileURL) }
                            }
                        }
                    }
                    Button("Rename", systemImage: "pencil") { renameText = item.title; showsRename = true }
                    Button("Delete file", systemImage: "trash", role: .destructive) { showsDelete = true }.disabled(isDeleting)
                }
                .listRowBackground(theme.surface)
                .listRowSeparatorTint(theme.separator)
            }
            .font(AppTypography.font(.body))
            .foregroundStyle(theme.primaryText, theme.secondaryText)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .appNativeChrome()
            .navigationTitle("File info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showsInfo = false } }
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
                    playback.close()
                    Task {
                        do { try await library.delete(item); showsInfo = false; dismiss() }
                        catch { library.errorMessage = error.localizedDescription; isDeleting = false; loadRequest += 1 }
                    }
                }
            } message: { Text("This removes the saved copy from yoink'd.") }
            .alert(photosOutcome?.title ?? "", isPresented: Binding(get: { photosOutcome != nil }, set: { if !$0 { photosOutcome = nil } })) {
                Button("OK", role: .cancel) { photosOutcome = nil }
            } message: { Text(photosOutcome?.message ?? "") }
        }
    }
}

@MainActor
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.accessibilityLabel = "Playback volume"
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
