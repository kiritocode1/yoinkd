import Foundation

public enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    case neutral, sage, lavender, amber, ocean, dynamic

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }

    public var palette: AccentPalette {
        switch self {
        case .neutral, .dynamic: .neutral
        case .sage: AccentPalette(hue: 0.40, saturation: 0.30)
        case .lavender: AccentPalette(hue: 0.74, saturation: 0.38)
        case .amber: AccentPalette(hue: 0.105, saturation: 0.52)
        case .ocean: AccentPalette(hue: 0.57, saturation: 0.38)
        }
    }
}

public struct ThemePreferences {
    private let defaults: UserDefaults
    public static let key = "accentTheme"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var theme: AccentTheme {
        get {
            defaults.string(forKey: Self.key).flatMap(AccentTheme.init(rawValue:)) ?? .sage
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

public struct AccentSelection: Sendable {
    public private(set) var key: String?
    public private(set) var requestID = UUID()
    public private(set) var palette = AccentPalette.neutral

    public init() {}

    @discardableResult
    public mutating func select(_ key: String?) -> Bool {
        guard self.key != key else { return false }
        self.key = key
        requestID = UUID()
        palette = .neutral
        return true
    }

    @discardableResult
    public mutating func accept(_ palette: AccentPalette, requestID: UUID) -> Bool {
        guard key != nil, self.requestID == requestID else { return false }
        self.palette = palette
        return true
    }
}
