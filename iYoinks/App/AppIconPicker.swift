import SwiftUI

@MainActor
struct AppIconPicker: View {
    @State private var selected = LauncherIcon.current
    @State private var isChanging = false
    @State private var errorMessage: String?

    var body: some View {
        if Bundle.main.object(forInfoDictionaryKey: "IYoinksUsesAlternateIconFallback") as? Bool == true {
            Picker("App icon", selection: Binding(get: { selected }, set: changeIcon)) {
                ForEach(LauncherIcon.allCases, id: \.self) { icon in
                    Text(icon.rawValue).tag(icon)
                }
            }
            .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
            .accessibilityHint("Choose the light or dark Home Screen icon")
            .alert("Couldn't change the icon", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func changeIcon(_ icon: LauncherIcon) {
        guard !isChanging, icon != selected else { return }
        isChanging = true
        Task {
            defer { isChanging = false }
            do {
                try await UIApplication.shared.setAlternateIconName(icon.alternateName)
                selected = .current
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private enum LauncherIcon: String, CaseIterable {
        case light = "Light", dark = "Dark"

        var alternateName: String? { self == .dark ? "AppIconDark" : nil }

        @MainActor
        static var current: Self {
            UIApplication.shared.alternateIconName == "AppIconDark" ? .dark : .light
        }
    }
}
