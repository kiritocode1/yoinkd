import SwiftUI

@MainActor
struct AppIconAppearanceObserver: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        if scenePhase == .active { controller.observePhoneAppearance() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.stopObserving()
    }

    final class Controller: UIViewController {
        private weak var observedScene: UIWindowScene?
        private var registration: (any UITraitChangeRegistration)?
        private var isChanging = false
        private var changeTask: Task<Void, Never>?

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            observePhoneAppearance()
        }

        func observePhoneAppearance() {
            guard let scene = viewIfLoaded?.window?.windowScene else { return }
            if observedScene !== scene {
                stopObserving()
                observedScene = scene
                registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self], target: self, action: #selector(phoneAppearanceChanged))
            }
            updateIcon()
        }

        func stopObserving() {
            if let registration { observedScene?.unregisterForTraitChanges(registration) }
            registration = nil
            observedScene = nil
            changeTask?.cancel()
            changeTask = nil
        }

        @objc private func phoneAppearanceChanged() { updateIcon() }

        private func updateIcon() {
            guard Bundle.main.object(forInfoDictionaryKey: "IYoinksUsesAlternateIconFallback") as? Bool == true,
                  UIApplication.shared.supportsAlternateIcons, !isChanging,
                  let scene = observedScene, scene.activationState == .foregroundActive else { return }
            let desired = scene.traitCollection.userInterfaceStyle == .dark ? "AppIconDark" : nil
            guard UIApplication.shared.alternateIconName != desired else { return }
            isChanging = true
            changeTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await UIApplication.shared.setAlternateIconName(desired)
                    isChanging = false
                    if !Task.isCancelled { updateIcon() }
                } catch { isChanging = false }
            }
        }
    }
}
