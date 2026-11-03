import SwiftUI
import UniformTypeIdentifiers
import YoinksCore

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.colorScheme) private var colorScheme
    @Binding var appearance: AppAppearance
    @ScaledMetric(relativeTo: .caption) private var swatchWidth = 76
    @State private var showsFolderPicker = false

    private var folderControlsDisabled: Bool {
        !queue.isReady || queue.jobs.contains { !$0.phase.isTerminal } || library.importProgress != nil || library.isChangingFolder
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Appearance") {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .appSegmentedControl()
                        .padding(.vertical, 16)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: swatchWidth), spacing: 8)], spacing: 8) {
                            ForEach(AccentTheme.allCases) { option in themeSwatch(option) }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Theme")
                    }
                    .listRowBackground(theme.surface)
                    .listRowSeparatorTint(theme.separator)
                    Section("Saved media") {
                        LabeledContent("Files", value: String(library.details.count))
                        LabeledContent("Media size", value: MediaPresentation.bytes(library.storedBytes))
                        LabeledContent("Folder", value: library.mediaFolderName)
                        if library.isChangingFolder {
                            ProgressView("Moving saved media...")
                        }
                        Button("Choose folder", systemImage: "folder") { showsFolderPicker = true }
                            .disabled(folderControlsDisabled)
                        Button("Use app folder", systemImage: "arrow.counterclockwise") {
                            changeFolder(to: nil)
                        }
                        .disabled(folderControlsDisabled)
                    }
                    .listRowBackground(theme.surface)
                    .listRowSeparatorTint(theme.separator)
                    Section("Media links") {
                        Text("Download public media from YouTube, Instagram, X, and other supported sites. Private links and sources that require sign-in may be unavailable.")
                            .foregroundStyle(theme.secondaryText)
                        LabeledContent("Video", value: "All available source qualities")
                        LabeledContent("Audio", value: "Source audio or converted output")
                    }
                    .listRowBackground(theme.surface)
                    .listRowSeparatorTint(theme.separator)
                    DependencyUpdatesSection()
                    Section {
                        HStack(spacing: 12) {
                            AppBrand.image(for: colorScheme).resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("yoink'd").font(AppTypography.font(.headline, weight: .semibold))
                                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                                    .font(AppTypography.font(.caption)).foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                    .listRowBackground(theme.surface)
                    .listRowSeparatorTint(theme.separator)
                }
                .listSectionSpacing(16)
                .scrollContentBackground(.hidden)
            }
            .foregroundStyle(theme.primaryText, theme.secondaryText)
            .background(theme.background)
            .appTabContent(for: .settings)
            .appNativeChrome()
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): changeFolder(to: url)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func changeFolder(to url: URL?) {
        guard !folderControlsDisabled else { return }
        Task {
            do { try await library.changeMediaFolder(to: url) }
            catch { library.errorMessage = error.localizedDescription }
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
                Text(option.name).font(AppTypography.font(.caption, weight: .medium)).foregroundStyle(theme.primaryText)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(theme.theme == option ? theme.controlBackground : Color.clear, in: RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.cornerRadius)
                    .strokeBorder(theme.theme == option ? theme.accent : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(theme.theme == option ? .isSelected : [])
        .accessibilityHint(option == .dynamic ? "Use colours from the selected media artwork" : "")
    }
}
