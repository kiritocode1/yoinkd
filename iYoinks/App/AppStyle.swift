import SwiftUI

enum AppStyle {
    static let cornerRadius: CGFloat = 12
    static let thumbnailRatio: CGFloat = 16.0 / 11.0
    static let pageInset: CGFloat = 20
    static let controlHeight: CGFloat = 44
}

@MainActor
struct AppPrimaryButtonStyle: PrimitiveButtonStyle {
    @EnvironmentObject private var theme: AppTheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            Button(configuration)
                .font(AppTypography.font(.body, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .buttonBorderShape(.capsule)
                .buttonStyle(.glassProminent)
        } else {
            Button(configuration)
                .font(AppTypography.font(.body, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .buttonBorderShape(.capsule)
                .buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct AppSecondaryButtonStyle: PrimitiveButtonStyle {
    @EnvironmentObject private var theme: AppTheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            Button(configuration)
                .font(AppTypography.font(.body, weight: .medium))
                .foregroundStyle(configuration.role == .destructive ? Color.red : theme.primaryText)
                .buttonBorderShape(.capsule)
                .buttonStyle(.glass)
        } else {
            Button(configuration)
                .font(AppTypography.font(.body, weight: .medium))
                .foregroundStyle(configuration.role == .destructive ? Color.red : theme.primaryText)
                .buttonBorderShape(.capsule)
                .buttonStyle(.bordered)
        }
    }
}

@MainActor
struct AppCompactButtonStyle: PrimitiveButtonStyle {
    @EnvironmentObject private var theme: AppTheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            Button(configuration)
                .foregroundStyle(configuration.role == .destructive ? Color.red : theme.primaryText)
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
        } else {
            Button(configuration)
                .foregroundStyle(configuration.role == .destructive ? Color.red : theme.primaryText)
                .buttonBorderShape(.circle)
                .buttonStyle(.bordered)
        }
    }
}

@MainActor
private struct AppToolbarSearch: ViewModifier {
    let prompt: String
    @Binding var text: String
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: Text(prompt))
                .searchFocused($focused)
                .searchToolbarBehavior(.minimize)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .modifier(cancelControl)
        } else if #available(iOS 18, *) {
            content
                .searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: Text(prompt))
                .searchFocused($focused)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .modifier(cancelControl)
        } else if #available(iOS 17.1, *) {
            content
                .searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: Text(prompt))
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .modifier(cancelControl)
        } else {
            content.searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: Text(prompt))
                .modifier(cancelControl)
        }
    }

    private var cancelControl: AppSearchCancellation {
        AppSearchCancellation(text: $text, isPresented: $isPresented) {
            focused = false
            text = ""
            isPresented = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

@MainActor
private struct AppSearchCancellation: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let cancel: () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .cancellationAction) {
                        AppSearchCancelButton(cancel: cancel)
                    }
                }
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { cancel() }
            }
            .onChange(of: text) { previous, current in
                if isPresented, !previous.isEmpty, current.isEmpty { cancel() }
            }
    }
}

private struct AppSearchCancelButton: View {
    @Environment(\.dismissSearch) private var dismissSearch
    let cancel: () -> Void

    var body: some View {
        Button("Cancel", role: .cancel) {
            dismissSearch()
            cancel()
        }
        .accessibilityLabel("Close search")
    }
}

@MainActor
private struct AppSegmentedControlStyle: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = AppStyle.controlHeight

    func body(content: Content) -> some View {
        content
            .pickerStyle(.segmented)
            .controlSize(.large)
            .font(AppTypography.font(.body, weight: .medium))
            .frame(minHeight: max(AppStyle.controlHeight, minimumHeight))
    }
}

@MainActor
struct AppSectionBar: View {
    @EnvironmentObject private var theme: AppTheme
    let title: String

    var body: some View {
        Text(title)
            .font(AppTypography.font(.headline, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: AppStyle.cornerRadius))
            .accessibilityAddTraits(.isHeader)
    }
}

enum SupportedPlatform: String, CaseIterable {
    case youtube, instagram, twitter, tiktok, other

    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .twitter: "X"
        case .tiktok: "TikTok"
        case .other: "More sites"
        }
    }

    var subtitle: String {
        switch self {
        case .youtube: "Videos, shorts, audio"
        case .instagram: "Reels, posts, videos"
        case .twitter, .tiktok: "Videos"
        case .other: "Other supported websites and direct links"
        }
    }
}

@MainActor
struct PlatformIcon: View {
    @EnvironmentObject private var theme: AppTheme
    let platform: SupportedPlatform

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(theme.controlBackground)
            if platform == .other {
                Image(systemName: "ellipsis").foregroundStyle(theme.secondaryText)
            } else if let image = AppPlatformArtwork.image(named: platform == .twitter ? "x" : platform.rawValue) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: 20, height: 20).foregroundStyle(theme.primaryText)
            }
        }
        .font(.system(.title3))
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

struct AppTabTransition: Equatable, Sendable {
    var selected = AppTab.library
    var generation = 0
}

private struct AppTabTransitionKey: EnvironmentKey {
    static let defaultValue = AppTabTransition()
}

extension EnvironmentValues {
    var appTabTransition: AppTabTransition {
        get { self[AppTabTransitionKey.self] }
        set { self[AppTabTransitionKey.self] = newValue }
    }
}

private struct AppTabContent: ViewModifier {
    @Environment(\.appTabTransition) private var transition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = true
    @State private var enteredGeneration = 0
    let tab: AppTab

    private var isEntering: Bool {
        guard transition.selected == tab, transition.generation > 0, !reduceMotion else { return false }
        return enteredGeneration != transition.generation || !entered
    }

    func body(content: Content) -> some View {
        content
            .transaction(value: isEntering) { transaction in
                transaction.animation = nil
            }
            .scaleEffect(isEntering ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isEntering)
            .task(id: transition) {
                resetEntry()
                guard transition.selected == tab, transition.generation != enteredGeneration else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    enteredGeneration = transition.generation
                    entered = reduceMotion
                }
                guard !reduceMotion else { return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, !reduceMotion else { return }
                entered = true
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { enteredGeneration = transition.generation; resetEntry() }
            }
            .onDisappear { enteredGeneration = transition.generation; resetEntry() }
    }

    private func resetEntry() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { entered = true }
    }
}

private struct AppFiniteReflection: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = true
    let trigger: String
    let cornerRadius: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled && !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, .white.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.5, height: geometry.size.height * 2)
                            .rotationEffect(.degrees(25))
                            .offset(x: geometry.size.width * (swept ? 1.5 : -0.8), y: -geometry.size.height * 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: trigger) {
                guard enabled && !reduceMotion else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { swept = false }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.7)) { swept = true }
            }
    }
}

@MainActor
private struct AppNativeChrome: UIViewControllerRepresentable {
    @EnvironmentObject private var theme: AppTheme

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.primaryText = UIColor(theme.primaryText)
        controller.secondaryText = UIColor(theme.secondaryText)
        controller.controlBackground = UIColor(theme.controlBackground)
        controller.accent = UIColor(theme.accent)
        controller.onAccent = UIColor(theme.onAccent)
        controller.applyPalette()
    }

    final class Controller: UIViewController {
        var primaryText = UIColor.clear
        var secondaryText = UIColor.clear
        var controlBackground = UIColor.clear
        var accent = UIColor.clear
        var onAccent = UIColor.clear

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyPalette()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            applyPalette()
        }

        func applyPalette() {
            guard viewIfLoaded?.window != nil else { return }
            var host: UIViewController = self
            while let parent = host.parent, !(parent is UINavigationController), !(parent is UITabBarController) {
                host = parent
            }
            guard navigationController?.visibleViewController === host else { return }
            if let bar = navigationController?.navigationBar {
                bar.titleTextAttributes = [.foregroundColor: primaryText, .font: AppTypography.nativeFont(for: .headline, weight: .semibold, heading: true, compatibleWith: bar.traitCollection)]
                bar.largeTitleTextAttributes = [.foregroundColor: primaryText, .font: AppTypography.nativeFont(for: .largeTitle, weight: .semibold, heading: true, compatibleWith: bar.traitCollection)]
                bar.tintColor = accent
                applySegmentPalette(in: bar)
            }
            if let bar = tabBarController?.tabBar {
                bar.tintColor = accent
                bar.unselectedItemTintColor = secondaryText
                for item in bar.items ?? [] {
                    let font = AppTypography.nativeFont(for: .caption2, weight: .medium, compatibleWith: bar.traitCollection)
                    item.setTitleTextAttributes([.font: font, .foregroundColor: secondaryText], for: .normal)
                    item.setTitleTextAttributes([.font: font, .foregroundColor: accent], for: .selected)
                }
            }
            applySegmentPalette(in: host.view)
        }

        private func applySegmentPalette(in view: UIView) {
            if let searchField = view as? UISearchTextField {
                searchField.font = AppTypography.nativeFont(for: .body, compatibleWith: searchField.traitCollection)
                searchField.textColor = primaryText
                searchField.tintColor = accent
            }
            if let segmented = view as? UISegmentedControl {
                segmented.backgroundColor = controlBackground
                segmented.selectedSegmentTintColor = accent
                let font = AppTypography.nativeFont(for: .body, weight: .medium, compatibleWith: segmented.traitCollection)
                segmented.setTitleTextAttributes([.foregroundColor: primaryText, .font: font], for: .normal)
                segmented.setTitleTextAttributes([.foregroundColor: onAccent, .font: font], for: .selected)
            }
            for child in view.subviews { applySegmentPalette(in: child) }
        }
    }
}

extension View {
    func appToolbarSearch(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        modifier(AppToolbarSearch(prompt: prompt, text: text, isPresented: isPresented))
    }

    func appTabContent(for tab: AppTab) -> some View { modifier(AppTabContent(tab: tab)) }

    func appSegmentedControl() -> some View {
        modifier(AppSegmentedControlStyle())
    }

    func appFiniteReflection(trigger: String, cornerRadius: CGFloat = 18, enabled: Bool = true) -> some View {
        modifier(AppFiniteReflection(trigger: trigger, cornerRadius: cornerRadius, enabled: enabled))
    }

    func appNativeChrome() -> some View { background(AppNativeChrome().frame(width: 0, height: 0)) }
}
