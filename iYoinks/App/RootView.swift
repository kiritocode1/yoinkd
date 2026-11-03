import SwiftUI
import UniformTypeIdentifiers

enum AppTab: Int, Hashable, Sendable { case library, downloads, history, settings }

@MainActor
struct RootView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @StateObject private var theme = AppTheme()
    @State private var selectedTab = AppTab.library
    @State private var tabTransition = AppTabTransition()
    @State private var showsAddLink = false
    @State private var showsImporter = false

    var body: some View {
        tabs
            .background(theme.background)
            .foregroundStyle(theme.primaryText)
            .tint(theme.accent)
            .font(AppTypography.font(.body))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: theme.palette)
            .preferredColorScheme(appearance.colorScheme)
            .sheet(isPresented: $showsAddLink) {
                AddLinkView { selectTab(.downloads) }
                    .tint(theme.accent)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: theme.palette)
                    .presentationDetents([.large])
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    selectTab(.library)
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
            .environment(\.appTabTransition, tabTransition)
            .environmentObject(theme)
            .background(AppIconAppearanceObserver().frame(width: 0, height: 0))
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { selectedTab }, set: selectTab)) {
            LibraryView(onImport: { showsImporter = true }, onAddLink: { showsAddLink = true })
                .tabItem { tabLabel("Library", systemImage: "folder") }
                .tag(AppTab.library)
            DownloadsView(onAddLink: { showsAddLink = true })
                .tabItem { tabLabel("Downloads", systemImage: "arrow.down.to.line") }
                .badge(queue.activeCount)
                .tag(AppTab.downloads)
            HistoryView()
                .tabItem { tabLabel("History", systemImage: "clock") }
                .tag(AppTab.history)
            SettingsView(appearance: $appearance)
                .tabItem { tabLabel("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }

    private func tabLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            if reduceMotion {
                Image(systemName: systemImage)
            } else {
                Image(systemName: systemImage)
                    .symbolEffect(.bounce, value: selectedTab)
            }
        }
    }

    private func selectTab(_ selected: AppTab) {
        guard selected != selectedTab else { return }
        tabTransition = AppTabTransition(selected: selected,
                                         generation: tabTransition.generation + 1)
        selectedTab = selected
    }
}
