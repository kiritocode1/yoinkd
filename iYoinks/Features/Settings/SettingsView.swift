import SwiftUI
import YoinksCore

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.colorScheme) private var colorScheme
    @Binding var appearance: AppAppearance
    @ScaledMetric(relativeTo: .caption) private var swatchWidth = 76

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    AppPillPicker(label: "Appearance", options: AppAppearance.allCases, selection: $appearance, title: { $0.rawValue })
                    AppIconPicker()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: swatchWidth), spacing: 8)], spacing: 8) {
                        ForEach(AccentTheme.allCases) { option in themeSwatch(option) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Accent theme")
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
                        AppBrand.image(for: colorScheme).resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iYoinks").font(.headline)
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func themeSwatch(_ option: AccentTheme) -> some View {
        let palette = option == .dynamic && theme.theme == .dynamic ? theme.palette : option.palette
        let color = colorScheme == .dark ? palette.dark : palette.light
        return Button { theme.setTheme(option) } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1))
                    .frame(width: 32, height: 32)
                    .overlay {
                        if theme.theme == option {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(theme.onAccent)
                        } else if option == .dynamic {
                            Image(systemName: "sparkles").font(.caption).foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        }
                    }
                Text(option.name).font(.caption).foregroundStyle(.primary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.theme == option ? theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(theme.theme == option ? .isSelected : [])
        .accessibilityHint(option == .dynamic ? "Use colours from the selected media artwork" : "")
    }
}
