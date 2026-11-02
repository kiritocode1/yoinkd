import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var library: MediaLibrary
    @Binding var appearance: AppAppearance

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScreenHeading(title: "Settings")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
                Section("Saved media") {
                    LabeledContent("Files", value: String(library.details.count))
                    LabeledContent("Media size", value: MediaPresentation.bytes(library.storedBytes))
                }
                Section("Media links") {
                    Text("Download public media from YouTube, Instagram, X, and other supported sites. Private links and sources that require sign-in may be unavailable.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Video", value: "360p to source maximum")
                    LabeledContent("Audio", value: "Source maximum")
                    LabeledContent("Extractor", value: "yt-dlp 2026.10.26")
                }
                Section {
                    HStack(spacing: 12) {
                        AppBrand.image.resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iYoinks").font(.headline)
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { BrandHeader() } }
        }
    }
}
