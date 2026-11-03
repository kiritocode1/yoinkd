import AVKit
import Combine
import Foundation

@MainActor
final class MediaPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var fileURL: URL?
    @Published private(set) var error: String?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    private var timeObserver: Any?
    private var requestID = UUID()
    private var mediaID: UUID?

    func open(_ item: LibraryItem, library: MediaLibrary) async {
        guard player == nil || mediaID != item.id else { return }
        close()
        error = nil
        mediaID = item.id
        let request = requestID
        do {
            let url = try await library.playbackURL(for: item)
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration).seconds
            try Task.checkCancellation()
            guard request == requestID, !item.isDeleted else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: item.mediaKind == .audio ? .default : .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let opened = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            fileURL = url
            duration = length.isFinite && length > 0 ? length : library.details[item.id]?.duration ?? 0
            player = opened
            timeObserver = opened.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == request else { return }
                    self.currentTime = time.seconds.isFinite ? max(0, min(time.seconds, self.duration)) : 0
                    self.isPlaying = self.player?.timeControlStatus == .playing
                    if let failure = self.player?.currentItem?.error { self.error = failure.localizedDescription }
                }
            }
            opened.play()
            isPlaying = true
        } catch {
            if !Task.isCancelled, request == requestID { self.error = error.localizedDescription }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else {
            if currentTime >= duration, duration > 0 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func close() {
        requestID = UUID()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        fileURL = nil
        mediaID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
