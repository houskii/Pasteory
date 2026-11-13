import AppKit
import SwiftUI
import Testing
@testable import Pasteory

@MainActor
@Test func updateBadgeTextMeetsContrastInEveryThemeAndAppearance() throws {
    func luminance(_ color: Color) throws -> Double {
        let c = try #require(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ x: CGFloat) -> Double {
            let value = Double(x)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
    for theme in PasteoryThemeColor.allCases {
        for scheme in [ColorScheme.light, .dark] {
            let colors = UpdatePalette.colors(theme: theme, scheme: scheme)
            let foreground = try luminance(colors.foreground)
            let background = try luminance(colors.background)
            let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
            #expect(contrast >= 4.5, "\(theme.rawValue), \(scheme): \(contrast)")
        }
    }
}
