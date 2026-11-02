import SwiftUI

enum AppStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let controlBackground = Color(uiColor: .tertiarySystemFill)
    static let cornerRadius: CGFloat = 12
}

@MainActor
struct AppPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(theme.onAccent)
            .background(theme.accent, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            label(configuration)
                .glassEffect(.regular.interactive(isEnabled), in: Capsule())
        } else {
            label(configuration)
                .background(AppStyle.controlBackground, in: Capsule())
        }
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

@MainActor
struct AppPillPicker<Selection: Hashable>: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    let label: String
    let options: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    var symbol: (Selection) -> String? = { _ in nil }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 4) { optionsContent }
            } else {
                HStack(spacing: 4) { optionsContent }
            }
        }
        .padding(.horizontal, 4)
        .background(AppStyle.controlBackground, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var optionsContent: some View {
        ForEach(options, id: \.self) { option in
            Button { selection = option } label: {
                HStack(spacing: 6) {
                    if let symbol = symbol(option) { Image(systemName: symbol).accessibilityHidden(true) }
                    Text(title(option))
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selection == option ? theme.onAccent : Color.primary)
                .background {
                    Capsule()
                        .fill(selection == option ? theme.accent : Color.clear)
                        .padding(.vertical, 6)
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == option ? .isSelected : [])
        }
    }
}
