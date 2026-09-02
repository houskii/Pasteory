import SwiftUI

private struct PasteoryAccentColorKey: EnvironmentKey {
    static let defaultValue = PasteoryThemeColor.blueViolet.accentColor
}

extension EnvironmentValues {
    var pasteoryAccentColor: Color {
        get { self[PasteoryAccentColorKey.self] }
        set { self[PasteoryAccentColorKey.self] = newValue }
    }
}

extension View {
    func pasteoryTheme(_ theme: PasteoryThemeColor) -> some View {
        environment(\.pasteoryAccentColor, theme.accentColor)
            .tint(theme.accentColor)
    }
}

extension PasteoryThemeColor {
    var accentColor: Color {
        switch self {
        case .blueViolet: Color(red: 0.29, green: 0.38, blue: 0.96)
        case .blue: Color(red: 0.08, green: 0.45, blue: 0.88)
        case .purple: Color(red: 0.53, green: 0.25, blue: 0.87)
        case .pink: Color(red: 0.84, green: 0.20, blue: 0.52)
        case .orange: Color(red: 0.91, green: 0.39, blue: 0.10)
        case .green: Color(red: 0.08, green: 0.58, blue: 0.38)
        case .graphite: Color(red: 0.34, green: 0.38, blue: 0.44)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .blueViolet: Color(red: 0.55, green: 0.25, blue: 0.91)
        case .blue: Color(red: 0.12, green: 0.65, blue: 0.93)
        case .purple: Color(red: 0.69, green: 0.38, blue: 0.94)
        case .pink: Color(red: 0.96, green: 0.39, blue: 0.63)
        case .orange: Color(red: 0.96, green: 0.61, blue: 0.16)
        case .green: Color(red: 0.16, green: 0.73, blue: 0.51)
        case .graphite: Color(red: 0.48, green: 0.52, blue: 0.59)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [accentColor, secondaryColor], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
