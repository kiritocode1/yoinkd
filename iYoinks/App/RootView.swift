import SwiftUI
import UniformTypeIdentifiers
import YoinksCore

enum AppTab: Int, Hashable, Sendable { case library, downloads, history, settings }

@MainActor
struct RootView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @StateObject private var theme = AppTheme()
    @State private var selectedTab = AppTab.library
    @State private var tabTransition = AppTabTransition()
    /// Set by `yoinkd://add` links. Taken and cleared here, so it can arrive before this view exists.
    @Binding var pendingCapture: CaptureRequest?
    @State private var capture: CaptureRequest?
    @State private var showsImporter = false
    /// Links the share extension saved, including ones that couldn't open the app. Nil without the App Group.
    private let inbox = CaptureInbox.shared()

    var body: some View {
        tabs
            .background(theme.background)
            .foregroundStyle(theme.primaryText)
            .tint(theme.accent)
            .font(AppTypography.font(.body))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: theme.palette)
            .preferredColorScheme(appearance.colorScheme)
            .sheet(item: $capture) { request in
                AddLinkView(request: request) { selectTab(.downloads) }
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
            .onChange(of: pendingCapture, initial: true) { presentNextCapture() }
            .onChange(of: capture) { presentNextCapture() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { presentNextCapture() } }
            .onChange(of: Set(library.details.keys)) { _, ids in theme.retainSelection(in: ids) }
            .environment(\.appTabTransition, tabTransition)
            .environmentObject(theme)
            .background(AppIconAppearanceObserver().frame(width: 0, height: 0))
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { selectedTab }, set: selectTab)) {
            LibraryView(onImport: { showsImporter = true }, onAddLink: { capture = CaptureRequest() })
                .tabItem { tabLabel("Library", systemImage: "folder") }
                .tag(AppTab.library)
            DownloadsView(onAddLink: { capture = CaptureRequest() })
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

    /// Shows a `yoinkd://add` link first, then the oldest link waiting in the share inbox.
    /// A link already on screen is not shown twice. A shared link that a newer one replaces goes back
    /// into the inbox, so it reappears when the newer sheet closes.
    private func presentNextCapture() {
        if let request = pendingCapture {
            pendingCapture = nil
            inbox?.remove(request.id)
            guard capture?.id != request.id else { return }
            if let current = capture, !current.link.isEmpty { try? inbox?.add(current) }
            capture = request
            return
        }
        guard capture == nil, scenePhase == .active, let next = inbox?.next() else { return }
        inbox?.remove(next.id)
        capture = next
    }

    private func selectTab(_ selected: AppTab) {
        guard selected != selectedTab else { return }
        tabTransition = AppTabTransition(selected: selected,
                                         generation: tabTransition.generation + 1)
        selectedTab = selected
    }
}
