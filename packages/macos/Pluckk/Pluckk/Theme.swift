import SwiftUI

// MARK: - Pluckk Design System
// Matches the Chrome extension styling

struct PluckkTheme {
    // MARK: - Brand Colors
    static let accent = Color(hex: "c9a66b")       // Warm tan/ochre - PRIMARY BRAND COLOR
    static let accentLight = Color(hex: "d4b896") // Lighter tan

    // MARK: - Card Type Accent Colors
    static let bidirectionalAccent = Color(hex: "3b82f6")  // Blue
    static let listAccent = Color(hex: "10b981")           // Emerald
    static let diagramAccent = Color(hex: "6366f1")        // Indigo

    // MARK: - Light Theme Colors
    struct Light {
        static let background = Color(hex: "fafafa")
        static let surface = Color(hex: "ffffff")
        static let surfaceSecondary = Color(hex: "f8f8f8")
        static let surfaceTertiary = Color(hex: "f5f5f5")

        static let textPrimary = Color(hex: "2d3436")
        static let textSecondary = Color(hex: "888888")
        static let textTertiary = Color(hex: "a0a0a0")
        static let textMuted = Color(hex: "999999")

        static let border = Color(hex: "e8e8e8")
        static let borderLight = Color(hex: "e0e0e0")
        static let divider = Color(hex: "eeeeee")

        static let buttonPrimary = Color(hex: "2d3436")
        static let buttonPrimaryHover = Color(hex: "1a1a1a")
        static let buttonSecondary = Color(hex: "f0f0f0")

        static let success = Color(hex: "27ae60")
        static let warning = Color(hex: "f39c12")
        static let error = Color(hex: "c0392b")

        // The surface the cards sit on, and the cards themselves
        static let table = Color(hex: "ececec")
        static let card = Color(hex: "ffffff")
        static let cardBorder = Color(hex: "dedede")
        static let answerText = Color(hex: "4a4a4a")

        // Sand particle colors
        static let sandParticles: [Color] = [
            Color(red: 60/255, green: 60/255, blue: 60/255).opacity(0.6),
            Color(red: 70/255, green: 70/255, blue: 70/255).opacity(0.5),
            Color(red: 50/255, green: 50/255, blue: 50/255).opacity(0.6),
            Color(red: 80/255, green: 80/255, blue: 80/255).opacity(0.45)
        ]
    }

    // MARK: - Dark Theme Colors
    struct Dark {
        static let background = Color(hex: "0f0f0f")
        static let surface = Color(hex: "1a1a1a")
        static let surfaceSecondary = Color(hex: "222222")
        static let surfaceTertiary = Color(hex: "252525")

        static let textPrimary = Color(hex: "f5f5f5")
        static let textSecondary = Color(hex: "a0a0a0")
        static let textTertiary = Color(hex: "777777")
        static let textMuted = Color(hex: "666666")

        static let border = Color(hex: "2a2a2a")
        static let borderLight = Color(hex: "333333")
        static let divider = Color(hex: "2a2a2a")

        static let buttonPrimary = Color(hex: "f5f5f5")
        static let buttonPrimaryHover = Color(hex: "e0e0e0")
        static let buttonSecondary = Color(hex: "2a2a2a")

        static let success = Color(hex: "27ae60")
        static let warning = Color(hex: "f39c12")
        static let error = Color(hex: "c0392b")

        // The surface the cards sit on, and the cards themselves
        static let table = Color(hex: "080808")
        static let card = Color(hex: "1c1c1e")
        static let cardBorder = Color(hex: "2e2e30")
        static let answerText = Color(hex: "c7c7cc")

        // Sand particle colors - warm ochre tones
        static let sandParticles: [Color] = [
            Color(red: 220/255, green: 215/255, blue: 200/255).opacity(0.5),  // cream
            Color(red: 200/255, green: 185/255, blue: 160/255).opacity(0.45), // warm cream
            Color(red: 180/255, green: 165/255, blue: 140/255).opacity(0.5),  // ochre/tan
            Color(red: 210/255, green: 200/255, blue: 180/255).opacity(0.4)   // light ochre
        ]
    }

    // MARK: - Typography
    static let fontFamily = Font.system(.body, design: .default)

    struct FontSize {
        static let display: CGFloat = 15
        static let body: CGFloat = 14
        static let small: CGFloat = 13
        static let smaller: CGFloat = 12
        static let tiny: CGFloat = 11
        static let mini: CGFloat = 10
    }

    // MARK: - Spacing
    struct Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 40
    }

    // MARK: - Border Radius
    struct Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 8
        static let xlarge: CGFloat = 10
    }

    // MARK: - Animation
    struct Animation {
        static let fast: Double = 0.15
        static let normal: Double = 0.2
        static let slow: Double = 0.25
    }
}

// MARK: - Color Extension for Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Environment-aware Colors
struct ThemeColors {
    @Environment(\.colorScheme) var colorScheme

    var background: Color {
        colorScheme == .dark ? PluckkTheme.Dark.background : PluckkTheme.Light.background
    }

    var surface: Color {
        colorScheme == .dark ? PluckkTheme.Dark.surface : PluckkTheme.Light.surface
    }

    var textPrimary: Color {
        colorScheme == .dark ? PluckkTheme.Dark.textPrimary : PluckkTheme.Light.textPrimary
    }

    var textSecondary: Color {
        colorScheme == .dark ? PluckkTheme.Dark.textSecondary : PluckkTheme.Light.textSecondary
    }

    var buttonPrimary: Color {
        colorScheme == .dark ? PluckkTheme.Dark.buttonPrimary : PluckkTheme.Light.buttonPrimary
    }

    var border: Color {
        colorScheme == .dark ? PluckkTheme.Dark.border : PluckkTheme.Light.border
    }

    var sandParticles: [Color] {
        colorScheme == .dark ? PluckkTheme.Dark.sandParticles : PluckkTheme.Light.sandParticles
    }
}
