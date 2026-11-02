import SwiftUI
import YoinksCore

@MainActor
final class AppTheme: ObservableObject {
    @Published private(set) var theme: AccentTheme
    @Published private(set) var palette: AccentPalette
    @Published private(set) var selectedMediaID: UUID?
    private let preferences: ThemePreferences
    private let cache = ArtworkPaletteCache()
    private var selection = AccentSelection()
    private var libraryStorage: MediaStorage?
    private var preview: (url: URL?, id: String)?
    private var extractionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        let preferences = ThemePreferences(defaults: defaults)
        self.preferences = preferences
        theme = preferences.theme
        palette = preferences.theme.palette
    }

    var accent: Color { appearanceColor(light: palette.light, dark: palette.dark) }

    var onAccent: Color {
        let light = palette.light.contrast(with: .white) >= 4.5 ? AccentRGB.white : .black
        let dark = palette.dark.contrast(with: .black) >= 4.5 ? AccentRGB.black : .white
        return appearanceColor(light: light, dark: dark)
    }

    func setTheme(_ theme: AccentTheme) {
        guard self.theme != theme else { return }
        preferences.theme = theme
        self.theme = theme
        palette = theme == .dynamic ? selection.palette : theme.palette
        if theme == .dynamic { resolveSelection() }
    }

    func selectMedia(id: UUID, storage: MediaStorage) {
        guard selectedMediaID != id || preview != nil else { return }
        selectedMediaID = id
        libraryStorage = storage
        preview = nil
        resolveSelection()
    }

    func retainSelection(in ids: Set<UUID>) {
        guard let selectedMediaID, !ids.contains(selectedMediaID) else { return }
        self.selectedMediaID = nil
        libraryStorage = nil
        resolveSelection()
    }

    func previewArtwork(url: URL?, id: String) {
        preview = (url, id)
        resolveSelection()
    }

    func endPreview() {
        guard preview != nil else { return }
        preview = nil
        resolveSelection()
    }

    private func resolveSelection() {
        let key: String?
        if let preview { key = "preview:\(preview.id):\(preview.url?.absoluteString ?? "none")" }
        else { key = selectedMediaID.map { "library:\($0.uuidString)" } }
        let changed = selection.select(key)
        if changed { extractionTask?.cancel(); extractionTask = nil }
        guard theme == .dynamic else { return }
        guard let key else { palette = .neutral; return }
        guard changed || extractionTask == nil else { return }
        let requestID = selection.requestID
        let previewURL = preview?.url
        let isPreview = preview != nil
        let mediaID = selectedMediaID
        let storage = libraryStorage
        let cache = cache
        extractionTask = Task {
            let extracted: AccentPalette
            if let cached = await cache.cachedPalette(for: key) {
                extracted = cached
            } else {
                let data: Data?
                if isPreview {
                    data = await Self.thumbnailData(from: previewURL)
                } else if let mediaID, let storage {
                    data = await storage.readThumbnail(id: mediaID)
                } else { data = nil }
                guard !Task.isCancelled else { return }
                extracted = await cache.palette(for: data, key: key)
            }
            guard !Task.isCancelled, selection.accept(extracted, requestID: requestID) else { return }
            if theme == .dynamic { palette = extracted }
        }
    }

    private func appearanceColor(light: AccentRGB, dark: AccentRGB) -> Color {
        Color(uiColor: UIColor { traits in
            let color = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        })
    }

    private nonisolated static func thumbnailData(from url: URL?) async -> Data? {
        guard let url, url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= 5_000_000 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 5_000_000 || Task.isCancelled { return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}
