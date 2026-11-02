import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Hashable { case library, downloads, history, settings }

@MainActor
struct RootView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @StateObject private var theme = AppTheme()
    @State private var selectedTab = AppTab.library
    @State private var showsAddLink = false
    @State private var showsImporter = false

    var body: some View {
        nativeTabs
            .tint(theme.accent)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: theme.palette)
            .preferredColorScheme(appearance.colorScheme)
            .sheet(isPresented: $showsAddLink) {
                AddLinkView { selectedTab = .downloads }
                    .tint(theme.accent)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: theme.palette)
                    .presentationDetents([.large])
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    selectedTab = .library
                    Task { await library.importFiles(urls) }
                case .failure(let error):
                    library.errorMessage = error.localizedDescription
                }
            }
            .alert("Library issue", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("OK", role: .cancel) { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
            .onChange(of: Set(library.details.keys)) { _, ids in theme.retainSelection(in: ids) }
            .environmentObject(theme)
    }

    @ViewBuilder
    private var nativeTabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                    LibraryView(onImport: { showsImporter = true }, onAddLink: { showsAddLink = true })
                }
                Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                    DownloadsView(onAddLink: { showsAddLink = true })
                }
                .badge(queue.activeCount)
                Tab("History", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                    HistoryView()
                }
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                    SettingsView(appearance: $appearance)
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                LibraryView(onImport: { showsImporter = true }, onAddLink: { showsAddLink = true })
                    .tabItem { Label("Library", systemImage: "rectangle.stack") }.tag(AppTab.library)
                DownloadsView(onAddLink: { showsAddLink = true })
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(AppTab.downloads)
                    .badge(queue.activeCount)
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(AppTab.history)
                SettingsView(appearance: $appearance)
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
            }
        }
    }
}
